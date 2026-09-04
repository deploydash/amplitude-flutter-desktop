import 'dart:async';
import 'dart:convert';

import 'package:amplitude_flutter/desktop/desktop_backend.dart';
import 'package:amplitude_flutter/desktop/desktop_compress.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:amplitude_flutter/desktop/desktop_system_info.dart';
import 'package:amplitude_flutter/desktop/desktop_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeClock {
  int nowMs = 1700000000000;
  int call() => nowMs;
}

const fakeOs = DesktopOsInfo(
  platform: 'Linux',
  osName: 'linux',
  osVersion: '24.04',
  deviceModel: 'Ubuntu',
  deviceManufacturer: null,
);
const fakeApp = DesktopAppVersion(appVersion: '1.2.3', versionName: '1.2.3');

class FakeSystemInfo implements DesktopSystemInfoSource {
  @override
  Future<DesktopOsInfo> currentOs() async => fakeOs;
}

class FakeAppInfo implements DesktopAppInfoSource {
  @override
  Future<DesktopAppVersion> current() async => fakeApp;
}

class Terminal {
  Terminal(this.eventType, this.code, this.message);
  final String? eventType;
  final int code;
  final String message;
}

Map<String, dynamic> configMap({
  int flushQueueSize = 1000,
  int flushMaxRetries = 5,
}) {
  return {
    'apiKey': 'test-key',
    'flushQueueSize': flushQueueSize,
    'flushIntervalMillis': 3600000,
    'instanceName': 'test',
    'optOut': false,
    'logLevel': 'off',
    'minIdLength': null,
    'partnerId': null,
    'flushMaxRetries': flushMaxRetries,
    'useBatch': false,
    'serverZone': 'us',
    'serverUrl': null,
    'minTimeBetweenSessionsMillis': 300000,
    'trackingOptions': <String, bool>{},
    'enableCoppaControl': false,
    'flushEventsOnClose': true,
    'identifyBatchIntervalMillis': 30000,
  };
}

/// Decodes a captured upload request body (gunzipping when needed).
Map<String, dynamic> decodeUpload(http.BaseRequest request) {
  final raw = (request as http.Request).bodyBytes;
  final gzipped = request.headers['Content-Encoding'] == 'gzip';
  final jsonText = gzipped
      ? utf8.decode(defaultDesktopCompressor.decode(raw))
      : utf8.decode(raw);
  return json.decode(jsonText) as Map<String, dynamic>;
}

/// Storage that lists one phantom file which reads as null: the
/// listed-but-unreadable case (corrupt prefs envelope). Quarantining the
/// phantom hides it.
class _PhantomStorage extends InMemoryDesktopStorage {
  _PhantomStorage(int Function() clock) : super(clock: clock);

  bool quarantined = false;

  @override
  Future<List<String>> listFilesOldestFirst() async {
    final real = await super.listFilesOldestFirst();
    if (quarantined) {
      return real;
    }
    return [...real, 'v2-phantom'];
  }

  @override
  Future<String?> readFile(String name) async {
    if (name == 'v2-phantom') {
      return null;
    }
    return super.readFile(name);
  }

  @override
  Future<int?> fileCreatedAt(String name) async {
    if (name == 'v2-phantom') {
      return null;
    }
    return super.fileCreatedAt(name);
  }

  @override
  Future<void> quarantineFile(String name) async {
    if (name == 'v2-phantom') {
      quarantined = true;
      return;
    }
    return super.quarantineFile(name);
  }
}

void main() {
  late FakeClock clock;
  late InMemoryDesktopStorage storage;
  late List<http.BaseRequest> requests;
  late List<int> statuses;
  late List<http.Response Function()> script;
  late List<Terminal> terminals;
  late List<Duration> sleeps;
  late List<String> logs;
  late List<DesktopBackend> backends;

  setUp(() {
    clock = FakeClock();
    storage = InMemoryDesktopStorage(clock: clock.call);
    requests = [];
    statuses = [];
    script = [];
    terminals = [];
    sleeps = [];
    logs = [];
    backends = [];
  });

  tearDown(() async {
    for (final backend in backends) {
      await backend.dispose();
    }
  });

  DesktopTransport makeTransport({Duration? timeout}) {
    return DesktopTransport(
      client: MockClient((request) async {
        requests.add(request);
        final response =
            script.isEmpty ? http.Response('{}', 200) : script.removeAt(0)();
        statuses.add(response.statusCode);
        return response;
      }),
      requestTimeout: timeout ?? const Duration(seconds: 60),
    );
  }

  Future<DesktopBackend> makeBackend({
    DesktopTransport? transport,
    Duration reprobeInterval = const Duration(hours: 6),
    Map<String, dynamic>? config,
  }) async {
    final backend = DesktopBackend(
      storage: storage,
      systemInfo: FakeSystemInfo(),
      appInfo: FakeAppInfo(),
      transport: transport ?? makeTransport(),
      clock: clock.call,
      sleeper: (duration) async {
        sleeps.add(duration);
      },
      offlineReprobeInterval: reprobeInterval,
      onTerminalEvent: (event, code, message) {
        terminals.add(Terminal(event['event_type'] as String?, code, message));
      },
      logger: logs.add,
    );
    backends.add(backend);
    expect(await backend.init(config ?? configMap()), isTrue);
    return backend;
  }

  List<String> uploadedEventTypes() {
    return [
      for (final request in requests)
        for (final event in (decodeUpload(request)['events'] as List))
          (event as Map)['event_type'] as String,
    ];
  }

  group('pipeline', () {
    test('success uploads oldest-first and fires callbacks', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await backend.flush();

      expect(requests, hasLength(1));
      final payload = decodeUpload(requests.single);
      expect(payload['api_key'], 'test-key');
      expect(
        (payload['events'] as List).map((e) => (e as Map)['event_type']),
        ['session_start', 'a'],
      );
      expect(terminals.map((t) => t.code), [200, 200]);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('rapid funnel tracks upload in arrival order', () async {
      final backend = await makeBackend();
      // Deliberately unawaited between calls: the serial chain must still
      // preserve invocation order end to end.
      final pending = [
        backend.track({'event_type': 'started'}),
        backend.track({'event_type': 'step'}),
        backend.track({'event_type': 'completed'}),
      ];
      await Future.wait(pending);
      await backend.flush();

      expect(requests, hasLength(1));
      expect(uploadedEventTypes(),
          ['session_start', 'started', 'step', 'completed']);
    });

    test('400 with indexes drops only those events and requeues the rest',
        () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      script.add(() => http.Response(
          '{"events_with_invalid_fields": {"event_type": [1]}}', 400));
      await backend.flush();

      expect(terminals.map((t) => '${t.eventType}:${t.code}'), ['a:400']);
      // The surviving session_start stays queued.
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      await backend.flush();
      expect(requests, hasLength(2));
      expect(uploadedEventTypes().last, 'session_start');
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('400 bad apiKey drops the whole file', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      script.add(
          () => http.Response('{"error": "Invalid API key: test-key"}', 400));
      await backend.flush();

      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => t.code), [400, 400]);
    });

    test('413 splits multi-event files and uploads every event once', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await backend.track({'event_type': 'b'});
      // First attempt: 413 for the 3-event file, then success thereafter.
      var first = true;
      script.add(() {
        if (first) {
          first = false;
          return http.Response('', 413);
        }
        return http.Response('{}', 200);
      });
      await backend.flush();

      // The 413 attempt also carried the events; count only what the
      // server accepted (200 responses): every event exactly once.
      final accepted = [
        for (var i = 0; i < requests.length; i++)
          if (statuses[i] == 200) requests[i],
      ];
      expect(accepted.length, greaterThanOrEqualTo(2));
      expect(
        [
          for (final request in accepted)
            for (final event in (decodeUpload(request)['events'] as List))
              (event as Map)['event_type'],
        ],
        ['session_start', 'a', 'b'],
      );
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('413 on a single-event file drops it with a callback', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await backend.flush(); // session_start + a go out; session established
      expect(terminals.where((t) => t.code == 200), hasLength(2));
      terminals.clear();

      await backend.track({'event_type': 'b'}); // single-event file
      script.add(() => http.Response('', 413));
      await backend.flush();

      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => '${t.eventType}:${t.code}'), ['b:413']);
    });

    test('429 throttles uploads for 30 s without data loss', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      script.add(() => http.Response('{"throttledEvents": [0, 1]}', 429));
      await backend.flush();
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      // Immediate retry is paused: no new request leaves the SDK.
      await backend.flush();
      expect(requests, hasLength(1));

      clock.nowMs += 31 * 1000;
      await backend.flush();
      expect(requests, hasLength(2));
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('500 then success retries with backoff and recovers', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      script.add(() => http.Response('boom', 500));
      await backend.flush();
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      await backend.flush();
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => t.code), [200, 200]);
    });

    test('network throw retries like a 5xx', () async {
      final backend = await makeBackend(
        transport: DesktopTransport(
          client: MockClient((request) async {
            requests.add(request);
            throw http.ClientException('offline');
          }),
        ),
      );
      await backend.track({'event_type': 'a'});
      await backend.flush();
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), hasLength(1));
    });

    test('never-settling send still settles the flush (SDK-188)', () async {
      final backend = await makeBackend(
        transport: DesktopTransport(
          client: MockClient((request) {
            requests.add(request);
            return Completer<http.Response>().future;
          }),
          requestTimeout: const Duration(milliseconds: 50),
        ),
      );
      await backend.track({'event_type': 'a'});
      // Would hang forever without the request timeout.
      await backend.flush().timeout(const Duration(seconds: 5));
      expect(await storage.listFilesOldestFirst(), hasLength(1));
    });

    test('exhaustion trips offline silently and the probe heals', () async {
      final backend = await makeBackend(
        config: configMap(flushMaxRetries: 2),
        reprobeInterval: const Duration(milliseconds: 50),
      );
      await backend.track({'event_type': 'a'});
      // One attempt per file per flush: three flushes fail before the
      // failures counter (3 > maxRetries 2) trips offline.
      for (var i = 0; i < 3; i++) {
        script.add(() => http.Response('down', 500));
        await backend.flush();
      }

      // Offline now: files kept, user-silence (no terminal callbacks,
      // diagnostic log only).
      expect(requests.length, 3);
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
      expect(terminals, isEmpty);
      expect(await storage.listFilesOldestFirst(), hasLength(1));
      final callsWhileOffline = requests.length;
      await backend.flush();
      expect(requests.length, callsWhileOffline,
          reason: 'offline flushes must not send');

      // The 6-hour... here 50 ms reprobe heals on the next success.
      await Future.delayed(const Duration(milliseconds: 300));
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => t.code), [200, 200]);
    });

    test('30-day-old files are discarded with a callback', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'ancient'});
      // Seal an old file: fail one upload so the sealed file survives.
      script.add(() => throw http.ClientException('offline'));
      await backend.flush();
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      clock.nowMs += 31 * 24 * 3600 * 1000;
      await backend.flush();

      expect(requests.length, 1, reason: 'discard sends nothing');
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => '${t.eventType}:${t.code}'),
          ['session_start:500', 'ancient:500']);
    });

    test('corrupt queue files are quarantined, healthy ones upload', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'good'});
      await storage.sealCurrentFile();
      await storage.writeFile('v2-9', 'not-json{{{');
      await backend.flush();

      expect(uploadedEventTypes(), ['session_start', 'good']);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('opt-out drops tracks and no-ops flush', () async {
      final backend = await makeBackend();
      await backend.setOptOut(true);
      await backend.track({'event_type': 'a'});
      await backend.flush();

      expect(requests, isEmpty);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('reset rotates identity but leaves queue and session to drain',
        () async {
      final backend = await makeBackend();
      final before = await backend.getDeviceId();
      await backend.track({'event_type': 'a'});
      final sessionBeforeReset = await backend.getSessionId();
      expect(sessionBeforeReset, isNot(-1));
      await backend.reset();

      expect(await backend.getDeviceId(), isNot(before));
      expect(await backend.getUserId(), isNull);
      // Swift `Amplitude.reset()` / Kotlin `doResetWithDeviceId` parity:
      // neither native SDK touches the session or the queue on reset.
      expect(await backend.getSessionId(), sessionBeforeReset);

      // Queued events keep the previous identity and still upload.
      await backend.flush();
      expect(uploadedEventTypes(), ['session_start', 'a']);
      final drained = decodeUpload(requests.single)['events'] as List;
      for (final event in drained) {
        expect((event as Map)['device_id'], before);
      }

      // Events tracked after the reset use the rotated id.
      await backend.track({'event_type': 'b'});
      await backend.flush();
      final after = decodeUpload(requests.last)['events'] as List;
      final b =
          after.where((e) => (e as Map)['event_type'] == 'b').single as Map;
      expect(b['device_id'], await backend.getDeviceId());
      expect(b['device_id'], isNot(before));
    });

    test('reset keeps the held identify batch; it drains first', () async {
      final backend = await makeBackend();
      final before = await backend.getDeviceId();
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });
      await backend.reset();

      await backend.track({'event_type': 'trigger'});
      await backend.flush();

      // The held batch survives reset (neither native SDK clears the
      // interceptor) and the identity-change path transfers it first,
      // still stamped with the previous identity.
      expect(uploadedEventTypes(), ['session_start', r'$identify', 'trigger']);
      final drained = decodeUpload(requests.single)['events'] as List;
      final held = drained
          .where((e) => (e as Map)['event_type'] == r'$identify')
          .single as Map;
      expect(held['device_id'], before);
      final trigger = drained
          .where((e) => (e as Map)['event_type'] == 'trigger')
          .single as Map;
      expect(trigger['device_id'], await backend.getDeviceId());
    });

    test(r'held $set emits before the triggering plain event', () async {
      // Regression: the held batch used to vanish when a plain event
      // arrived (transfer() return ignored in process()). It must emit
      // first with session/event ids, before the trigger.
      final backend = await makeBackend();
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });
      await backend.track({'event_type': 'clicked'});
      await backend.flush();

      expect(requests, hasLength(1));
      final events = decodeUpload(requests.single)['events'] as List;
      final types = [
        for (final e in events) (e as Map)['event_type'],
      ];
      expect(types, contains(r'$identify'));
      expect(types, contains('clicked'));
      expect(
        types.indexOf(r'$identify'),
        lessThan(types.indexOf('clicked')),
        reason: 'combined identify must precede the trigger',
      );
      final identify = events.cast<Map>().firstWhere(
            (e) => e['event_type'] == r'$identify',
          );
      expect(
        (identify['user_properties'] as Map)[r'$set'],
        {'plan': 'pro'},
      );
      expect(identify['session_id'], isNotNull);
      expect(identify['event_id'], isNotNull);
    });

    test('listed-but-unreadable files are quarantined', () async {
      final phantom = _PhantomStorage(clock.call);
      final backend = DesktopBackend(
        storage: phantom,
        systemInfo: FakeSystemInfo(),
        appInfo: FakeAppInfo(),
        transport: makeTransport(),
        clock: clock.call,
        sleeper: (duration) async {
          sleeps.add(duration);
        },
        offlineReprobeInterval: const Duration(hours: 6),
        logger: logs.add,
      );
      backends.add(backend);
      expect(await backend.init(configMap()), isTrue);
      await backend.track({'event_type': 'good'});
      await backend.flush();

      expect(phantom.quarantined, isTrue);
      expect(uploadedEventTypes(), contains('good'));
      expect(await phantom.listFilesOldestFirst(), isEmpty);
    });

    test('partial-400 survivors keep their age for 30-day discard', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      final createdBefore = await storage.fileCreatedAt('v2-0.tmp') ??
          await storage.fileCreatedAt('v2-0');
      script.add(() => http.Response(
          '{"events_with_invalid_fields": {"event_type": [1]}}', 400));
      await backend.flush();
      expect(await storage.listFilesOldestFirst(), hasLength(1));
      final survivor = (await storage.listFilesOldestFirst()).single;
      // The rewrite must not reset the 30-day clock.
      expect(await storage.fileCreatedAt(survivor), createdBefore);

      clock.nowMs += 31 * 24 * 3600 * 1000;
      terminals.clear();
      await backend.flush();

      expect(requests.length, 1, reason: 'discard sends nothing');
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => t.code), contains(500));
    });

    test('hostile types never reject track()', () async {
      final backend = await makeBackend();
      await backend.track({
        'event_type': 'x',
        'timestamp': 'not-a-number',
        'session_id': 'also-bad',
      }).timeout(const Duration(seconds: 5));
      await backend.track({
        'event_type': 'y',
        'nasty': DateTime.utc(2026, 1, 1),
      }).timeout(const Duration(seconds: 5));
      await backend.flush().timeout(const Duration(seconds: 5));
      // The String-timestamp event survives (clock fallback); the
      // non-encodable one drops. Either way nothing threw.
      expect(uploadedEventTypes(), contains('x'));
    });

    test('transfer enqueues do not auto-flush', () async {
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 1),
      );
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'a': 1}
        },
      });
      await backend.track({'event_type': 'clicked'});
      // One threshold flush for the host event; the transfer itself must
      // not have triggered a nested chain (which would split the batch).
      expect(requests, hasLength(1));
      expect(
        uploadedEventTypes(),
        containsAll([r'$identify', 'clicked']),
      );
    });

    test('identity reads before init completion never hang', () async {
      final backend = DesktopBackend(
        storage: storage,
        systemInfo: FakeSystemInfo(),
        appInfo: FakeAppInfo(),
        transport: makeTransport(),
        clock: clock.call,
      );
      backends.add(backend);
      expect(await backend.getUserId(), isNull);
      expect(await backend.getDeviceId(), isNull);
      expect(await backend.getSessionId(), -1);
      await backend.dispose();
    });
  });
}
