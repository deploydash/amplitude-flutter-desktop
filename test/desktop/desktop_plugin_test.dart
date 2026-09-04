import 'dart:convert';

import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/desktop/desktop_backend.dart';
import 'package:amplitude_flutter/desktop/desktop_compress.dart';
import 'package:amplitude_flutter/desktop/desktop_plugin.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:amplitude_flutter/desktop/desktop_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Channel wiring for the pure-Dart desktop backend (plan §H.8).
//
// WHY this test drives the handler directly: the plugin is a static
// `registerWith()` plus a `handleMethodCall` (the `amplitude_web.dart`
// shape). The generated registrant owns the channel, so unit tests call the
// handler with `MethodCall`s — one per channel method — against backends
// with in-memory storage and a scripted `MockClient`.

class DesktopPluginHarness {
  DesktopPluginHarness(this.plugin, this.requests, this.backends);
  final DesktopAmplitudePlugin plugin;
  final List<http.BaseRequest> requests;
  final List<DesktopBackend> backends;
}

DesktopPluginHarness makeHarness() {
  final requests = <http.BaseRequest>[];
  final backends = <DesktopBackend>[];
  final plugin = DesktopAmplitudePlugin(
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
  return DesktopPluginHarness(plugin, requests, backends);
}

Map<String, dynamic> initArgs({String instance = 'test'}) {
  return Map<String, dynamic>.from(
    Configuration(apiKey: 'test-key', instanceName: instance).toMap(),
  );
}

Map<String, dynamic> decodeUpload(http.BaseRequest request) {
  final raw = (request as http.Request).bodyBytes;
  final gzipped = request.headers['Content-Encoding'] == 'gzip';
  final jsonText = gzipped
      ? utf8.decode(defaultDesktopCompressor.decode(raw))
      : utf8.decode(raw);
  return json.decode(jsonText) as Map<String, dynamic>;
}

Future<dynamic> call(
  DesktopAmplitudePlugin plugin,
  String method, [
  Map<String, dynamic>? arguments,
]) {
  return plugin.handleMethodCall(MethodCall(method, arguments));
}

void main() {
  late DesktopPluginHarness harness;

  setUp(() {
    harness = makeHarness();
  });

  tearDown(() async {
    for (final backend in harness.backends) {
      await backend.dispose();
    }
  });

  group('DesktopAmplitudePlugin channel wiring', () {
    test(r'init stores the backend; track/flush delivers with api_key',
        () async {
      await call(harness.plugin, 'init', initArgs());
      await call(harness.plugin, 'track', {
        'instanceName': 'test',
        'event': {'event_type': 'clicked'},
      });
      await call(harness.plugin, 'flush', {'instanceName': 'test'});

      expect(harness.requests, hasLength(1));
      final payload = decodeUpload(harness.requests.single);
      expect(payload['api_key'], 'test-key');
      expect(
        (payload['events'] as List).map((e) => (e as Map)['event_type']),
        contains('clicked'),
      );
    });

    test('identify/groupIdentify/setGroup/revenue enqueue without throwing',
        () async {
      await call(harness.plugin, 'init', initArgs());
      await call(harness.plugin, 'identify', {
        'instanceName': 'test',
        'event': {
          'event_type': r'$identify',
          'user_properties': {
            r'$set': {'plan': 'pro'}
          },
        },
      });
      await call(harness.plugin, 'groupIdentify', {
        'instanceName': 'test',
        'event': {
          'event_type': r'$groupidentify',
          'groups': {'org': 'acme'},
        },
      });
      await call(harness.plugin, 'setGroup', {
        'instanceName': 'test',
        'event': {
          'event_type': r'$identify',
          'groups': {'org': 'acme'},
        },
      });
      await call(harness.plugin, 'revenue', {
        'instanceName': 'test',
        'event': {'event_type': 'revenue_amount', 'price': 3.99},
      });
      await call(harness.plugin, 'flush', {'instanceName': 'test'});

      expect(harness.requests, hasLength(1));
      final types = [
        for (final event
            in (decodeUpload(harness.requests.single)['events'] as List))
          (event as Map)['event_type'],
      ];
      expect(types, contains(r'$groupidentify'));
      expect(types, contains('revenue_amount'));
    });

    test('identity reads round-trip through the channel', () async {
      await call(harness.plugin, 'init', initArgs());
      expect(
        await call(harness.plugin, 'getSessionId', {'instanceName': 'test'}),
        -1,
      );

      await call(harness.plugin, 'setUserId', {
        'instanceName': 'test',
        'properties': {'setUserId': 'user-1'},
      });
      expect(
        await call(harness.plugin, 'getUserId', {'instanceName': 'test'}),
        'user-1',
      );

      await call(harness.plugin, 'setDeviceId', {
        'instanceName': 'test',
        'properties': {'setDeviceId': 'device-1'},
      });
      expect(
        await call(harness.plugin, 'getDeviceId', {'instanceName': 'test'}),
        'device-1',
      );

      await call(harness.plugin, 'track', {
        'instanceName': 'test',
        'event': {'event_type': 'clicked'},
      });
      final sessionId = await call(
        harness.plugin,
        'getSessionId',
        {'instanceName': 'test'},
      );
      expect(sessionId, isA<int>());
      expect(sessionId, greaterThanOrEqualTo(0));
    });

    test('setOptOut drops tracks and no-ops flush', () async {
      await call(harness.plugin, 'init', initArgs());
      await call(harness.plugin, 'setOptOut', {
        'instanceName': 'test',
        'properties': {'setOptOut': true},
      });
      await call(harness.plugin, 'track', {
        'instanceName': 'test',
        'event': {'event_type': 'clicked'},
      });
      await call(harness.plugin, 'flush', {'instanceName': 'test'});
      expect(harness.requests, isEmpty);
    });

    test('reset rotates the device id', () async {
      await call(harness.plugin, 'init', initArgs());
      final before =
          await call(harness.plugin, 'getDeviceId', {'instanceName': 'test'});
      await call(harness.plugin, 'reset', {'instanceName': 'test'});
      final after =
          await call(harness.plugin, 'getDeviceId', {'instanceName': 'test'});
      expect(before, isNotNull);
      expect(after, isNot(before));
      expect(
        await call(harness.plugin, 'getUserId', {'instanceName': 'test'}),
        isNull,
      );
    });

    test('reads before init resolve null/-1 and writes drop, never hanging',
        () async {
      expect(
        await call(harness.plugin, 'getUserId', {'instanceName': 'missing'})
            .timeout(const Duration(seconds: 5)),
        isNull,
      );
      expect(
        await call(harness.plugin, 'getDeviceId', {'instanceName': 'missing'})
            .timeout(const Duration(seconds: 5)),
        isNull,
      );
      expect(
        await call(harness.plugin, 'getSessionId', {'instanceName': 'missing'})
            .timeout(const Duration(seconds: 5)),
        -1,
      );
      await call(harness.plugin, 'track', {
        'instanceName': 'missing',
        'event': {'event_type': 'clicked'},
      }).timeout(const Duration(seconds: 5));
      await call(harness.plugin, 'flush', {'instanceName': 'missing'})
          .timeout(const Duration(seconds: 5));
      expect(harness.requests, isEmpty);
      expect(harness.backends, isEmpty);
    });

    test('instances are namespaced by instanceName', () async {
      await call(harness.plugin, 'init', initArgs(instance: 'a'));
      await call(harness.plugin, 'init', initArgs(instance: 'b'));
      await call(harness.plugin, 'setUserId', {
        'instanceName': 'a',
        'properties': {'setUserId': 'alice'},
      });
      expect(
        await call(harness.plugin, 'getUserId', {'instanceName': 'a'}),
        'alice',
      );
      expect(
        await call(harness.plugin, 'getUserId', {'instanceName': 'b'}),
        isNull,
      );
      expect(
        await call(harness.plugin, 'getDeviceId', {'instanceName': 'a'}),
        isNot(await call(harness.plugin, 'getDeviceId', {'instanceName': 'b'})),
      );
    });

    test('init without an apiKey refuses and stores nothing', () async {
      final args = initArgs()..['apiKey'] = '';
      expect(await call(harness.plugin, 'init', args), isNull);
      expect(harness.plugin.instances, isEmpty);
      expect(harness.requests, isEmpty);
    });

    test('re-init disposes the replaced backend', () async {
      await call(harness.plugin, 'init', initArgs());
      final first = harness.plugin.instances['test']!;
      await call(harness.plugin, 'init', initArgs());
      final second = harness.plugin.instances['test']!;
      expect(second, isNot(same(first)));
      expect(harness.backends, hasLength(2));
      // The old backend is retired: only the new one serves reads.
      await call(harness.plugin, 'setUserId', {
        'instanceName': 'test',
        'properties': {'setUserId': 'fresh'},
      });
      expect(await second.getUserId(), 'fresh');
    });

    test('unknown methods throw Unimplemented like the web backend', () async {
      await call(harness.plugin, 'init', initArgs());
      expect(
        () => call(harness.plugin, 'teleport', {'instanceName': 'test'}),
        throwsA(isA<PlatformException>()),
      );
    });

    test('registerWith wires the channel end to end', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('amplitude_flutter');
      // Registration itself must not throw (the generated Linux/Windows
      // registrant calls this exact zero-arg shape).
      DesktopAmplitudePlugin.registerWith();
      // Outgoing channel calls do not loop back into `setMethodCallHandler`
      // in tests, so wire the handler as the mock platform side: this still
      // exercises the real channel codec for every argument map.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          channel, harness.plugin.handleMethodCall);
      try {
        await channel.invokeMethod('init', initArgs(instance: 'wired'));
        await channel.invokeMethod('track', {
          'instanceName': 'wired',
          'event': {'event_type': 'clicked'},
        });
        await channel.invokeMethod('flush', {'instanceName': 'wired'});
        final deviceId = await channel
            .invokeMethod<String?>('getDeviceId', {'instanceName': 'wired'});
        expect(deviceId, isNotNull);
        expect(harness.requests, hasLength(1));
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  });
}
