import 'dart:async';

import 'package:amplitude_flutter/desktop/desktop_identify_interceptor.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Manual-fire one-shot timer: the test decides exactly when it expires.
class ManualTimer implements Timer {
  ManualTimer();
  void Function()? callback;
  bool _active = true;

  void fire() {
    if (_active) {
      _active = false;
      callback!();
    }
  }

  @override
  void cancel() {
    _active = false;
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

Map<String, dynamic> identifyEvent(Map<String, dynamic> userProperties,
    {String? userId, String? deviceId}) {
  return {
    'event_type': r'$identify',
    'user_properties': userProperties,
    if (userId != null) 'user_id': userId,
    if (deviceId != null) 'device_id': deviceId,
  };
}

void main() {
  group('isInterceptibleDesktopIdentify', () {
    test(r'accepts only empty-group $set-only identifies', () {
      expect(
          isInterceptibleDesktopIdentify(identifyEvent({
            r'$set': {'a': 1}
          })),
          isTrue);
      expect(
          isInterceptibleDesktopIdentify(identifyEvent({
            r'$set': {'a': 1},
            r'$add': {'b': 1},
          })),
          isFalse,
          reason: r'anything beyond $set passes through');
      expect(isInterceptibleDesktopIdentify(identifyEvent({})), isFalse);
      expect(
          isInterceptibleDesktopIdentify({
            'event_type': r'$identify',
            'groups': {'g': 'x'},
            'user_properties': {
              r'$set': {'a': 1}
            },
          }),
          isFalse,
          reason: 'non-empty groups pass through');
      expect(
          isInterceptibleDesktopIdentify({
            'event_type': 'click',
            'user_properties': {r'$set': {}}
          }),
          isFalse);
    });
  });

  group('DesktopIdentifyInterceptor', () {
    late InMemoryDesktopStorage storage;
    late List<ManualTimer> timers;
    late int timerFires;
    late List<String> warnings;

    DesktopIdentifyInterceptor makeInterceptor({
      int intervalMillis = 30000,
      int Function()? clock,
    }) {
      return DesktopIdentifyInterceptor(
        storage: storage,
        identifyBatchIntervalMillis: intervalMillis,
        clock: clock ?? (() => 999),
        onTimerFired: () => timerFires++,
        timerFactory: (duration, callback) {
          final timer = ManualTimer()..callback = callback;
          timers.add(timer);
          return timer;
        },
        onWarn: warnings.add,
      );
    }

    setUp(() async {
      storage = InMemoryDesktopStorage();
      await storage.init();
      timers = [];
      timerFires = 0;
      warnings = [];
    });

    test(r'holds $set identifies and transfers one combined event', () async {
      final interceptor = makeInterceptor();
      var result = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }, userId: 'u'));
      expect(result.event, isNull);
      expect(result.transfers, isEmpty);
      result = await interceptor.process(identifyEvent({
        r'$set': {'b': 2}
      }, userId: 'u'));
      expect(result.event, isNull);
      expect(result.transfers, isEmpty);
      expect(timers.length, 1, reason: 'fixed window keeps the first timer');
      expect(timers.first.isActive, isTrue);

      final combined = await interceptor.transfer();
      expect(combined, {
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'a': 1, 'b': 2}
        },
        'user_id': 'u',
        'timestamp': 999,
      });
      expect(await interceptor.transfer(), isNull);
    });

    test('second hold keeps the first batch timer', () async {
      final interceptor = makeInterceptor();
      await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      await interceptor.process(identifyEvent({
        r'$set': {'b': 2}
      }));

      expect(timers, hasLength(1));
      expect(timers.first.isActive, isTrue);
    });

    test('firing the first timer transfers the merged batch', () async {
      final interceptor = makeInterceptor();
      await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      await interceptor.process(identifyEvent({
        r'$set': {'b': 2}
      }));

      timers.single.fire();
      expect(timerFires, 1);
      final combined = await interceptor.transfer();
      expect((combined!['user_properties'] as Map)[r'$set'], {'a': 1, 'b': 2});
    });

    test('continuous identifies do not move the deadline', () async {
      final interceptor = makeInterceptor();
      for (var i = 0; i < 5; i++) {
        await interceptor.process(identifyEvent({
          r'$set': {'k$i': i}
        }));
      }
      expect(timers, hasLength(1));
      expect(timers.first.isActive, isTrue);
    });

    test('next batch after transfer starts a new timer', () async {
      final interceptor = makeInterceptor();
      await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(timers, hasLength(1));
      await interceptor.transfer();
      await interceptor.process(identifyEvent({
        r'$set': {'b': 2}
      }));
      expect(timers, hasLength(2));
      expect(timers.last.isActive, isTrue);
    });

    test('hold after timer expiry starts a fresh timer', () async {
      final interceptor = makeInterceptor();
      await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(timers, hasLength(1));
      timers.single.fire();
      expect(timers.single.isActive, isFalse);

      await interceptor.process(identifyEvent({
        r'$set': {'b': 2}
      }));
      expect(timers, hasLength(2));
      expect(timers.last.isActive, isTrue);
    });

    test('source wins except null keeps old', () async {
      final interceptor = makeInterceptor();
      var result = await interceptor.process(identifyEvent({
        r'$set': {'a': 1, 'b': 1}
      }));
      expect(result.event, isNull);
      result = await interceptor.process(identifyEvent({
        r'$set': {'a': 2, 'b': null}
      }));
      expect(result.event, isNull);
      final combined = await interceptor.transfer();
      expect((combined!['user_properties'] as Map)[r'$set'], {'a': 2, 'b': 1});
    });

    test(r'$clearAll identify clears the hold and passes', () async {
      final interceptor = makeInterceptor();
      final held = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(held.event, isNull);
      final event = identifyEvent({r'$clearAll': '-'});
      final result = await interceptor.process(event);
      expect(result.event, same(event));
      expect(result.transfers, isEmpty);
      expect(await interceptor.transfer(), isNull);
    });

    test(r'non-$set $identify transfers the hold first', () async {
      // Behavior change: previously the held `$set` was silently dropped
      // here (transfer() return ignored). Per plan §F the combined
      // `$identify` must emit before the triggering event (Swift
      // `pipeline.put`), so process() now returns it in `transfers`.
      final interceptor = makeInterceptor();
      final held = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(held.event, isNull);
      final other = identifyEvent({
        r'$add': {'n': 1}
      });
      final result = await interceptor.process(other);
      expect(result.event, same(other));
      expect(result.transfers, hasLength(1));
      expect((result.transfers.single['user_properties'] as Map)[r'$set'],
          {'a': 1});
      // The hold was drained into `transfers`; nothing remains.
      expect(await interceptor.transfer(), isNull);
    });

    test(r'$groupidentify passes with the hold untouched', () async {
      final interceptor = makeInterceptor();
      final held = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(held.event, isNull);
      final group = {
        'event_type': r'$groupidentify',
        'groups': {'g': 'x'},
      };
      final result = await interceptor.process(group);
      expect(result.event, same(group));
      expect(result.transfers, isEmpty);
      expect((await interceptor.transfer())!['user_properties'], {
        r'$set': {'a': 1}
      });
    });

    test('plain events transfer the hold and pass', () async {
      // Behavior change: see the non-$set test above — the held batch
      // emits in `transfers` instead of vanishing.
      final interceptor = makeInterceptor();
      final held = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(held.event, isNull);
      final click = {'event_type': 'click'};
      final result = await interceptor.process(click);
      expect(result.event, same(click));
      expect(result.transfers, hasLength(1));
      expect((result.transfers.single['user_properties'] as Map)[r'$set'],
          {'a': 1});
      expect(await interceptor.transfer(), isNull);
    });

    test('identity change transfers the hold first', () async {
      // Behavior change: the u1 batch previously vanished when the u2
      // event arrived. It now emits in `transfers` before u2 is held.
      final interceptor = makeInterceptor();
      final first = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }, userId: 'u1'));
      expect(first.event, isNull);
      final otherUser = identifyEvent({
        r'$set': {'b': 2}
      }, userId: 'u2');
      // The u1 batch must go out before the u2 event is held.
      final result = await interceptor.process(otherUser);
      expect(result.event, isNull, reason: 'u2 is held for batching');
      expect(result.transfers, hasLength(1));
      expect((result.transfers.single['user_properties'] as Map)[r'$set'],
          {'a': 1});
      expect(result.transfers.single['user_id'], 'u1');
      final combined = await interceptor.transfer();
      expect((combined!['user_properties'] as Map)[r'$set'], {'b': 2});
      expect(combined['user_id'], 'u2');
    });

    test('timer expiry notifies the backend to drain', () async {
      final interceptor = makeInterceptor();
      final held = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(held.event, isNull);
      expect(timerFires, 0);
      timers.last.fire();
      expect(timerFires, 1);
      interceptor.dispose();
    });

    test('interval below 30 s is floored with a warning', () async {
      makeInterceptor(intervalMillis: 1000);
      expect(warnings, hasLength(1));
    });

    test('held batch survives restarts via the separate store', () async {
      var interceptor = makeInterceptor();
      final held = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }, deviceId: 'd1'));
      expect(held.event, isNull);

      interceptor = makeInterceptor();
      await interceptor.restore();
      final combined = await interceptor.transfer();
      expect((combined!['user_properties'] as Map)[r'$set'], {'a': 1});
      expect(combined['device_id'], 'd1');
    });

    test('restore schedules exactly one timer without duplication', () async {
      var interceptor = makeInterceptor();
      await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(timers, hasLength(1));

      interceptor = makeInterceptor();
      await interceptor.restore();
      expect(timers, hasLength(2),
          reason: 'restored hold must schedule a batch timer');
      expect(timers.last.isActive, isTrue);

      await interceptor.restore();
      expect(timers, hasLength(2),
          reason: 'second restore must not duplicate the active timer');
    });

    test('corrupt persisted hold restores to empty, never throws', () async {
      await storage.writeString(DesktopStoreKeys.heldIdentify, 'not-json{{{');
      var interceptor = makeInterceptor();
      await interceptor.restore();
      expect(await interceptor.transfer(), isNull);
      expect(await storage.readString(DesktopStoreKeys.heldIdentify), isNull,
          reason: 'the corrupt hold must be cleared, not left to rot');

      await storage.writeString(DesktopStoreKeys.heldIdentify, '{"\$set": 42}');
      interceptor = makeInterceptor();
      await interceptor.restore();
      expect(await interceptor.transfer(), isNull,
          reason: r'a $set that is not a Map cannot be held');
      expect(await storage.readString(DesktopStoreKeys.heldIdentify), isNull);
    });

    test(r'$clearAll on a plain event clears the hold and passes', () async {
      final interceptor = makeInterceptor();
      final held = await interceptor.process(identifyEvent({
        r'$set': {'a': 1}
      }));
      expect(held.event, isNull);

      final click = {
        'event_type': 'click',
        r'$clearAll': '-',
        'user_properties': {r'$clearAll': '-'},
      };
      final result = await interceptor.process(click);
      expect(result.event, same(click));
      expect(result.transfers, isEmpty);
      expect(await interceptor.transfer(), isNull);
    });

    test('events without a properties map pass straight through', () async {
      final interceptor = makeInterceptor();
      final plain = {'event_type': 'click'};
      final result = await interceptor.process(plain);

      expect(result.event, same(plain));
      expect(result.transfers, isEmpty);
      expect(await interceptor.transfer(), isNull);
    });

    test(r'$identify without properties is not interceptible', () async {
      final interceptor = makeInterceptor();
      final result = await interceptor.process({
        'event_type': r'$identify',
      });

      expect(result.event?['event_type'], r'$identify');
      expect(result.transfers, isEmpty);
    });

    test('numeric user and device ids coerce to strings', () async {
      final interceptor = makeInterceptor();
      final held = await interceptor.process({
        'event_type': r'$identify',
        'user_properties': {
          r'$set': {'a': 1}
        },
        'user_id': 42,
        'device_id': 7,
      });
      expect(held.event, isNull);

      final combined = await interceptor.transfer();
      expect(combined!['user_id'], '42');
      expect(combined['device_id'], '7');
    });
  });
}
