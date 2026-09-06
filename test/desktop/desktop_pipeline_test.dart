import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:amplitude_flutter/desktop/desktop_backend.dart';
import 'package:amplitude_flutter/desktop/desktop_compress.dart';
import 'package:amplitude_flutter/desktop/desktop_identify_interceptor.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:amplitude_flutter/desktop/desktop_system_info.dart';
import 'package:amplitude_flutter/desktop/desktop_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// System-info source that always fails: proves a host lookup failure
/// degrades to fallbacks instead of refusing init.
class ThrowingSystemInfo implements DesktopSystemInfoSource {
  @override
  Future<DesktopOsInfo> currentOs() => throw StateError('no device info');
}

/// Storage that fails writes on demand: proves a failing disk drops events
/// without ever rejecting the caller's track() future.
class FailingStorage extends InMemoryDesktopStorage {
  FailingStorage({
    required super.clock,
    this.failAppend = false,
    this.failWriteInt = false,
  });

  final bool failAppend;
  final bool failWriteInt;

  @override
  Future<void> appendEvent(String jsonLine) async {
    if (failAppend) {
      throw StateError('disk full');
    }
    return super.appendEvent(jsonLine);
  }

  @override
  Future<void> writeInt(String key, int value) async {
    if (failWriteInt) {
      throw StateError('disk full');
    }
    return super.writeInt(key, value);
  }
}

/// Storage that fails only its first append: proves a refused write does not
/// consume threshold budget.
class FailOnceStorage extends InMemoryDesktopStorage {
  FailOnceStorage({required super.clock});

  bool _failed = false;

  @override
  Future<void> appendEvent(String jsonLine) async {
    if (!_failed) {
      _failed = true;
      throw StateError('disk full once');
    }
    return super.appendEvent(jsonLine);
  }
}

/// Storage whose queue listing fails on demand: proves a storage failure
/// inside the flush loop propagates to the caller instead of hanging, and
/// the in-flush guard is still released for later threshold flushes.
class ThrowingFlushStorage extends InMemoryDesktopStorage {
  ThrowingFlushStorage({required super.clock, this.throwLists = true});

  bool throwLists;

  @override
  Future<List<String>> listFilesOldestFirst() async {
    if (throwLists) {
      throw StateError('disk gone');
    }
    return super.listFilesOldestFirst();
  }
}

/// Storage that lists the same unreadable file twice: exercises the flush
/// loop's `skip` set, which must deduplicate a corrupt listing instead of
/// quarantining (and logging) the same file twice.
class DuplicateListingStorage extends InMemoryDesktopStorage {
  DuplicateListingStorage(int Function() clock) : super(clock: clock);

  int quarantines = 0;

  @override
  Future<List<String>> listFilesOldestFirst() async => ['v2-dup', 'v2-dup'];

  @override
  Future<String?> readFile(String name) async => null;

  @override
  Future<int?> fileCreatedAt(String name) async => 0;

  @override
  Future<void> quarantineFile(String name) async {
    quarantines += 1;
  }
}

/// Storage whose sealed files read as missing while their creation times
/// survive: exercises the flush loop's own listed-but-unreadable branch,
/// which the expiry backstop (creation time missing) never reaches.
class BlindReadStorage extends InMemoryDesktopStorage {
  BlindReadStorage({required super.clock, required this.blind});

  final Set<String> blind;

  @override
  Future<String?> readFile(String name) async {
    if (blind.contains(name)) {
      return null;
    }
    return super.readFile(name);
  }
}

/// Manual-fire one-shot timer for the backend's identify seam.
class BackendManualTimer implements Timer {
  BackendManualTimer();
  void Function()? callback;

  void fire() => callback!();

  @override
  void cancel() {}

  @override
  bool get isActive => true;

  @override
  int get tick => 0;
}

/// Map whose reads throw: the only input that can make
/// `translateDesktopEvent` throw. Every other hostile shape (wrong-typed
/// plain values) is handled total by `is`-checks — and `== null` never
/// dispatches `operator==`, so a throwing `==` would NOT reach the catch
/// (verified). A throwing `[]` on a nested map does: the top-level event
/// map is always plain (track() copies it), but nested values keep their
/// runtime type through the shallow copy.
class _ThrowingMap extends MapBase<String, dynamic> {
  @override
  dynamic operator [](Object? key) => throw StateError('hostile []');

  @override
  void operator []=(String key, dynamic value) =>
      throw StateError('hostile []=');

  @override
  void clear() {}

  @override
  Iterable<String> get keys => const [];

  @override
  dynamic remove(Object? key) => null;
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
    DesktopStorage? storageOverride,
    DesktopSystemInfoSource? systemOverride,
    DesktopAppInfoSource? appOverride,
    DesktopTerminalCallback? terminalOverride,
    DesktopTimerFactory? timerOverride,
  }) async {
    final backend = DesktopBackend(
      storage: storageOverride ?? storage,
      systemInfo: systemOverride ?? FakeSystemInfo(),
      appInfo: appOverride ?? FakeAppInfo(),
      transport: transport ?? makeTransport(),
      clock: clock.call,
      sleeper: (duration) async {
        sleeps.add(duration);
      },
      offlineReprobeInterval: reprobeInterval,
      identifyTimerFactory: timerOverride,
      onTerminalEvent: terminalOverride ??
          (event, code, message) {
            terminals
                .add(Terminal(event['event_type'] as String?, code, message));
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

    test('uploaded bodies use wire time, never timestamp', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a', 'timestamp': 1700000001234});
      await backend.flush();

      expect(requests, hasLength(1));
      final payload = decodeUpload(requests.single);
      final events = payload['events'] as List;
      expect(events, isNotEmpty);
      for (final raw in events) {
        final event = raw as Map;
        expect(event.containsKey('timestamp'), isFalse,
            reason: 'wire events must not contain timestamp');
        expect(event.containsKey('time'), isTrue,
            reason: 'wire events must contain time');
      }
      final main = events.cast<Map>().firstWhere((e) => e['event_type'] == 'a');
      expect(main['time'], 1700000001234);
    });

    test('generated session_start uses wire time', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a', 'timestamp': 1700000001234});
      await backend.flush();

      final payload = decodeUpload(requests.single);
      final events = payload['events'] as List;
      final start = events.cast<Map>().firstWhere(
            (e) => e['event_type'] == 'session_start',
          );
      expect(start.containsKey('timestamp'), isFalse);
      expect(start['time'], 1700000001234);
    });

    test('transferred identify uses wire time', () async {
      final backend = await makeBackend();
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });
      await backend.track({'event_type': 'trigger'});
      await backend.flush();

      final payload = decodeUpload(requests.single);
      final events = payload['events'] as List;
      final identify = events.cast<Map>().firstWhere(
            (e) => e['event_type'] == r'$identify',
          );
      expect(identify.containsKey('timestamp'), isFalse);
      expect(identify.containsKey('time'), isTrue);
    });

    test('out-of-session event uploads without session events', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'x', 'session_id': -1});
      await backend.flush();

      expect(requests, hasLength(1));
      final payload = decodeUpload(requests.single);
      final events = payload['events'] as List;
      expect(
        events.map((e) => (e as Map)['event_type']),
        ['x'],
        reason: 'sentinel must not emit session_start',
      );
      final main = events.single as Map;
      expect(main['session_id'], -1);
      expect(main.containsKey('time'), isTrue);
      expect(main['event_id'], isNotNull);
      expect(main['device_id'], isNotNull);
      expect(main['platform'], 'Linux');
      expect(await backend.getSessionId(), -1);
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

      // Ordered retry drains the survivor in the same flush: 400 drops `a`,
      // rewrite preserves session_start, second upload sends it.
      expect(requests, hasLength(2));
      expect(terminals.map((t) => '${t.eventType}:${t.code}'),
          ['a:400', 'session_start:200']);
      expect(await storage.listFilesOldestFirst(), isEmpty);

      await backend.flush();
      expect(requests, hasLength(2),
          reason: 'second flush has nothing left to send');
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

    test('429 on a single file retries within the same flush', () async {
      // Historical 30 s throttle removed in T-7: 429 now uses the same
      // ordered whole-file retry as other retryable failures.
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      script.add(() => http.Response('{"throttled_events": [0, 1]}', 429));
      await backend.flush();

      expect(requests, hasLength(2));
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => t.code), [200, 200]);
    });

    test('429 retains the whole file and retries it in order', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await storage.sealCurrentFile();
      await backend.track({'event_type': 'b'});
      const canonical = '{"throttled_events": [0], '
          '"exceeded_daily_quota_users": {"u1": 1}}';
      script.add(() => http.Response(canonical, 429));
      await backend.flush();

      // Oldest 429 retried first: A, A, then B. Nothing dropped.
      expect(requests, hasLength(3));
      expect(terminals.map((t) => t.code), [200, 200, 200],
          reason: 'rate-limited files stay pending, never terminal-drop');
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(sleeps, [const Duration(seconds: 1)]);
    });

    test('429 exhaustion keeps every event and trips offline', () async {
      final backend = await makeBackend(
        config: configMap(flushMaxRetries: 1),
      );
      await backend.track({'event_type': 'a'});
      script.add(() => http.Response('{"throttled_events": [0]}', 429));
      script.add(() => http.Response('{"throttled_events": [0]}', 429));
      await backend.flush();

      expect(requests, hasLength(2));
      expect(terminals, isEmpty);
      expect(await storage.listFilesOldestFirst(), hasLength(1));
    });

    test('500 then success retries with backoff and recovers', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      script.add(() => http.Response('boom', 500));
      await backend.flush();

      // Ordered retry: same oldest file retried within the one flush.
      expect(requests, hasLength(2));
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => t.code), [200, 200]);
    });

    test('retryable failure retries the same file within one flush', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      script.add(() => http.Response('boom', 500));
      await backend.flush();

      expect(requests, hasLength(2));
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => t.code), [200, 200]);
    });

    test('newer file never overtakes a retrying oldest file', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await storage.sealCurrentFile();
      await backend.track({'event_type': 'b'});
      // Two sealed files: oldest holds session_start+a, newest holds b.
      script.add(() => http.Response('boom', 500));
      await backend.flush();

      // Oldest retried first: A fails, A succeeds, then B succeeds.
      expect(requests, hasLength(3));
      final perRequest = [
        for (final r in requests)
          (decodeUpload(r)['events'] as List)
              .map((e) => (e as Map)['event_type'] as String)
              .toList(),
      ];
      expect(perRequest[0].first, 'session_start');
      expect(perRequest[1].first, 'session_start');
      expect(perRequest[2], ['b']);
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('exhaustion retries the oldest file without touching newer files',
        () async {
      final backend = await makeBackend(
        config: configMap(flushMaxRetries: 2),
      );
      await backend.track({'event_type': 'a'});
      await storage.sealCurrentFile();
      await backend.track({'event_type': 'b'});
      for (var i = 0; i < 3; i++) {
        script.add(() => http.Response('down', 500));
      }
      await backend.flush();

      // Three attempts, all on the oldest file; newer file never requested.
      expect(requests, hasLength(3));
      for (final r in requests) {
        final types = (decodeUpload(r)['events'] as List)
            .map((e) => (e as Map)['event_type'] as String)
            .toList();
        expect(types, contains('session_start'));
        expect(types, isNot(contains('b')));
      }
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
      expect(terminals, isEmpty);
      expect(await storage.listFilesOldestFirst(), hasLength(2));
    });

    test('a successful retry resets failures before the next file', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await storage.sealCurrentFile();
      await backend.track({'event_type': 'b'});
      script.add(() => http.Response('boom', 500));
      await backend.flush();

      // One backoff for the oldest retry; the next file uploads cleanly.
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(requests, hasLength(3));
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
      // Six attempts (failures 1..5 back off, 6th trips offline).
      expect(requests, hasLength(6));
      expect(sleeps, [
        for (final s in [1, 2, 4, 8, 16]) Duration(seconds: s),
      ]);
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
      // Ordered retry: one flush makes three attempts on the same oldest
      // file before the failures counter (3 > maxRetries 2) trips offline.
      for (var i = 0; i < 3; i++) {
        script.add(() => http.Response('down', 500));
      }
      await backend.flush();

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
      await storage.sealCurrentFile();
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      clock.nowMs += 31 * 24 * 3600 * 1000;
      await backend.flush();

      expect(requests, isEmpty, reason: 'discard sends nothing');
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

    test('legacy stored false cannot defeat current true', () async {
      await storage.init();
      await storage.writeBool(DesktopStoreKeys.optOut, false);
      final backend = await makeBackend(
        config: {...configMap(), 'optOut': true},
      );
      await backend.track({'event_type': 'a'});
      await backend.flush();

      expect(requests, isEmpty);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('opt-out keeps queued events for opt-in later in same run', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await backend.setOptOut(true);
      await backend.track({'event_type': 'b'});
      await backend.flush();

      expect(requests, isEmpty, reason: 'opted-out flush must not upload');

      await backend.setOptOut(false);
      await backend.flush();

      expect(uploadedEventTypes(), ['session_start', 'a'],
          reason: 'pre-opt-out queue must survive and drain after opt-in');
      await backend.track({'event_type': 'c'});
      await backend.flush();
      expect(uploadedEventTypes(), contains('c'));
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
      // Trip offline after the rewrite so the survivor is retained for the
      // age check (ordered retry would otherwise drain it in the same flush).
      for (var i = 0; i < 6; i++) {
        script.add(() => http.Response('down', 500));
      }
      await backend.flush();
      expect(await storage.listFilesOldestFirst(), hasLength(1));
      final survivor = (await storage.listFilesOldestFirst()).single;
      // The rewrite must not reset the 30-day clock.
      expect(await storage.fileCreatedAt(survivor), createdBefore);
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

    test('a throwing nested map drops the event, never the track call',
        () async {
      final backend = await makeBackend();
      await backend.track({
        'event_type': 'x',
        'ingestion_metadata': _ThrowingMap(),
      }).timeout(const Duration(seconds: 5));
      await backend.flush();

      expect(requests, isEmpty,
          reason: 'translate threw before the session opened: nothing stored');
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('transfer enqueues do not auto-flush', () async {
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 3),
      );
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'a': 1}
        },
      });
      await backend.track({'event_type': 'clicked'});
      // Deferred threshold: session_start + transfer + trigger append in order
      // first, then one flush carries all three. A nested flush would split
      // the batch into two requests.
      expect(requests, hasLength(1));
      expect(
        uploadedEventTypes(),
        ['session_start', r'$identify', 'clicked'],
      );
    });

    test('first track counts session_start plus event toward threshold',
        () async {
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 2),
      );
      await backend.track({'event_type': 'a'});

      expect(requests, hasLength(1));
      final payload = decodeUpload(requests.single);
      expect(
        (payload['events'] as List).map((e) => (e as Map)['event_type']),
        ['session_start', 'a'],
      );
    });

    test('without session events one track counts as one', () async {
      final backend = await makeBackend(config: {
        ...configMap(flushQueueSize: 2),
        'autocapture': false,
      });
      await backend.track({'event_type': 'a'});

      expect(requests, isEmpty,
          reason: 'single event must not reach threshold 2');
      await backend.track({'event_type': 'b'});
      expect(requests, hasLength(1));
      expect(uploadedEventTypes(), ['a', 'b']);
    });

    test('held identify session_start participates in threshold', () async {
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 1),
      );
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'a': 1}
        },
      });

      expect(requests, hasLength(1),
          reason: 'session_start from held identify must trigger threshold');
      // Flush-time transfer joins the same upload: threshold counted the
      // session_start, the flush drained the held batch with it.
      expect(uploadedEventTypes(), ['session_start', r'$identify']);
    });

    test('timer-drained identify counts and can trigger flush', () async {
      BackendManualTimer? timer;
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 2),
        timerOverride: (duration, callback) {
          timer = BackendManualTimer()..callback = callback;
          return timer!;
        },
      );
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });
      // One session_start queued, below threshold: no upload yet.
      expect(requests, isEmpty);

      timer!.fire();
      // Timer drain runs through the backend chain; give it a turn.
      // Threshold 2 (session_start + drained identify) triggers one upload.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (requests.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests, hasLength(1));
      expect(uploadedEventTypes(), ['session_start', r'$identify']);
    });

    test('flush-time transfer joins the current flush without nesting',
        () async {
      final backend = await makeBackend();
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'a': 1}
        },
      });
      await backend.flush();

      expect(requests, hasLength(1));
      expect(
        uploadedEventTypes(),
        ['session_start', r'$identify'],
      );
    });

    test('encoding and storage failures do not advance the count', () async {
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 2),
      );
      await backend.track({
        'event_type': 'bad',
        'nasty': DateTime.utc(2026, 1, 1),
      });
      expect(requests, isEmpty);

      await backend.track({'event_type': 'good'});
      expect(requests, hasLength(1),
          reason: 'bad event must not have consumed threshold budget');
      expect(
        uploadedEventTypes(),
        ['session_start', 'good'],
      );
    });

    test('a refused append does not consume threshold budget', () async {
      final failing = FailOnceStorage(clock: clock.call);
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 2),
        storageOverride: failing,
      );
      // First track: session_start append fails, main event appends (count 1).
      await backend.track({'event_type': 'a'});
      expect(requests, isEmpty);

      // Second track: one more append reaches threshold 2 with a single
      // upload. If the failed append had counted, this would have flushed
      // early with a split batch.
      await backend.track({'event_type': 'b'});
      expect(requests, hasLength(1));
      expect(uploadedEventTypes(), containsAll(['a', 'b']));
    });

    test('threshold restarts from zero after a flush', () async {
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 2),
      );
      await backend.track({'event_type': 'a'});
      expect(requests, hasLength(1));

      await backend.track({'event_type': 'b'});
      await backend.track({'event_type': 'c'});
      expect(requests, hasLength(2));
      expect(uploadedEventTypes(), ['session_start', 'a', 'b', 'c']);
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

    test('missing trackingOptions means everything tracked', () async {
      final config = Map<String, dynamic>.from(configMap())
        ..remove('trackingOptions');
      final backend = await makeBackend(config: config);
      await backend.track({'event_type': 'a'});
      await backend.flush();

      final payload = decodeUpload(requests.single);
      final event = (payload['events'] as List).last as Map;
      expect(event['platform'], 'Linux',
          reason: 'absent options default to tracked, never to dropped');
    });

    test('below-floor identifyBatchInterval warns through the backend log',
        () async {
      await makeBackend(config: {
        ...configMap(),
        'identifyBatchIntervalMillis': 1000,
        'logLevel': 'warn',
      });
      expect(
        logs.join('\n'),
        contains('30000'),
        reason: 'the 30 s floor warning must reach host logs, not vanish',
      );
    });

    test('a failing system-info source falls back instead of refusing init',
        () async {
      final backend = await makeBackend(systemOverride: ThrowingSystemInfo());
      await backend.track({'event_type': 'a'});
      await backend.flush();

      final payload = decodeUpload(requests.single);
      final event = (payload['events'] as List).first as Map;
      expect(event['platform'], 'Unknown',
          reason: 'a host lookup failure degrades; init must still succeed');
    });

    test('identify timer expiry drains the hold through the backend', () async {
      BackendManualTimer? timer;
      final backend = await makeBackend(timerOverride: (duration, callback) {
        timer = BackendManualTimer()..callback = callback;
        return timer!;
      });
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });
      expect(timer, isNotNull);

      timer!.fire();
      await backend.flush();

      expect(uploadedEventTypes(), ['session_start', r'$identify']);
    });

    test('setForeground(false) lets the session gap rotate', () async {
      final backend = await makeBackend(config: {
        ...configMap(),
        'minTimeBetweenSessionsMillis': 1000,
      });
      await backend.track({'event_type': 'a'});
      final first = await backend.getSessionId();

      backend.setForeground(false);
      clock.nowMs += 5000;
      await backend.track({'event_type': 'b'});
      expect(await backend.getSessionId(), isNot(first));

      await backend.flush();
      expect(
        uploadedEventTypes(),
        containsAll(['session_end', 'session_start']),
        reason: 'background past the gap closes the old session',
      );
    });

    test('onEnterForeground starts a new session past the gap', () async {
      final backend = await makeBackend(config: {
        ...configMap(),
        'minTimeBetweenSessionsMillis': 1000,
      });
      await backend.track({'event_type': 'a'});
      final first = await backend.getSessionId();

      clock.nowMs += 5000;
      await backend.onEnterForeground(clock.nowMs);
      expect(await backend.getSessionId(), clock.nowMs);
      expect(await backend.getSessionId(), isNot(first));

      await backend.flush();
      final payload = decodeUpload(requests.single);
      final starts = (payload['events'] as List)
          .where((e) => (e as Map)['event_type'] == 'session_start');
      expect(
          starts.map((e) => (e as Map)['session_id']), contains(clock.nowMs));
    });

    test('tracking a bare session start stores it once, not twice', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'session_start'});
      await backend.flush();

      // The dummy is consumed (null main): its preceding start uploads,
      // and no second copy follows it into the queue.
      expect(uploadedEventTypes(), ['session_start']);
    });

    test('onEnterForeground with no session starts one', () async {
      final backend = await makeBackend();
      expect(await backend.getSessionId(), -1);

      // Cold start entering the foreground: the dummy is consumed and a
      // session opens, exactly as if the first event had arrived.
      await backend.onEnterForeground(clock.nowMs);
      expect(await backend.getSessionId(), clock.nowMs);

      await backend.flush();
      expect(uploadedEventTypes(), ['session_start']);
    });

    test('onExitForeground flushes when close-flush is on', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});

      await backend.onExitForeground(clock.nowMs);
      expect(requests, hasLength(1),
          reason: 'hosts rely on this flush at window close');
      expect(await backend.getSessionId(), isNot(-1),
          reason: 'exit never ends the session');
    });

    test('onExitForeground only stamps time when close-flush is off', () async {
      final backend = await makeBackend(config: {
        ...configMap(),
        'flushEventsOnClose': false,
      });
      await backend.track({'event_type': 'a'});
      final first = await backend.getSessionId();

      await backend.onExitForeground(clock.nowMs);
      expect(requests, isEmpty);

      // The stamped time extends the session for the next event.
      clock.nowMs += 100;
      await backend.track({'event_type': 'b'});
      expect(await backend.getSessionId(), first);
    });

    test('a refusing queue drops the event without rejecting track', () async {
      final backend = await makeBackend(
        storageOverride: FailingStorage(clock: clock.call, failAppend: true),
      );
      await backend.track({'event_type': 'a'}).timeout(
        const Duration(seconds: 5),
      );
      await backend.flush();
      expect(requests, isEmpty);
    });

    test('failing session bookkeeping does not reject track', () async {
      final failing = FailingStorage(clock: clock.call, failWriteInt: true);
      final backend = await makeBackend(storageOverride: failing);
      await backend.track({'event_type': 'a'}).timeout(
        const Duration(seconds: 5),
      );
      expect(await failing.listFilesOldestFirst(), isEmpty);
    });

    test('a throwing terminal callback cannot break flush', () async {
      final backend = await makeBackend(
        config: {
          ...configMap(),
          'logLevel': 'warn',
        },
        terminalOverride: (event, code, message) {
          throw StateError('host callback blew up');
        },
      );
      await backend.track({'event_type': 'a'});
      await backend.flush().timeout(const Duration(seconds: 5));

      expect(requests, hasLength(1),
          reason: 'the upload already succeeded; only the callback failed');
      expect(logs.join('\n'), contains('terminal callback threw'));
    });

    test('flush transfers a held identify with no triggering event', () async {
      final backend = await makeBackend();
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });
      await backend.flush();

      expect(uploadedEventTypes(), ['session_start', r'$identify']);
    });

    test('empty queue files are removed at flush without uploading', () async {
      final backend = await makeBackend();
      await storage.writeFile('v2-9', '');
      await backend.flush();

      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(requests, isEmpty);
    });

    test('a storage failure inside flush releases the in-flush guard',
        () async {
      final throwing = ThrowingFlushStorage(clock: clock.call);
      final backend = await makeBackend(
        config: configMap(flushQueueSize: 3),
        storageOverride: throwing,
      );
      await backend.track({'event_type': 'a'});

      // The listing failure propagates instead of hanging the flush.
      await expectLater(backend.flush(), throwsStateError);

      // The guard was released: reaching the threshold still auto-flushes.
      throwing.throwLists = false;
      await backend.track({'event_type': 'b'});
      expect(requests, hasLength(1));
      expect(
        uploadedEventTypes(),
        ['session_start', 'a', 'b'],
      );
    });

    test('transport exceptions exhaust retries and trip offline silently',
        () async {
      final backend = await makeBackend(
        config: {
          ...configMap(),
          'flushMaxRetries': 1,
        },
      );
      await backend.track({'event_type': 'a'});
      script.add(() => throw http.ClientException('down'));
      script.add(() => throw http.ClientException('still down'));

      await backend.flush();
      await backend.flush();
      expect(requests, hasLength(2));
      expect(terminals, isEmpty);
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      // Offline now: further flushes send nothing until a probe heals.
      await backend.flush();
      expect(requests, hasLength(2));
    });

    test('a partial 400 covering every event removes the file', () async {
      final backend = await makeBackend();
      await backend.track({'event_type': 'a'});
      await backend.track({'event_type': 'b'});
      script.add(() => http.Response(
          '{"events_with_invalid_fields": {"event_type": [0, 1, 2]}}', 400));
      await backend.flush();

      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(terminals.map((t) => '${t.eventType}:${t.code}'),
          ['session_start:400', 'a:400', 'b:400']);
    });

    test('listed-but-unreadable files are quarantined at flush', () async {
      final blind = <String>{};
      final wrapped = BlindReadStorage(clock: clock.call, blind: blind);
      final backend = await makeBackend(storageOverride: wrapped);
      await backend.track({'event_type': 'good'});
      final sealed = await wrapped.sealCurrentFile();
      blind.add(sealed!);
      await backend.flush();

      expect(await wrapped.listFilesOldestFirst(), isEmpty);
      expect(requests, isEmpty,
          reason: 'nothing readable was ever uploaded from the blind file');
      expect(terminals, isEmpty);
    });

    test('init state and config are observable for tests', () async {
      final fresh = DesktopBackend();
      expect(fresh.isInitialized, isFalse);
      expect(fresh.configForTests, isNull);
      await fresh.dispose();

      final backend = await makeBackend();
      expect(backend.isInitialized, isTrue);
      expect(backend.configForTests?.apiKey, 'test-key');
    });

    test('default storage and system sources degrade gracefully', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final backend = DesktopBackend(
        transport: makeTransport(),
        clock: clock.call,
        sleeper: (duration) async {
          sleeps.add(duration);
        },
        onTerminalEvent: (event, code, message) {
          terminals
              .add(Terminal(event['event_type'] as String?, code, message));
        },
        logger: logs.add,
      );
      backends.add(backend);
      expect(await backend.init(configMap()), isTrue);

      await backend.track({'event_type': 'a'});
      await backend.flush();

      final payload = decodeUpload(requests.single);
      final event = (payload['events'] as List).first as Map;
      expect(event['platform'], 'Unknown',
          reason: 'no platform channel in unit tests; fallbacks must hold');
      expect(event['device_id'], isNotNull);
    });

    /// Points `path_provider` at a temporary directory for the test.
    Future<Directory> mockApplicationSupport() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp('amplitude-support-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return temp.path;
        }
        return null;
      });
      return temp;
    }

    void unmockApplicationSupport() {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }

    DesktopBackend defaultBackend() {
      final backend = DesktopBackend(
        transport: makeTransport(),
        clock: clock.call,
        sleeper: (duration) async {
          sleeps.add(duration);
        },
        onTerminalEvent: (event, code, message) {
          terminals
              .add(Terminal(event['event_type'] as String?, code, message));
        },
        logger: logs.add,
      );
      backends.add(backend);
      return backend;
    }

    test(
        'default backend uses the filesystem queue and migrates legacy entries',
        () async {
      final support = await mockApplicationSupport();
      try {
        final prefs = await SharedPreferences.getInstance();
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await prefs.setString(
          'storage-test-key-test/file/v2-0',
          json.encode({
            'createdAt': nowMs,
            'content': '{"event_type":"legacy"}',
          }),
        );
        final backend = defaultBackend();
        expect(await backend.init(configMap()), isTrue);
        await backend.track({'event_type': 'b'});
        await backend.flush();

        // The legacy preference queue migrated exactly once...
        expect(
          prefs
              .getKeys()
              .where((k) => k.startsWith('storage-test-key-test/file/')),
          isEmpty,
        );
        // ...into a real application-support subdirectory (not preferences).
        final supportEntries = await support.list().toList();
        expect(supportEntries.whereType<Directory>(), hasLength(1));
        expect(uploadedEventTypes(), ['legacy', 'session_start', 'b']);
      } finally {
        unmockApplicationSupport();
        await support.delete(recursive: true);
      }
    });

    test('a backend restart drains the previously written filesystem queue',
        () async {
      final support = await mockApplicationSupport();
      try {
        final first = defaultBackend();
        expect(await first.init(configMap()), isTrue);
        await first.track({'event_type': 'a'});
        await first.dispose();

        // Wipe preferences entirely: the queue must come from files alone.
        final prefs = await SharedPreferences.getInstance();
        for (final key in prefs.getKeys().toList()) {
          await prefs.remove(key);
        }
        requests.clear();

        final second = defaultBackend();
        expect(await second.init(configMap()), isTrue);
        await second.flush();
        expect(uploadedEventTypes(), contains('a'));
      } finally {
        unmockApplicationSupport();
        await support.delete(recursive: true);
      }
    });

    test('an unmigratable legacy entry does not refuse init', () async {
      final support = await mockApplicationSupport();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'storage-test-key-test/file/v2-0',
          json.encode({
            'createdAt': 1000,
            'content': '{"event_type":"legacy"}',
          }),
        );
        // Block the migration destination with a directory.
        final safe = base64Url
            .encode(utf8.encode('storage-test-key-test'))
            .replaceAll('=', '');
        final nsDir = Directory('${support.path}/$safe');
        await nsDir.create(recursive: true);
        await Directory('${nsDir.path}/v2-0').create();

        final backend = defaultBackend();
        expect(
            await backend.init({
              ...configMap(),
              'logLevel': 'warn',
            }),
            isTrue);
        expect(logs.join('\n'), contains('migration'));
        expect(
          prefs.getString('storage-test-key-test/file/v2-0'),
          isNotNull,
          reason: 'a failed migration must leave the source for next launch',
        );
      } finally {
        unmockApplicationSupport();
        await support.delete(recursive: true);
      }
    });

    test('the flush timer uploads without an explicit flush', () async {
      final backend = await makeBackend(config: {
        ...configMap(),
        'flushIntervalMillis': 20,
      });
      await backend.track({'event_type': 'a'});

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (requests.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests, isNotEmpty,
          reason: 'the periodic timer must drive uploads on its own');
    });

    test('autocapture false disables session events', () async {
      final backend = await makeBackend(config: {
        ...configMap(),
        'autocapture': false,
      });
      await backend.track({'event_type': 'a'});
      await backend.flush();

      expect(uploadedEventTypes(), ['a'],
          reason: 'a bare boolean is a complete sessions answer, not ignored');
    });

    test('calls before init complete without storing or sending', () async {
      final backend = DesktopBackend(transport: makeTransport());
      backends.add(backend);
      expect(backend.isInitialized, isFalse);

      await backend
          .track({'event_type': 'early'}).timeout(const Duration(seconds: 5));
      await backend.flush().timeout(const Duration(seconds: 5));

      expect(requests, isEmpty);
      expect(terminals, isEmpty);
    });

    test('a fully held identify stores only its session start', () async {
      final backend = await makeBackend();
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });

      final sealed = await storage.sealCurrentFile();
      expect(sealed, isNotNull);
      final lines = splitDesktopFileContent((await storage.readFile(sealed!))!);
      expect(
        lines.map((e) => json.decode(e)['event_type']),
        ['session_start'],
        reason: 'the held body waits for the timer or the next event',
      );
    });

    test('a failing probe stays offline without sleeping', () async {
      final backend = await makeBackend(
        config: {
          ...configMap(),
          'flushMaxRetries': 1,
        },
        reprobeInterval: const Duration(milliseconds: 200),
      );
      await backend.track({'event_type': 'a'});
      script.add(() => throw http.ClientException('down'));
      script.add(() => throw http.ClientException('still down'));
      script.add(() => throw http.ClientException('probe down'));
      await backend.flush();
      await backend.flush();
      expect(requests, hasLength(2));
      final sleepsAfterTrip = sleeps.length;

      // One probe attempt fires, fails, and stands down silently.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (requests.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await backend.dispose();
      expect(requests.length, greaterThanOrEqualTo(3));
      expect(sleeps, hasLength(sleepsAfterTrip),
          reason: 'single-attempt probes never back off');
      expect(terminals, isEmpty);
    });

    test('a duplicated corrupt listing is quarantined once, not twice',
        () async {
      final dups = DuplicateListingStorage(clock.call);
      final backend = await makeBackend(storageOverride: dups);
      await backend.flush();

      expect(dups.quarantines, 1);
      expect(requests, isEmpty,
          reason: 'the only listed files were unreadable');
    });

    test('probes run one file: a failed probe trips again, the next heals',
        () async {
      final backend = await makeBackend(
        config: configMap(flushMaxRetries: 1),
        reprobeInterval: const Duration(milliseconds: 50),
      );
      await backend.track({'event_type': 'a'});
      await storage.sealCurrentFile();
      await backend.track({'event_type': 'b'});
      // Trip offline in one flush: two attempts on the oldest file.
      script.add(() => throw http.ClientException('down'));
      script.add(() => throw http.ClientException('still down'));
      await backend.flush();
      expect(requests, hasLength(2));
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), hasLength(2));

      // First probe fails on the oldest file and stays offline.
      script.add(() => throw http.ClientException('probe down'));
      var deadline = DateTime.now().add(const Duration(seconds: 5));
      while (requests.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests.length, 3);
      expect(await storage.listFilesOldestFirst(), hasLength(2));
      expect(sleeps, [const Duration(seconds: 1)],
          reason: 'probes never back off');

      // Next probe succeeds on the oldest only and heals without walking.
      deadline = DateTime.now().add(const Duration(seconds: 5));
      while (requests.length < 4 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests.length, 4);
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      // Healed means online: a normal flush drains the survivor.
      await backend.flush();
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(requests.length, 5);
    });

    test('a stray online probe stands down without uploading', () async {
      // Race: a probe chain slower than the reprobe interval lets a second
      // timer callback queue behind it. The first probe heals (cancelling
      // the timer, which cannot retract the queued callback); the stray
      // must stand down instead of uploading.
      final gate = Completer<http.Response>();
      var calls = 0;
      final backend = await makeBackend(
        config: configMap(flushMaxRetries: 1),
        reprobeInterval: const Duration(milliseconds: 200),
        transport: DesktopTransport(
          client: MockClient((request) async {
            requests.add(request);
            calls += 1;
            if (calls == 1) throw http.ClientException('down');
            if (calls == 2) throw http.ClientException('still down');
            if (calls == 3) return gate.future;
            return http.Response('{}', 200);
          }),
        ),
      );
      await backend.track({'event_type': 'a'});
      await storage.sealCurrentFile();
      await backend.track({'event_type': 'b'});
      await storage.sealCurrentFile();
      await backend.flush();
      // Tripped offline in one flush (two attempts on oldest); two files.
      expect(calls, 2);
      expect(await storage.listFilesOldestFirst(), hasLength(2));

      // First probe hangs mid-upload past the next tick, so a second probe
      // queues behind it; completing the gate heals via the first probe.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (requests.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests.length, 3);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      gate.complete(http.Response('{}', 200));

      // Let both chains settle: only the first probe may have uploaded.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(requests.length, 3,
          reason: 'the stray probe must not touch the network');
      expect(await storage.listFilesOldestFirst(), hasLength(1));
      expect(sleeps, [const Duration(seconds: 1)]);

      // Healed means online: a normal flush drains the survivor.
      await backend.flush();
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(requests.length, 4);
    });

    test('an offline probe with a held identify uploads nothing', () async {
      final backend = await makeBackend(
        config: configMap(flushMaxRetries: 1),
        reprobeInterval: const Duration(milliseconds: 300),
      );
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'pro'}
        },
      });
      await backend.track({'event_type': 'a'});
      // Trip offline in one flush (two attempts on oldest).
      script.add(() => throw http.ClientException('down'));
      script.add(() => throw http.ClientException('still down'));
      await backend.flush();
      expect(sleeps, [const Duration(seconds: 1)]);
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      // A fresh held batch is waiting when the first probe fires: the
      // probe drains it into the open buffer but must not upload while
      // offline — that cycle sends nothing.
      await backend.identify({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'plan': 'enterprise'}
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(requests.length, 2,
          reason: 'the offline probe drains the hold but sends nothing');
      expect(await storage.listFilesOldestFirst(), hasLength(1));

      // The next probe uploads the oldest file, heals, and stops after
      // one file; a normal flush then drains the rest.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (requests.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests.length, 3);
      await backend.flush();
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('backoff sleep doubles then clamps at the maximum', () async {
      final backend = await makeBackend(config: {
        ...configMap(),
        'flushMaxRetries': 100,
      });
      await backend.track({'event_type': 'a'});
      for (var i = 0; i < 8; i++) {
        script.add(() => throw http.ClientException('down'));
      }
      // Ordered retry performs all attempts within one flush.
      await backend.flush();

      expect(sleeps, [
        for (final s in [1, 2, 4, 8, 16, 32, 60, 60]) Duration(seconds: s),
      ]);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('ancient files with corrupt content vanish without terminals',
        () async {
      final backend = await makeBackend();
      await storage.writeFile(
        'v2-old',
        'not-json{{{',
        createdAtMs: clock() - const Duration(days: 31).inMilliseconds,
      );
      await backend.flush().timeout(const Duration(seconds: 5));

      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(requests, isEmpty);
      expect(terminals, isEmpty,
          reason: 'unparseable lines cannot produce per-event callbacks');
    });
  });
}
