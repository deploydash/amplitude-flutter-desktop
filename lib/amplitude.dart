import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'events/event_options.dart';
import 'events/identify_event.dart';
import 'events/identify.dart';
import 'events/revenue.dart';
import 'configuration.dart';
import 'events/base_event.dart';
import 'events/group_identify_event.dart';

enum _InitializationState { pending, draining, ready, failed }

class _PendingMethodCall {
  const _PendingMethodCall({
    required this.dispatch,
    required this.completeError,
  });

  final void Function() dispatch;
  final void Function(Object error, StackTrace stackTrace) completeError;
}

class Amplitude {
  Configuration configuration;
  MethodChannel _channel = const MethodChannel('amplitude_flutter');
  late final bool _gateUntilRegistration;
  _InitializationState _initializationState = _InitializationState.pending;
  final List<_PendingMethodCall> _pendingMethodCalls = [];
  Object? _initializationError;
  StackTrace? _initializationStackTrace;

  /// Whether the Amplitude instance has been successfully initialized.
  ///
  /// On Android, this waits for the native SDK's `isBuilt` signal. Calls made
  /// while the Flutter plugin instance is being registered are buffered in
  /// call order and handed to the native SDK before this future resolves.
  ///
  /// ```
  /// var amplitude = Amplitude(Configuration(apiKey: 'apiKey'));
  /// // Await when the application needs Android's native initialization to be
  /// // complete or needs to inspect whether initialization succeeded.
  /// await amplitude.isBuilt;
  /// ```
  late Future<bool> isBuilt;

  /// Returns an Amplitude instance
  ///
  /// ```
  /// final amplitude = Amplitude(Configuration(apiKey: 'apiKey'));
  /// // Await when the application needs Android's native initialization to be
  /// // complete or needs to inspect whether initialization succeeded.
  /// await amplitude.isBuilt;
  /// ```
  Amplitude(this.configuration, [MethodChannel? methodChannel]) {
    _channel = methodChannel ?? _channel;
    _gateUntilRegistration =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    isBuilt = _init();
  }

  Future<bool> _init() async {
    final initializedInstanceName = configuration.instanceName;
    try {
      await _channel.invokeMethod<void>('init', configuration.toMap());

      if (!_gateUntilRegistration) {
        return true;
      }

      // Android's init reply means the plugin instance is registered and can
      // accept calls. Hand off buffered calls before waiting for the native
      // build so identity/event ordering remains compatible with the Android
      // SDK's own pre-build queue.
      _drainPendingMethodCalls();
      await _channel.invokeMethod<void>('awaitBuild', {
        'instanceName': initializedInstanceName,
      });
      return true;
    } catch (error, stackTrace) {
      print('Error initializing Amplitude: $error');
      if (_gateUntilRegistration) {
        if (_initializationState == _InitializationState.ready) {
          _markInitializationFailed(error, stackTrace);
        } else if (_initializationState != _InitializationState.failed) {
          _completePendingMethodCallsWithError(error, stackTrace);
        }
      }
      return false;
    }
  }

  /// On Android, buffers platform methods in call order until `init` confirms
  /// that the plugin instance is registered.
  ///
  /// Other platforms continue to use MethodChannel directly, preserving their
  /// existing startup behavior. A registration failure rejects buffered and
  /// later calls; a native-build failure rejects subsequent calls.
  Future<T?> _invokeMethod<T>(String method, Object? arguments) {
    if (!_gateUntilRegistration ||
        _initializationState == _InitializationState.ready) {
      return _channel.invokeMethod<T>(method, arguments);
    }

    if (_initializationState == _InitializationState.failed) {
      return Future<T?>.error(
        _initializationError!,
        _initializationStackTrace!,
      );
    }

    final completer = Completer<T?>();
    final argumentsSnapshot = _snapshot(method, arguments);

    _pendingMethodCalls.add(_PendingMethodCall(
      dispatch: () =>
          _dispatchPendingMethodCall(method, argumentsSnapshot, completer),
      completeError: completer.completeError,
    ));

    return completer.future;
  }

  void _drainPendingMethodCalls() {
    _initializationState = _InitializationState.draining;

    // A dispatch can synchronously enqueue another call in tests or custom
    // channel implementations. Reading length on each iteration preserves FIFO
    // for those reentrant calls too.
    for (var index = 0; index < _pendingMethodCalls.length; index++) {
      _pendingMethodCalls[index].dispatch();
    }

    _pendingMethodCalls.clear();
    _initializationState = _InitializationState.ready;
  }

  void _completePendingMethodCallsWithError(
    Object error,
    StackTrace stackTrace,
  ) {
    _markInitializationFailed(error, stackTrace);
    for (final pendingMethodCall in _pendingMethodCalls) {
      pendingMethodCall.completeError(error, stackTrace);
    }
    _pendingMethodCalls.clear();
  }

  void _markInitializationFailed(Object error, StackTrace stackTrace) {
    _initializationState = _InitializationState.failed;
    _initializationError = error;
    _initializationStackTrace = stackTrace;
  }

  void _dispatchPendingMethodCall<T>(
    String method,
    Object? arguments,
    Completer<T?> completer,
  ) {
    try {
      final invocation = _channel.invokeMethod<T>(method, arguments);
      unawaited(invocation.then<void>(
        completer.complete,
        onError: (Object error, StackTrace stackTrace) {
          completer.completeError(error, stackTrace);
        },
      ));
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  }

  /// Android calls deferred during plugin registration must observe values as
  /// they were when the public method was called, just as an immediate channel
  /// invocation would. Round-trip through the channel's own codec so injected
  /// or custom channels keep their existing serialization behavior.
  Object? _snapshot(String method, Object? value) {
    final encoded = _channel.codec.encodeMethodCall(MethodCall(method, value));
    return _channel.codec.decodeMethodCall(encoded).arguments;
  }

  /// Tracks an event. Events are saved locally.
  ///
  /// Uploads are batched to occur every 30 events or every 30 seconds
  /// (whichever comes first), as well as on app close.
  ///
  /// ```
  /// amplitude.track(BaseEvent('Button Clicked'))
  /// ```
  Future<void> track(
    BaseEvent event, [
    EventOptions? options,
  ]) async {
    if (options != null) {
      event.mergeEventOptions(options);
    }

    return await _invokeMethod<void>('track',
        {'instanceName': configuration.instanceName, 'event': event.toMap()});
  }

  /// Updates user properties using operations provided via Identify API.
  ///
  /// Note that this will only affect only future events, and don't update historical events.
  ///
  /// To update user properties, first create an Identify object.
  ///
  /// Example: if you wanted to set a user's gender, increment their karma count by 1, you would do:
  /// ```
  /// final Identify identify = Identify()
  ///   ..set('gender','male')
  ///   ..add('karma', 1);
  /// amplitude.identify(identify);
  /// ```
  Future<void> identify(Identify identify, [EventOptions? options]) async {
    final event = IdentifyEvent();
    event.userProperties = identify.properties;

    if (options != null) {
      event.mergeEventOptions(options);
      if (options.userId != null) {
        // TODO(xinyi): make sure setUserId() is called on native platforms
        setUserId(options.userId!);
      }
      if (options.deviceId != null) {
        // TODO(xinyi): make sure setUserId() is called on native platforms
        setDeviceId(options.deviceId!);
      }
    }

    return await _invokeMethod<void>('identify',
        {'instanceName': configuration.instanceName, 'event': event.toMap()});
  }

  /// Updates the properties of particular groups.
  ///
  /// This feature is available in accounts with a Growth or Enterprise plan
  /// with the [Accounts add-on](https://help.amplitude.com/hc/en-us/articles/115001765532-Account-level-reporting-in-Amplitude).
  ///
  /// Note that this will only affect future events, and don't update historical events.
  ///
  /// Accepts a [groupType], a [groupName], an [identify] object that's applied to the group,
  /// and an optional [eventOptions]
  ///
  /// Example: if you wanted to set a key-value pair as a group property to the enterprise group with group type to be plan, you would do:
  /// ```
  /// final groupIdentifyEvent = Identify()
  ///   ..set('key1', 'value1');
  /// amplitude.groupIdentify('plan', 'enterprise', identify);
  /// ```
  Future<void> groupIdentify(
      String groupType, String groupName, Identify identify,
      [EventOptions? options]) async {
    final event = GroupIdentifyEvent();
    final group = <String, dynamic>{};
    group[groupType] = groupName;
    event.groups = group;
    event.groupProperties = identify.properties;
    if (options != null) {
      event.mergeEventOptions(options);
    }

    return await _invokeMethod<void>('groupIdentify',
        {'instanceName': configuration.instanceName, 'event': event.toMap()});
  }

  /// Adds a user to a group or groups. You need to specify a groupType and groupName(s).
  ///
  /// For example you can group people by their organization. In this case,
  /// groupType is 'orgId', and groupName would be the actual ID(s).
  /// groupName can be a string or an array of strings to indicate a user in multiple groups.
  ///
  /// ```
  /// amplitude.setGroup('orgId', '15');
  /// ```
  ///
  /// You can also call setGroup multiple times with different groupTypes to track
  /// multiple types of groups (up to 5 per app).
  /// Note: This will also set groupType: groupName as a user property.
  Future<void> setGroup(String groupType, dynamic groupName,
      [EventOptions? options]) async {
    if (groupName is! String && groupName is! List<String>) {
      // TODO(xinyi): log warn that groupName should be either a string or an array of string.
      return;
    }

    final identify = Identify().set(groupType, groupName);
    final event = IdentifyEvent()
      ..groups = {groupType: groupName}
      ..userProperties = identify.properties;

    if (options != null) {
      event.mergeEventOptions(options);
    }

    return await _invokeMethod<void>('setGroup',
        {'instanceName': configuration.instanceName, 'event': event.toMap()});
  }

  /// Tracks revenue generated by a user.
  ///
  /// Example:
  /// ```
  /// final revenue = Revenue()
  ///   ..price = 3.99
  ///   ..quantity = 3
  ///   ..productId = 'com.company.productId';
  /// amplitude.revenue(revenue);
  /// ```
  Future<void> revenue(Revenue revenue, [EventOptions? options]) async {
    if (!revenue.isValid()) {
      // TODO(xinyi): logger.warn('Invalid revenue object, missing required fields')
      return;
    }
    final event = revenue.toRevenueEvent();
    if (options != null) {
      event.mergeEventOptions(options);
    }

    return await _invokeMethod<void>('revenue',
        {'instanceName': configuration.instanceName, 'event': event.toMap()});
  }

  /// Get the current user Id.
  /// ```
  /// final userId = await amplitude.getUserId();
  /// ```
  Future<String?> getUserId() async {
    return await _invokeMethod<String>(
        'getUserId', {'instanceName': configuration.instanceName});
  }

  /// Set a custom user Id.
  ///
  /// If your app has its own login system that you want to track users with,
  /// you can set the userId.
  ///
  /// ```
  /// amplitude.setUserId('user Id');
  /// ```
  Future<void> setUserId(String? userId) async {
    Map<String, String?> properties = {};
    properties['setUserId'] = userId;

    return await _invokeMethod<void>('setUserId',
        {'instanceName': configuration.instanceName, 'properties': properties});
  }

  /// Get the current device ID.
  ///
  /// ```
  /// final deviceId = await amplitude.getDeviceId();
  /// ```
  Future<String?> getDeviceId() async {
    return await _invokeMethod<String>(
        'getDeviceId', {'instanceName': configuration.instanceName});
  }

  /// Sets a custom device ID.
  ///
  /// Make sure the value is sufficiently unique. Amplitude recommends using a UUID.
  ///
  /// ```
  /// amplitude.setDeviceId('device Id');
  /// ```
  Future<void> setDeviceId(String? deviceId) async {
    Map<String, String?> properties = {};
    properties['setDeviceId'] = deviceId;

    return await _invokeMethod<void>('setDeviceId',
        {'instanceName': configuration.instanceName, 'properties': properties});
  }

  /// Get the current session ID.
  ///
  /// ```
  /// final sessionId = await amplitude.getSessionId();
  /// ```
  Future<int?> getSessionId() async {
    return await _invokeMethod<int>(
        'getSessionId', {'instanceName': configuration.instanceName});
  }

  /// Disables tracking.
  ///
  /// Set setOptOut to true to disable logging for a specific user.
  /// Set setOptOut to false to re-enable logging.
  Future<void> setOptOut(bool enabled) async {
    Map<String, bool> properties = {};
    properties['setOptOut'] = enabled;

    return await _invokeMethod<void>('setOptOut',
        {'instanceName': configuration.instanceName, 'properties': properties});
  }

  /// Resets userId to 'null' and deviceId to a random UUID.
  ///
  /// Note different devices on different platforms should have different device Ids.
  Future<void> reset() async {
    return await _invokeMethod<void>(
        'reset', {'instanceName': configuration.instanceName});
  }

  /// Flush events in storage.
  Future<void> flush() async {
    return await _invokeMethod<void>(
        'flush', {'instanceName': configuration.instanceName});
  }
}
