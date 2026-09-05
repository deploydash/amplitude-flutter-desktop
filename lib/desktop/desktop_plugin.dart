import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../constants.dart';
import 'desktop_backend.dart';

// `MethodChannel` handler for the pure-Dart desktop backend (plan §1.6/H.8).
//
// WHY this file exists: Linux and Windows have no native Amplitude SDK, so
// the generated registrant routes the shared `amplitude_flutter` channel to
// this Dart implementation (via the `linux:`/`windows:` `dartPluginClass`
// entries in pubspec.yaml) instead of leaving it unhandled. The shape mirrors
// `amplitude_web.dart`'s `registerWith` + `handleMethodCall`; `lib/
// amplitude.dart` is untouched, so no caller changes.
//
// SCOPE: the channel carries the 14 methods `Amplitude` invokes
// (init/track/identify/groupIdentify/setGroup/revenue/getUserId/setUserId/
// getDeviceId/setDeviceId/getSessionId/setOptOut/reset/flush). Terminal
// per-event outcomes are config-level only (`DesktopBackend.onTerminalEvent`,
// plan §H.9): callbacks cannot cross a `MethodChannel`, so channel users get
// diagnostic logs, while direct `DesktopBackend` users get callbacks.

/// Creates the [DesktopBackend] for one `init` call. Tests inject a factory
/// with in-memory storage and a scripted HTTP client.
typedef DesktopBackendFactory = DesktopBackend Function();

/// Source of Flutter lifecycle states for one plugin.
///
/// WHY an interface: production observes `WidgetsBinding` (no Cocoa code,
/// no caller API), while tests inject a fake that fires states with explicit
/// timestamps. The plugin translates states to backend
/// enter/exit calls; backends serialize the calls through their own chains.
abstract class DesktopLifecycleSource {
  /// Current state at attach time (drives init-while-hidden).
  AppLifecycleState get currentState;

  /// Begins observations, invoking [onState] with the state and epoch millis
  /// for every transition.
  void start(void Function(AppLifecycleState state, int timestampMs) onState);

  /// Ends observations. Idempotent.
  void stop();
}

/// Production [DesktopLifecycleSource] via `WidgetsBindingObserver`.
///
/// WHY `WidgetsBindingObserver` and not a window-manager plugin: the 14-method
/// channel contract is frozen, and no extra native toolchain is required on
/// Linux/Windows. Desktop `inactive` (visible but unfocused, e.g. alt-tab)
/// is deliberately not a session boundary.
class WidgetsBindingLifecycleSource
    with WidgetsBindingObserver
    implements DesktopLifecycleSource {
  WidgetsBindingLifecycleSource({int Function()? clock})
      : _clock = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final int Function() _clock;
  void Function(AppLifecycleState state, int timestampMs)? _onState;

  @override
  AppLifecycleState get currentState =>
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  @override
  void start(void Function(AppLifecycleState state, int timestampMs) onState) {
    _onState = onState;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _onState = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _onState?.call(state, _clock());
  }
}

class DesktopAmplitudePlugin {
  DesktopAmplitudePlugin({
    DesktopBackendFactory? backendFactory,
    DesktopLifecycleSource? lifecycleSource,
  })  : _backendFactory = backendFactory ?? DesktopBackend.new,
        _lifecycleSource = lifecycleSource {
    final source = _lifecycleSource;
    if (source != null) {
      _isForeground = _isForegroundState(source.currentState);
      source.start((state, timestampMs) {
        unawaited(handleLifecycleForTests(state, timestampMs));
      });
    }
  }

  final DesktopBackendFactory _backendFactory;
  final DesktopLifecycleSource? _lifecycleSource;

  /// True while the app is visible/foreground. `inactive` never changes it.
  bool _isForeground = true;

  /// Set on `detached`: further states are ignored and observations stop.
  bool _detached = false;

  static bool _isForegroundState(AppLifecycleState state) {
    return switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached =>
        false,
    };
  }

  /// Backends by `instanceName`. Visible for tests.
  final Map<String, DesktopBackend> instances = {};

  /// The plugin currently serving the channel. Hot restart re-runs the
  /// registrant without killing the isolate, so a second `registerWith`
  /// must retire the first plugin's backends (their 30 s flush timers
  /// would otherwise keep firing against the same store namespace and
  /// upload every file twice).
  static DesktopAmplitudePlugin? _activePlugin;

  /// Test-only override for the backend factory used by [registerWith].
  /// Production always uses the default constructor; tests inject scripted
  /// backends to prove hot-restart retires the previous plugin without
  /// real I/O. The generated registrant calls the zero-arg [registerWith],
  /// so this never affects the channel contract.
  @visibleForTesting
  static DesktopBackendFactory debugBackendFactory = DesktopBackend.new;

  /// Test-only view of the plugin currently serving the channel.
  @visibleForTesting
  static DesktopAmplitudePlugin? get activePluginForTests => _activePlugin;

  /// Called by the generated registrant on Linux/Windows (zero-arg shape
  /// verified against the Flutter tool's `flutter_plugins.dart`).
  static void registerWith() {
    final previous = _activePlugin;
    final next = DesktopAmplitudePlugin(
      backendFactory: debugBackendFactory,
      lifecycleSource: WidgetsBindingLifecycleSource(),
    );
    _activePlugin = next;
    const MethodChannel('amplitude_flutter')
        .setMethodCallHandler(next.handleMethodCall);
    if (previous != null) {
      unawaited(previous.dispose());
    }
  }

  /// Releases observations and backends. Idempotent: safe to call twice and
  /// safe to call on a plugin that never initialized a backend. The on-disk
  /// queue is the delivery guarantee; lifecycle exit flushes are best-effort.
  Future<void> dispose() async {
    _detached = true;
    _lifecycleSource?.stop();
    for (final backend in instances.values) {
      await backend.dispose();
    }
    instances.clear();
    if (identical(_activePlugin, this)) {
      _activePlugin = null;
    }
  }

  /// Test hook driving the same path as the lifecycle source, with an
  /// explicit timestamp. Production never calls this; the source does.
  @visibleForTesting
  Future<void> handleLifecycleForTests(
    AppLifecycleState state,
    int timestampMs,
  ) async {
    if (_detached) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        if (_isForeground) {
          return;
        }
        _isForeground = true;
        for (final backend in instances.values) {
          await backend.onEnterForeground(timestampMs);
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!_isForeground) {
          return;
        }
        _isForeground = false;
        for (final backend in instances.values) {
          await backend.onExitForeground(timestampMs);
        }
      case AppLifecycleState.inactive:
        // Visible but unfocused (alt-tab): never a session boundary.
        return;
      case AppLifecycleState.detached:
        // Best-effort exit/flush once, then stop observations. The SDK never
        // decides whether the app may exit; the host owns that.
        _isForeground = false;
        _detached = true;
        for (final backend in instances.values) {
          await backend.onExitForeground(timestampMs);
        }
        _lifecycleSource?.stop();
    }
  }

  /// Handles method calls over the `MethodChannel` of this plugin.
  Future<dynamic> handleMethodCall(MethodCall call) async {
    if (call.method == 'init') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final backend = _backendFactory();
      final ok = await backend.init(args);
      if (!ok) {
        // Refused (no usable apiKey): never stored, queue stays untouched.
        await backend.dispose();
        return null;
      }
      final rawKey = args['instanceName'];
      final key = rawKey is String && rawKey.isNotEmpty
          ? rawKey
          : Constants.defaultInstanceName;
      // Re-init replaces the backend: dispose the old one first so its
      // flush timer stops firing against the same store namespace (which
      // would otherwise upload every file twice).
      final previous = instances[key];
      if (previous != null) {
        await previous.dispose();
      }
      instances[key] = backend;
      // Init-while-hidden: the first event must process as background so a
      // restored session rotates on the next real resume past the gap.
      if (!_isForeground) {
        backend.setForeground(false);
      }
      return null;
    }

    final rawLookup = (call.arguments as Map)['instanceName'];
    final backend = instances[
        rawLookup is String ? rawLookup : Constants.defaultInstanceName];
    if (backend == null) {
      // No init yet for this instance: reads resolve null/-1 and never hang
      // (the Android `isBuilt` gate analog); writes drop silently.
      switch (call.method) {
        case 'getUserId':
        case 'getDeviceId':
          return null;
        case 'getSessionId':
          return -1;
        case 'track':
        case 'identify':
        case 'groupIdentify':
        case 'setGroup':
        case 'revenue':
        case 'setUserId':
        case 'setDeviceId':
        case 'setOptOut':
        case 'reset':
        case 'flush':
          return null;
        default:
          throw PlatformException(
            code: 'Unimplemented',
            details:
                "The amplitude_flutter plugin for desktop doesn't implement the method '${call.method}'",
          );
      }
    }

    switch (call.method) {
      case 'track':
        return backend.track(_eventArgs(call));
      case 'identify':
        return backend.identify(_eventArgs(call));
      case 'groupIdentify':
        return backend.groupIdentify(_eventArgs(call));
      case 'setGroup':
        return backend.setGroup(_eventArgs(call));
      case 'revenue':
        return backend.revenue(_eventArgs(call));
      case 'getUserId':
        return backend.getUserId();
      case 'setUserId':
        return backend.setUserId(
          (call.arguments as Map)['properties']['setUserId'] as String?,
        );
      case 'getDeviceId':
        return backend.getDeviceId();
      case 'setDeviceId':
        return backend.setDeviceId(
          (call.arguments as Map)['properties']['setDeviceId'] as String?,
        );
      case 'getSessionId':
        return backend.getSessionId();
      case 'setOptOut':
        return backend.setOptOut(
          (call.arguments as Map)['properties']['setOptOut'] as bool,
        );
      case 'reset':
        return backend.reset();
      case 'flush':
        return backend.flush();
      default:
        throw PlatformException(
          code: 'Unimplemented',
          details:
              "The amplitude_flutter plugin for desktop doesn't implement the method '${call.method}'",
        );
    }
  }

  Map<String, dynamic> _eventArgs(MethodCall call) {
    return Map<String, dynamic>.from(
      (call.arguments as Map)['event'] as Map,
    );
  }
}
