import 'dart:convert';
import 'dart:io';

import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Public-plugin smoke test for the Linux/Windows desktop backend (T-12).
//
// WHY an on-device test instead of another VM unit test: the unit suite
// drives `DesktopBackend` directly with fakes, so it cannot prove the
// generated registrant routes the shared `amplitude_flutter` channel to
// `DesktopAmplitudePlugin` on a real Linux/Windows runner, nor that real
// application-support directories, the real `WidgetsBinding` lifecycle,
// and real restart recovery behave. This file uses only the public
// `Amplitude` API against an in-process loopback collector, so it never
// touches Amplitude production endpoints.
//
// Run on Linux: `cd example && xvfb-run -a flutter test
// integration_test -d linux`
// Run on Windows: `cd example && flutter test integration_test -d windows`

/// One captured upload: decoded JSON body plus whether it arrived gzipped.
class _Upload {
  _Upload(this.body, this.gzipped);

  final Map<String, dynamic> body;
  final bool gzipped;

  List<Map<String, dynamic>> get events =>
      (body['events'] as List).cast<Map<String, dynamic>>();
}

/// In-process loopback collector. Tests point `serverUrl` at it.
class _Collector {
  final uploads = <_Upload>[];
  HttpServer? _server;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      final bytes = await request.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      final gzipped =
          request.headers.value(HttpHeaders.contentEncodingHeader) == 'gzip';
      // Custom server URLs are never gzipped, but decode defensively.
      final text = gzipped ? gzip.decode(bytes) : bytes;
      uploads.add(
        _Upload(
          json.decode(utf8.decode(text)) as Map<String, dynamic>,
          gzipped,
        ),
      );
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{}');
      await request.response.close();
    });
    return 'http://127.0.0.1:${_server!.port}';
  }

  Future<void> stop() async => _server?.close(force: true);

  /// Waits until at least [count] uploads arrived (flush already settled
  /// the chain; this only bridges the loopback socket).
  Future<void> waitFor(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (uploads.length < count && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(uploads.length, greaterThanOrEqualTo(count));
  }
}

Future<Amplitude> _init(
  String serverUrl,
  String instance, {
  int minTimeBetweenSessionsMillis = 300000,
}) async {
  final amplitude = Amplitude(
    Configuration(
      apiKey: 'smoke-key',
      instanceName: instance,
      serverUrl: serverUrl,
      flushIntervalMillis: 3600000,
      minTimeBetweenSessionsMillis: minTimeBetweenSessionsMillis,
    ),
  );
  expect(await amplitude.isBuilt, isTrue);
  return amplitude;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _Collector collector;
  late String serverUrl;

  setUp(() async {
    collector = _Collector();
    serverUrl = await collector.start();
  });

  tearDown(() async {
    await collector.stop();
  });

  testWidgets('timestamped track uploads a valid HTTP wire body', (
    tester,
  ) async {
    final amplitude = await _init(serverUrl, 'smoke-wire');
    await amplitude.setUserId('smoke-user');
    await amplitude.track(BaseEvent('smoke_event', timestamp: 1700000001234));
    await amplitude.flush();
    await collector.waitFor(1);

    final upload = collector.uploads.single;
    expect(upload.body['api_key'], 'smoke-key');
    final event = upload.events.firstWhere(
      (event) => event['event_type'] == 'smoke_event',
    );
    // Internal `timestamp` must arrive as HTTP `time`, never as `timestamp`.
    expect(event['time'], 1700000001234);
    expect(event.containsKey('timestamp'), isFalse);
    expect(event['session_id'], isA<int>());
    expect(event['event_id'], isNotNull);
    expect(event['insert_id'], isNotNull);
    expect(event['device_id'], isNotNull);
    expect(event['user_id'], 'smoke-user');
    expect(event['platform'], Platform.isWindows ? 'Windows' : 'Linux');
    expect(event['library'], startsWith('amplitude-flutter/'));
    expect(event['ip'], r'$remote');

    // The production default is the filesystem queue: no preference keys
    // may exist for this instance namespace (proves the native
    // path_provider registration resolved a real directory).
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where(
        (key) => key.startsWith('storage-smoke-key-smoke-wire/'),
      ),
      isEmpty,
    );
  });

  testWidgets('two instances keep isolated storage and identity', (
    tester,
  ) async {
    final first = await _init(serverUrl, 'smoke-iso-a');
    final second = await _init(serverUrl, 'smoke-iso-b');
    await first.setUserId('user-a');
    await second.setUserId('user-b');
    await first.track(BaseEvent('from_a'));
    await second.track(BaseEvent('from_b'));
    await first.flush();
    await second.flush();
    await collector.waitFor(2);

    final deviceA = await first.getDeviceId();
    final deviceB = await second.getDeviceId();
    expect(deviceA, isNotNull);
    expect(deviceB, isNotNull);
    expect(deviceA, isNot(deviceB));

    final byType = {
      for (final upload in collector.uploads)
        for (final event in upload.events) event['event_type'] as String: event,
    };
    expect(byType['from_a']!['user_id'], 'user-a');
    expect(byType['from_b']!['user_id'], 'user-b');
    expect(byType['from_a']!['device_id'], deviceA);
    expect(byType['from_b']!['device_id'], deviceB);
  });

  testWidgets('hide and restore rotate the session past the gap', (
    tester,
  ) async {
    final amplitude = await _init(
      serverUrl,
      'smoke-lifecycle',
      minTimeBetweenSessionsMillis: 1000,
    );
    await amplitude.track(BaseEvent('before'));
    final first = await amplitude.getSessionId();

    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.hidden,
    );
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump();
    await amplitude.track(BaseEvent('after'));

    expect(await amplitude.getSessionId(), isNot(first));
    await amplitude.flush();
    await collector.waitFor(1);

    final types = [
      for (final upload in collector.uploads)
        for (final event in upload.events) event['event_type'] as String,
    ];
    expect(types, contains('session_end'));
    expect(
      types.lastIndexOf('session_start'),
      greaterThan(types.indexOf('session_end')),
    );
  });

  testWidgets('a fresh backend drains the previously written queue', (
    tester,
  ) async {
    var amplitude = await _init(serverUrl, 'smoke-restart');
    final before = await amplitude.getDeviceId();
    await amplitude.track(BaseEvent('queued_before_restart'));
    // No flush: re-initializing the same instance retires the backend the
    // way a process restart would, leaving the open queue file on disk.
    amplitude = await _init(serverUrl, 'smoke-restart');

    expect(await amplitude.getDeviceId(), before);
    await amplitude.track(BaseEvent('queued_after_restart'));
    await amplitude.flush();
    await collector.waitFor(2);

    final types = [
      for (final upload in collector.uploads)
        for (final event in upload.events) event['event_type'] as String,
    ];
    // Recovery uploads first: nothing newer overtakes the restarted queue.
    expect(
      types.indexOf('queued_before_restart'),
      lessThan(types.indexOf('queued_after_restart')),
    );
  });
}
