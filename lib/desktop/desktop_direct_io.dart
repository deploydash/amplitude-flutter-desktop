import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_plugin.dart';

// In-process desktop routing for the public `Amplitude` API (IO targets).
//
// WHY direct routing instead of the channel: on Linux/Windows the
// engine-backed binary messenger delivers a Dart `invokeMethod` to native
// code only, so a pure-Dart `setMethodCallHandler` never sees it
// (MissingPluginException on a real run — proven by the loopback probe in
// T-12). The public `Amplitude` API therefore calls the in-process desktop
// backend directly on desktop; Android, iOS, macOS, and web keep the
// channel bit-for-bit. The 14-method contract is unchanged: direct calls
// run through the same `handleMethodCall` the channel serves.
//
// This file is only compiled where `dart:io` exists (see the conditional
// import in `amplitude.dart`); web keeps `desktop_direct.dart`.
/// Test-only override for the process-wide direct plugin.
@visibleForTesting
DesktopAmplitudePlugin Function()? debugDirectPluginFactory;

/// Process-wide direct plugin. One per process is correct: backends inside
/// are keyed by instance name exactly like channel-served ones.
DesktopAmplitudePlugin? _directPlugin;

/// Drops the process-wide direct plugin (and its override). Tests call
/// this in setUp/tearDown so platform routing never leaks between cases.
@visibleForTesting
void resetDesktopDirectForTests() {
  _directPlugin = null;
  debugDirectPluginFactory = null;
}

Future<dynamic> invokeDesktopMethod(
  MethodChannel channel,
  String method,
  dynamic arguments,
) {
  if (defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.windows) {
    return channel.invokeMethod(method, arguments);
  }
  final custom = debugDirectPluginFactory;
  _directPlugin ??= custom != null
      ? custom()
      : DesktopAmplitudePlugin(
          lifecycleSource: WidgetsBindingLifecycleSource(),
        );
  return _directPlugin!.handleMethodCall(MethodCall(method, arguments));
}
