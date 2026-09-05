import 'dart:convert';

import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/desktop/desktop_backend.dart';
import 'package:amplitude_flutter/desktop/desktop_compress.dart';
import 'package:amplitude_flutter/desktop/desktop_plugin.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:amplitude_flutter/desktop/desktop_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Transport that records close(): proves hot-restart retires the previous
// plugin's backends (their timers/clients must not survive re-registration).
class RecordingCloseTransport extends DesktopTransport {
  RecordingCloseTransport({required super.client, required this.onClose});

  final void Function() onClose;
  bool closed = false;

  @override
  void close() {
    closed = true;
    onClose();
    super.close();
  }
}

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

/// Fake lifecycle source: tests drive states with explicit timestamps.
class FakeLifecycleSource implements DesktopLifecycleSource {
  FakeLifecycleSource([this.currentState = AppLifecycleState.resumed]);

  @override
  AppLifecycleState currentState;

  void Function(AppLifecycleState state, int timestampMs)? _onState;
  int stops = 0;

  @override
  void start(void Function(AppLifecycleState state, int timestampMs) onState) {
    _onState = onState;
  }

  @override
  void stop() {
    stops += 1;
    _onState = null;
  }

  void fire(AppLifecycleState state, int timestampMs) {
    _onState?.call(state, timestampMs);
  }
}

/// Lifecycle source whose observation fails: proves the plugin still
/// serves method calls when the binding is not ready at attach time.
class ThrowingLifecycleSource implements DesktopLifecycleSource {
  @override
  AppLifecycleState get currentState => throw StateError('no binding');

  @override
  void start(void Function(AppLifecycleState state, int timestampMs) onState) {
    throw StateError('no binding');
  }

  @override
  void stop() {}
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
    test(
      r'init stores the backend; track/flush delivers with api_key',
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
      },
    );

    test(
      'identify/groupIdentify/setGroup/revenue enqueue without throwing',
      () async {
        await call(harness.plugin, 'init', initArgs());
        await call(harness.plugin, 'identify', {
          'instanceName': 'test',
          'event': {
            'event_type': r'$identify',
            'user_properties': {
              r'$set': {'plan': 'pro'},
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
      },
    );

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
      final sessionId = await call(harness.plugin, 'getSessionId', {
        'instanceName': 'test',
      });
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
      final before = await call(harness.plugin, 'getDeviceId', {
        'instanceName': 'test',
      });
      await call(harness.plugin, 'reset', {'instanceName': 'test'});
      final after = await call(harness.plugin, 'getDeviceId', {
        'instanceName': 'test',
      });
      expect(before, isNotNull);
      expect(after, isNot(before));
      expect(
        await call(harness.plugin, 'getUserId', {'instanceName': 'test'}),
        isNull,
      );
    });

    test(
      'reads before init resolve null/-1 and writes drop, never hanging',
      () async {
        expect(
          await call(harness.plugin, 'getUserId', {
            'instanceName': 'missing',
          }).timeout(const Duration(seconds: 5)),
          isNull,
        );
        expect(
          await call(harness.plugin, 'getDeviceId', {
            'instanceName': 'missing',
          }).timeout(const Duration(seconds: 5)),
          isNull,
        );
        expect(
          await call(harness.plugin, 'getSessionId', {
            'instanceName': 'missing',
          }).timeout(const Duration(seconds: 5)),
          -1,
        );
        await call(harness.plugin, 'track', {
          'instanceName': 'missing',
          'event': {'event_type': 'clicked'},
        }).timeout(const Duration(seconds: 5));
        await call(harness.plugin, 'flush', {
          'instanceName': 'missing',
        }).timeout(const Duration(seconds: 5));
        expect(harness.requests, isEmpty);
        expect(harness.backends, isEmpty);
      },
    );

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

    test('unknown methods throw Unimplemented before init too', () async {
      expect(
        () => call(harness.plugin, 'teleport', {'instanceName': 'missing'}),
        throwsA(isA<PlatformException>()),
      );
    });

    test('hot restart disposes the previous plugin backends', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final closed = <RecordingCloseTransport>[];
      final created = <DesktopBackend>[];
      final previousFactory = DesktopAmplitudePlugin.debugBackendFactory;
      DesktopAmplitudePlugin.debugBackendFactory = () {
        final transport = RecordingCloseTransport(
          client: MockClient((request) async => http.Response('{}', 200)),
          onClose: () {},
        );
        closed.add(transport);
        final backend = DesktopBackend(
          storage: InMemoryDesktopStorage(),
          transport: transport,
        );
        created.add(backend);
        return backend;
      };
      const channel = MethodChannel('amplitude_flutter');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      try {
        DesktopAmplitudePlugin.registerWith();
        final first = DesktopAmplitudePlugin.activePluginForTests!;
        await first.handleMethodCall(MethodCall('init', initArgs()));
        expect(created, hasLength(1));

        // Hot restart re-runs the registrant: the first plugin's backends
        // must be retired so their flush timers cannot double-upload.
        DesktopAmplitudePlugin.registerWith();
        await Future<void>.delayed(Duration.zero);
        expect(closed, hasLength(1));
        expect(closed.single.closed, isTrue);
        expect(first.instances, isEmpty);
        for (final backend in created) {
          await backend.dispose();
        }
      } finally {
        DesktopAmplitudePlugin.debugBackendFactory = previousFactory;
        messenger.setMockMethodCallHandler(channel, null);
      }
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
        channel,
        harness.plugin.handleMethodCall,
      );
      try {
        await channel.invokeMethod('init', initArgs(instance: 'wired'));
        await channel.invokeMethod('track', {
          'instanceName': 'wired',
          'event': {'event_type': 'clicked'},
        });
        await channel.invokeMethod('flush', {'instanceName': 'wired'});
        final deviceId = await channel.invokeMethod<String?>('getDeviceId', {
          'instanceName': 'wired',
        });
        expect(deviceId, isNotNull);
        expect(harness.requests, hasLength(1));
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  });

  group('DesktopAmplitudePlugin lifecycle', () {
    DesktopAmplitudePlugin makeLifecyclePlugin(
      FakeLifecycleSource source,
      List<http.BaseRequest> requests,
      List<DesktopBackend> backends,
    ) {
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
        lifecycleSource: source,
      );
    }

    test('hidden then resumed exits and enters with timestamps', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource();
      final plugin = makeLifecyclePlugin(source, requests, backends);
      try {
        await call(plugin, 'init', initArgs());
        await call(plugin, 'track', {
          'instanceName': 'test',
          'event': {'event_type': 'a'},
        });
        final first = await call(plugin, 'getSessionId', {
          'instanceName': 'test',
        });

        await plugin.handleLifecycleForTests(AppLifecycleState.hidden, 2000);
        await plugin.handleLifecycleForTests(AppLifecycleState.resumed, 9000);

        await call(plugin, 'flush', {'instanceName': 'test'});
        expect(harness.requests, isEmpty);
        expect(requests, isNotEmpty);
        // Default 5-minute gap: 2 s to 9 s is within gap, session extends.
        expect(
          await call(plugin, 'getSessionId', {'instanceName': 'test'}),
          first,
        );
      } finally {
        await plugin.dispose();
      }
    });

    test('repeated states deduplicate; inactive never exits', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource();
      final plugin = makeLifecyclePlugin(source, requests, backends);
      try {
        await call(plugin, 'init', initArgs());
        await call(plugin, 'track', {
          'instanceName': 'test',
          'event': {'event_type': 'a'},
        });
        final first = await call(plugin, 'getSessionId', {
          'instanceName': 'test',
        });

        await plugin.handleLifecycleForTests(AppLifecycleState.hidden, 1000);
        await plugin.handleLifecycleForTests(AppLifecycleState.paused, 1100);
        await plugin.handleLifecycleForTests(AppLifecycleState.resumed, 1200);
        await plugin.handleLifecycleForTests(AppLifecycleState.resumed, 1300);
        await plugin.handleLifecycleForTests(AppLifecycleState.inactive, 1400);

        // Within gap, no rotation despite duplicate exits/enters; inactive
        // is not a boundary.
        expect(
          await call(plugin, 'getSessionId', {'instanceName': 'test'}),
          first,
        );
      } finally {
        await plugin.dispose();
      }
    });

    test('all instances receive each transition once', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource();
      final plugin = makeLifecyclePlugin(source, requests, backends);
      try {
        await call(plugin, 'init', initArgs(instance: 'a'));
        await call(plugin, 'init', initArgs(instance: 'b'));
        await plugin.handleLifecycleForTests(AppLifecycleState.hidden, 1000);
        await plugin.handleLifecycleForTests(AppLifecycleState.resumed, 2000);
        expect(backends, hasLength(2));
      } finally {
        await plugin.dispose();
      }
    });

    test(
      'init while hidden starts background; resume rotates past gap',
      () async {
        final requests = <http.BaseRequest>[];
        final backends = <DesktopBackend>[];
        final source = FakeLifecycleSource(AppLifecycleState.hidden);
        final plugin = makeLifecyclePlugin(source, requests, backends);
        try {
          await call(plugin, 'init', initArgs());
          await call(plugin, 'track', {
            'instanceName': 'test',
            'event': {'event_type': 'a'},
          });
          final first = await call(plugin, 'getSessionId', {
            'instanceName': 'test',
          });

          // 10 minutes later (past the 5-minute gap): resume rotates.
          final resumeMs =
              DateTime.now().millisecondsSinceEpoch + 10 * 60 * 1000;
          await plugin.handleLifecycleForTests(
            AppLifecycleState.resumed,
            resumeMs,
          );
          await call(plugin, 'track', {
            'instanceName': 'test',
            'event': {'event_type': 'b'},
          });
          expect(
            await call(plugin, 'getSessionId', {'instanceName': 'test'}),
            isNot(first),
          );

          await call(plugin, 'flush', {'instanceName': 'test'});
          final types = [
            for (final r in requests)
              for (final e in (decodeUpload(r)['events'] as List))
                (e as Map)['event_type'] as String,
          ];
          expect(types, contains('session_end'));
          expect(
            types.lastIndexOf('session_start'),
            greaterThan(types.indexOf('session_end')),
          );
        } finally {
          await plugin.dispose();
        }
      },
    );

    test('dispose is idempotent and stops observations', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource();
      final plugin = makeLifecyclePlugin(source, requests, backends);
      await call(plugin, 'init', initArgs());
      await plugin.dispose();
      await plugin.dispose();
      expect(source.stops, greaterThanOrEqualTo(1));
      expect(plugin.instances, isEmpty);
      final before = requests.length;
      source.fire(AppLifecycleState.hidden, 9999);
      await Future<void>.delayed(Duration.zero);
      expect(
        requests.length,
        before,
        reason: 'disposed plugin forwards nothing',
      );
    });

    test('hot restart retires the old observer with its backends', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final firstSource = FakeLifecycleSource();
      final first = makeLifecyclePlugin(firstSource, requests, backends);
      await call(first, 'init', initArgs());
      await first.dispose();

      expect(firstSource.stops, greaterThanOrEqualTo(1));
      expect(first.instances, isEmpty);
      // Old backends receive no later lifecycle: firing is a no-op.
      firstSource.fire(AppLifecycleState.resumed, 9999);
      await Future<void>.delayed(Duration.zero);
    });

    test('detached flushes once, stops, and ignores later states', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource();
      final plugin = makeLifecyclePlugin(source, requests, backends);
      try {
        await call(plugin, 'init', initArgs());
        await call(plugin, 'track', {
          'instanceName': 'test',
          'event': {'event_type': 'a'},
        });
        await plugin.handleLifecycleForTests(AppLifecycleState.detached, 5000);
        final afterDetach = requests.length;
        expect(afterDetach, greaterThanOrEqualTo(1));

        await plugin.handleLifecycleForTests(AppLifecycleState.resumed, 6000);
        await Future<void>.delayed(Duration.zero);
        expect(
          requests.length,
          afterDetach,
          reason: 'states after detached are ignored',
        );
        expect(source.stops, greaterThanOrEqualTo(1));
      } finally {
        await plugin.dispose();
      }
    });

    test('source-driven transitions reach backends', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource();
      final plugin = makeLifecyclePlugin(source, requests, backends);
      try {
        await call(plugin, 'init', initArgs());
        await call(plugin, 'track', {
          'instanceName': 'test',
          'event': {'event_type': 'a'},
        });
        source.fire(AppLifecycleState.hidden, 1000);
        await Future<void>.delayed(Duration.zero);
        source.fire(AppLifecycleState.resumed, 2000);
        await Future<void>.delayed(Duration.zero);
        expect(
          await call(plugin, 'getSessionId', {'instanceName': 'test'}),
          isNot(-1),
        );
      } finally {
        await plugin.dispose();
      }
    });

    test('paused initial state starts background', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource(AppLifecycleState.paused);
      final plugin = makeLifecyclePlugin(source, requests, backends);
      try {
        await call(plugin, 'init', initArgs());
        // First track processes as background (no crash, session opens).
        await call(plugin, 'track', {
          'instanceName': 'test',
          'event': {'event_type': 'a'},
        });
        expect(
          await call(plugin, 'getSessionId', {'instanceName': 'test'}),
          isNot(-1),
        );
      } finally {
        await plugin.dispose();
      }
    });

    test('detached initial state starts background', () async {
      final requests = <http.BaseRequest>[];
      final backends = <DesktopBackend>[];
      final source = FakeLifecycleSource(AppLifecycleState.detached);
      final plugin = makeLifecyclePlugin(source, requests, backends);
      try {
        await call(plugin, 'init', initArgs());
        await call(plugin, 'track', {
          'instanceName': 'test',
          'event': {'event_type': 'a'},
        });
        expect(
          await call(plugin, 'getSessionId', {'instanceName': 'test'}),
          isNot(-1),
        );
      } finally {
        await plugin.dispose();
      }
      expect(source.stops, greaterThanOrEqualTo(1));
    });

    test('an unobservable lifecycle still serves method calls', () async {
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
        lifecycleSource: ThrowingLifecycleSource(),
      );
      try {
        await call(plugin, 'init', initArgs());
        await call(plugin, 'track', {
          'instanceName': 'test',
          'event': {'event_type': 'a'},
        });
        await call(plugin, 'flush', {'instanceName': 'test'});
        expect(requests, hasLength(1));
      } finally {
        await plugin.dispose();
        for (final backend in backends) {
          await backend.dispose();
        }
      }
    });

    test('detached without a source still exits backends', () async {
      final plugin = DesktopAmplitudePlugin(
        backendFactory: () {
          final backend = DesktopBackend(
            storage: InMemoryDesktopStorage(),
            transport: DesktopTransport(
              client: MockClient((request) async => http.Response('{}', 200)),
            ),
          );
          return backend;
        },
      );
      try {
        await call(plugin, 'init', initArgs());
        await plugin.handleLifecycleForTests(AppLifecycleState.detached, 1000);
        await plugin.handleLifecycleForTests(AppLifecycleState.resumed, 2000);
      } finally {
        await plugin.dispose();
      }
    });

    test('disposing the active plugin clears the channel owner', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final previousFactory = DesktopAmplitudePlugin.debugBackendFactory;
      DesktopAmplitudePlugin.debugBackendFactory = () => DesktopBackend(
        storage: InMemoryDesktopStorage(),
        transport: DesktopTransport(
          client: MockClient((request) async => http.Response('{}', 200)),
        ),
      );
      try {
        DesktopAmplitudePlugin.registerWith();
        final active = DesktopAmplitudePlugin.activePluginForTests!;
        await active.dispose();
        expect(DesktopAmplitudePlugin.activePluginForTests, isNull);
      } finally {
        DesktopAmplitudePlugin.debugBackendFactory = previousFactory;
      }
    });
  });

  group('WidgetsBindingLifecycleSource', () {
    test('reports binding state, forwards with clock, stops cleanly', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      var clockCalls = 0;
      final source = WidgetsBindingLifecycleSource(
        clock: () {
          clockCalls += 1;
          return 4242;
        },
      );
      expect(source.currentState, isA<AppLifecycleState>());

      AppLifecycleState? seen;
      int? seenMs;
      source.start((state, ms) {
        seen = state;
        seenMs = ms;
      });
      source.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(seen, AppLifecycleState.hidden);
      expect(seenMs, 4242);
      expect(clockCalls, 1);

      source.stop();
      seen = null;
      source.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(seen, isNull);
    });

    test('default clock uses wall time', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final source = WidgetsBindingLifecycleSource();
      int? seenMs;
      source.start((_, ms) => seenMs = ms);
      final before = DateTime.now().millisecondsSinceEpoch;
      source.didChangeAppLifecycleState(AppLifecycleState.paused);
      source.stop();
      expect(seenMs, greaterThanOrEqualTo(before));
    });
  });
}
