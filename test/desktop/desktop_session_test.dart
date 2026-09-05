import 'package:amplitude_flutter/desktop/desktop_identity.dart';
import 'package:amplitude_flutter/desktop/desktop_session.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Fake clock: session tests must never depend on wall time (real-time
// session tests are flaky by construction).
class FakeClock {
  int nowMs = 1000000;
  int call() => nowMs;
}

Future<DesktopSession> makeSession({
  required InMemoryDesktopStorage storage,
  required FakeClock clock,
  int gapMs = 5 * 60 * 1000,
  bool trackSessionEvents = true,
}) async {
  final identity = DesktopIdentity(storage: storage);
  await identity.load(apiKey: 'k', seedDeviceId: 'device-1');
  final session = DesktopSession(
    storage: storage,
    identity: identity,
    clock: clock.call,
    sessionGapMs: gapMs,
    trackSessionEvents: trackSessionEvents,
  );
  await session.restore();
  return session;
}

Map<String, dynamic> event([String type = 'click']) => {'event_type': type};

void main() {
  group('DesktopSession', () {
    late InMemoryDesktopStorage storage;
    late FakeClock clock;

    setUp(() async {
      storage = InMemoryDesktopStorage();
      await storage.init();
      clock = FakeClock();
    });

    test('starts with no session (-1, not null)', () async {
      final session = await makeSession(storage: storage, clock: clock);
      expect(session.sessionId, -1);
    });

    test('first event starts a session and emits session_start', () async {
      final session = await makeSession(storage: storage, clock: clock);
      final result = await session.processEvent(event(), inForeground: true);

      expect(session.sessionId, clock.nowMs);
      expect(
        result.preceding.map((e) => e['event_type']),
        ['session_start'],
      );
      expect(result.preceding.first['session_id'], clock.nowMs);
      expect(result.event?['session_id'], clock.nowMs);
      expect(result.event?['event_id'], 2,
          reason: 'session_start takes event_id 1, the event takes 2');
    });

    test('foreground extends the session even past the gap', () async {
      final session =
          await makeSession(storage: storage, clock: clock, gapMs: 1000);
      await session.processEvent(event(), inForeground: true);

      clock.nowMs += 60 * 1000; // well past the 1 s gap
      final result = await session.processEvent(event(), inForeground: true);
      expect(result.preceding, isEmpty);
      expect(session.sessionId, 1000000);
    });

    test('background within the gap extends, past the gap starts new',
        () async {
      final session =
          await makeSession(storage: storage, clock: clock, gapMs: 1000);
      await session.processEvent(event(), inForeground: true);

      clock.nowMs += 500;
      var result = await session.processEvent(event(), inForeground: false);
      expect(result.preceding, isEmpty);

      clock.nowMs += 5000;
      result = await session.processEvent(event(), inForeground: false);
      expect(
        result.preceding.map((e) => e['event_type']),
        ['session_end', 'session_start'],
      );
      // The end event is timestamped with the last event time, not now.
      expect(result.preceding.first['timestamp'], 1000500);
      expect(result.preceding.first['session_id'], 1000000);
      expect(session.sessionId, clock.nowMs);
    });

    test('session_start dummy is consumed when no session exists', () async {
      final session = await makeSession(storage: storage, clock: clock);
      final result = await session.processEvent(
        {'event_type': 'session_start'},
        inForeground: false,
      );
      expect(result.event, isNull,
          reason: 'the dummy must be dropped, not enqueued');
      expect(
        result.preceding.map((e) => e['event_type']),
        ['session_start'],
      );
    });

    test('live dummy within the gap extends without emitting', () async {
      final session =
          await makeSession(storage: storage, clock: clock, gapMs: 1000);
      await session.processEvent(event(), inForeground: true);

      clock.nowMs += 500;
      final result = await session.processEvent(
        {'event_type': 'session_start'},
        inForeground: false,
      );
      expect(result.event, isNull,
          reason: 'dummies never enqueue (Swift skipEvent)');
      expect(result.preceding, isEmpty);
      expect(session.sessionId, 1000000);
    });

    test('session_start with a live session adopts its id', () async {
      final session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);

      final result = await session.processEvent(
        {'event_type': 'session_start', 'session_id': 777},
        inForeground: true,
      );
      expect(session.sessionId, 777);
      expect(result.event?['session_id'], 777);
    });

    test('session_end passes through with no state change', () async {
      final session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);
      final before = session.sessionId;

      final result = await session.processEvent(
        {'event_type': 'session_end'},
        inForeground: true,
      );
      expect(result.event?['event_type'], 'session_end');
      expect(session.sessionId, before);
    });

    test('exit-foreground stamps time but never ends the session', () async {
      final session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);
      final before = session.sessionId;

      clock.nowMs += 9000;
      await session.noteExitForeground(clock.nowMs);
      expect(session.sessionId, before,
          reason:
              '§C.5: no end-on-exit; the end event belongs to the next start');

      // The stamped time extends the timeout for the next background event.
      clock.nowMs += 100;
      final result = await session.processEvent(event(), inForeground: false);
      expect(result.preceding, isEmpty);
    });

    test('explicit per-event session id is kept', () async {
      final session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);

      final result = await session.processEvent(
        {'event_type': 'x', 'session_id': 555},
        inForeground: false,
      );
      expect(result.event?['session_id'], 555);
    });

    test('explicit per-event event id is kept without bumping the sequence',
        () async {
      final session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);
      // First event took event_id 2 (its session_start took 1).

      final result = await session.processEvent(
        {'event_type': 'x', 'event_id': 41},
        inForeground: false,
      );
      expect(result.event?['event_id'], 41);

      final next = await session.processEvent(event(), inForeground: false);
      expect(next.event?['event_id'], 3,
          reason: 'a kept explicit id must not consume the sequence');
    });

    test('non-integer numeric ids coerce instead of resetting', () async {
      final session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);

      final result = await session.processEvent(
        {'event_type': 'x', 'session_id': 555.0, 'event_id': 7.0},
        inForeground: false,
      );
      expect(result.event?['session_id'], 555);
      expect(result.event?['session_id'], isA<int>());
      expect(result.event?['event_id'], 7);
      expect(result.event?['event_id'], isA<int>());
    });

    test('endCurrentSession without tracked events just clears to -1',
        () async {
      final session = await makeSession(
        storage: storage,
        clock: clock,
        trackSessionEvents: false,
      );
      await session.processEvent(event(), inForeground: true);
      expect(session.sessionId, isNot(-1));

      final end = await session.endCurrentSession();
      expect(end, isNull);
      expect(session.sessionId, -1);
    });

    test('disabled session events still track ids', () async {
      final session = await makeSession(
        storage: storage,
        clock: clock,
        trackSessionEvents: false,
      );
      final result = await session.processEvent(event(), inForeground: true);
      expect(result.preceding, isEmpty);
      expect(session.sessionId, clock.nowMs);
      expect(result.event?['session_id'], clock.nowMs);
    });

    test('state restores across restarts', () async {
      var session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);
      final sessionId = session.sessionId;

      session = await makeSession(storage: storage, clock: clock);
      expect(session.sessionId, sessionId);

      // Within the gap, the restored session extends without new events.
      clock.nowMs += 1000;
      final result = await session.processEvent(event(), inForeground: false);
      expect(result.preceding, isEmpty);
      expect(session.sessionId, sessionId);
    });

    test('endCurrentSession emits end and clears to -1', () async {
      final session = await makeSession(storage: storage, clock: clock);
      await session.processEvent(event(), inForeground: true);

      final end = await session.endCurrentSession();
      expect(end?['event_type'], 'session_end');
      expect(end?['session_id'], 1000000);
      expect(session.sessionId, -1);
    });

    test('session events carry user and device ids', () async {
      final identity = DesktopIdentity(storage: storage);
      await identity.load(apiKey: 'k', seedDeviceId: 'device-1');
      await identity.setUserId('user-1');
      final session = DesktopSession(
        storage: storage,
        identity: identity,
        clock: clock.call,
        sessionGapMs: 5 * 60 * 1000,
        trackSessionEvents: true,
      );
      await session.restore();

      final result = await session.processEvent(event(), inForeground: true);
      expect(result.preceding.first['user_id'], 'user-1');
      expect(result.preceding.first['device_id'], 'device-1');
    });

    test('hostile types never throw (§E)', () async {
      final session = await makeSession(storage: storage, clock: clock);
      final result = await session.processEvent(
        {
          'event_type': 123,
          'timestamp': 'not-a-number',
          'session_id': 'also-bad',
        },
        inForeground: true,
      );
      // Non-String type is an ordinary event; bad timestamp falls back
      // to the clock; bad session_id is ignored.
      expect(result.event?['timestamp'], clock.nowMs);
      expect(result.event?['session_id'], session.sessionId);
    });
  });
}
