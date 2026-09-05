import 'dart:io';

import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/desktop/desktop_backend.dart';
import 'package:amplitude_flutter/desktop/desktop_direct.dart'
    as desktop_default;
import 'package:amplitude_flutter/desktop/desktop_direct_io.dart'
    as desktop_direct;
import 'package:amplitude_flutter/desktop/desktop_plugin.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:amplitude_flutter/desktop/desktop_transport.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// In-process desktop routing for the public `Amplitude` API.
//
// WHY these tests exist: on Linux/Windows the engine-backed binary
// messenger cannot deliver a Dart `invokeMethod` to a Dart
// `setMethodCallHandler` (MissingPluginException on a real run), so the
// public API routes to the in-process desktop backend directly. These
// tests prove the routing per platform: Linux/Windows never touch the
// channel, everything else passes through untouched.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.BaseRequest> requests;
  late List<DesktopBackend> backends;
  late TargetPlatform? savedPlatform;
  late MethodChannel channel;
  var channelCalls = 0;

  DesktopAmplitudePlugin makePlugin() {
    return DesktopAmplitudePlugin(
      backendFactory: () {
        final backend = DesktopBackend(
          storage: InMemoryDesktopStorage(),
          transport: DesktopTransport(
            client: MockClient((request) async {
              requests.add(request);
              return http.Response('{}', 200);
            }),
          ),
        );
        backends.add(backend);
        return backend;
      },
    );
  }

  setUp(() {
    requests = [];
    backends = [];
    savedPlatform = debugDefaultTargetPlatformOverride;
    channelCalls = 0;
    desktop_direct.resetDesktopDirectForTests();
    desktop_direct.debugDirectPluginFactory = makePlugin;
    channel = const MethodChannel('amplitude_flutter');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          channelCalls += 1;
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = savedPlatform;
    desktop_direct.resetDesktopDirectForTests();
    for (final backend in backends) {
      await backend.dispose();
    }
  });

  Amplitude newAmplitude() => Amplitude(
    Configuration(
      apiKey: 'direct-key',
      instanceName: 'direct-test',
      flushIntervalMillis: 3600000,
    ),
    channel,
  );

  test('linux routes in-process without touching the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final amplitude = newAmplitude();
    expect(await amplitude.isBuilt, isTrue);
    await amplitude.track(BaseEvent('direct_event'));
    await amplitude.flush();

    expect(
      channelCalls,
      0,
      reason: 'desktop calls must not cross the engine channel',
    );
    expect(requests, hasLength(1));
  });

  test('windows routes in-process without touching the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final amplitude = newAmplitude();
    expect(await amplitude.isBuilt, isTrue);
    await amplitude.track(BaseEvent('direct_event'));
    await amplitude.flush();

    expect(channelCalls, 0);
    expect(requests, hasLength(1));
  });

  test('other platforms keep using the channel untouched', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final amplitude = newAmplitude();
    expect(await amplitude.isBuilt, isTrue);
    await amplitude.track(BaseEvent('channel_event'));
    await amplitude.flush();

    expect(channelCalls, greaterThan(0));
    expect(requests, isEmpty);
  });

  test('production plugin creation serves calls end to end', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final support = await Directory.systemTemp.createTemp('amplitude-direct-');
    const provider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(provider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return support.path;
      }
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    desktop_direct.debugDirectPluginFactory = null;
    try {
      final amplitude = newAmplitude();
      expect(await amplitude.isBuilt, isTrue);
      // Queued only: flushing would hit the real network.
      await amplitude.track(BaseEvent('prod_event'));

      expect(channelCalls, 0);
    } finally {
      messenger.setMockMethodCallHandler(provider, null);
      await support.delete(recursive: true);
    }
  });

  test('the default variant passes calls to the channel untouched', () async {
    final result = await desktop_default.invokeDesktopMethod(channel, 'ping', {
      'key': 'value',
    });
    expect(channelCalls, 1);
    expect(result, isNull);
  });
}
