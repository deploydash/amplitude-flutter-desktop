import 'package:amplitude_flutter/desktop/desktop_dispatch.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> events(int count) {
  return List.generate(
    count,
    (i) => {
      'event_type': 'e$i',
      'user_id': 'user-$i',
      'device_id': 'device-$i',
    },
  );
}

void main() {
  group('decideDesktopDispatch', () {
    test('2xx deletes the file', () {
      for (final code in [200, 201, 299]) {
        expect(
          decideDesktopDispatch(
            statusCode: code,
            responseBody: '',
            events: events(2),
          ),
          isA<DispatchSuccess>(),
        );
      }
    });

    test('network failure and unknown codes retry', () {
      for (final code in [null, 301, 408, 500, 503]) {
        expect(
          decideDesktopDispatch(
            statusCode: code,
            responseBody: '',
            events: events(2),
          ),
          isA<DispatchRetry>(),
          reason: 'status $code',
        );
      }
    });

    test('400 with an invalid apiKey drops the whole file', () {
      final decision = decideDesktopDispatch(
        statusCode: 400,
        responseBody: '{"error": "Invalid API key: k"}',
        events: events(3),
      );
      expect(decision, isA<DispatchDropFile>());
      expect((decision as DispatchDropFile).code, 400);
    });

    test('400 with index bodies drops only those indexes', () {
      final decision = decideDesktopDispatch(
        statusCode: 400,
        responseBody: '{"events_with_invalid_fields": {"event_type": [0, 2]}, '
            '"events_with_missing_fields": {"user_id": [2]}, '
            '"silenced_events": [1]}',
        events: events(4),
      );
      expect(decision, isA<DispatchDropSome>());
      final drop = decision as DispatchDropSome;
      expect(drop.dropIndexes, {0, 1, 2});
      final parts = partitionDesktopEvents(events(4), drop);
      expect(parts.drop.length, 3);
      expect(parts.keep.length, 1);
      expect(parts.keep.first['event_type'], 'e3');
    });

    test('400 with silenced devices matches device_id', () {
      final decision = decideDesktopDispatch(
        statusCode: 400,
        responseBody: '{"silenced_devices": ["device-1"]}',
        events: events(3),
      );
      final drop = decision as DispatchDropSome;
      final parts = partitionDesktopEvents(events(3), drop);
      expect(parts.drop.length, 1);
      expect(parts.drop.first['device_id'], 'device-1');
      expect(parts.keep.length, 2);
    });

    test('unparseable 400 drops instead of poison-looping', () {
      expect(
        decideDesktopDispatch(
          statusCode: 400,
          responseBody: 'not json',
          events: events(2),
        ),
        isA<DispatchDropFile>(),
      );
    });

    test('413 splits multi-event files and drops single-event ones', () {
      expect(
        decideDesktopDispatch(
          statusCode: 413,
          responseBody: '',
          events: events(4),
        ),
        isA<DispatchSplit>(),
      );
      final single = decideDesktopDispatch(
        statusCode: 413,
        responseBody: '',
        events: events(1),
      );
      expect(single, isA<DispatchDropFile>());
      expect((single as DispatchDropFile).code, 413);
    });

    test('429 with quota bodies drops matches and throttles', () {
      final decision = decideDesktopDispatch(
        statusCode: 429,
        responseBody: '{"exceededDailyQuotaUsers": ["user-0"], '
            '"exceededDailyQuotaDevices": ["device-2"], '
            '"throttledEvents": [1]}',
        events: events(3),
      );
      final drop = decision as DispatchDropSome;
      expect(drop.throttle, isTrue);
      expect(drop.throttledIndexes, {1});
      final parts = partitionDesktopEvents(events(3), drop);
      // Quota matches drop; the throttled event is kept for retry.
      expect(parts.drop.length, 2);
      expect(parts.keep.length, 1);
      expect(parts.keep.first['event_type'], 'e1');
    });

    test('plain 429 retries without dropping', () {
      expect(
        decideDesktopDispatch(
          statusCode: 429,
          responseBody: '{}',
          events: events(2),
        ),
        isA<DispatchRetry>(),
      );
    });

    test('unparseable 429 retries instead of throwing', () {
      expect(
        decideDesktopDispatch(
          statusCode: 429,
          responseBody: 'not-json{{{',
          events: events(2),
        ),
        isA<DispatchRetry>(),
      );
    });

    test('400 naming no event drops the file with the server message', () {
      final decision = decideDesktopDispatch(
        statusCode: 400,
        responseBody: '{"error": "billing expired"}',
        events: events(2),
      );
      expect(decision, isA<DispatchDropFile>());
      expect((decision as DispatchDropFile).message, 'billing expired');
    });

    test('400 with a non-integer numeric index still drops it', () {
      final decision = decideDesktopDispatch(
        statusCode: 400,
        responseBody: '{"events_with_invalid_fields": {"event_type": [2.0]}}',
        events: events(3),
      );
      expect(decision, isA<DispatchDropSome>());
      expect((decision as DispatchDropSome).dropIndexes, {2});
    });

    test('429 quota lists nested in maps still match', () {
      final decision = decideDesktopDispatch(
        statusCode: 429,
        responseBody: '{"exceededDailyQuotaDevices": {"region": ["device-1"]}}',
        events: events(2),
      );
      expect(decision, isA<DispatchDropSome>());
      final parts =
          partitionDesktopEvents(events(2), decision as DispatchDropSome);
      expect(parts.drop.map((e) => e['device_id']), ['device-1']);
      expect(parts.keep, hasLength(1));
    });
  });
}
