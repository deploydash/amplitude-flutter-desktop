import 'dart:async';
import 'dart:convert';

import 'desktop_constants.dart';
import 'desktop_storage.dart';

// Identify batching for `$identify` events (plan §F).
//
// WHY this exists: back-to-back `$set`-only identifies (login funnels,
// progressive profiling) collapse into ONE `$identify` with a shallow-merged
// `$set`, instead of one HTTP event each. Ports `IdentifyInterceptor.swift`
// exactly: the interceptible predicate, hold + one-shot transfer timer, FIFO
// combine, CLEAR_ALL handling, and the separate identify store.
//
// SERIALIZATION: every public method must be called from the backend's
// single-writer chain (the timer re-enters through the backend too), so no
// locking lives here — same assumption as [DesktopStorage].

/// Creates one-shot timers. Tests inject a manual-fire fake.
typedef DesktopTimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

/// Outcome of [DesktopIdentifyInterceptor.process]: held-batch transfers to
/// emit first (in order), plus the triggering event when it passes.
///
/// The backend enqueues [transfers] before [event] so a `$set` held for
/// batching is never dropped (plan §F, Swift `pipeline.put`). Null [event]
/// means the triggering event itself was held for batching.
class DesktopInterceptResult {
  const DesktopInterceptResult({this.transfers = const [], this.event});

  /// Combined `$identify` events drained from the hold, oldest first.
  /// Empty when nothing was held.
  final List<Map<String, dynamic>> transfers;

  /// The triggering event to enqueue, or null when it was held.
  final Map<String, dynamic>? event;
}

/// True when [event] may be held for batching: `$identify` with empty
/// groups whose `user_properties` contain ONLY `$set` (Swift `:199-203`).
bool isInterceptibleDesktopIdentify(Map<String, dynamic> event) {
  if (event['event_type'] != r'$identify') {
    return false;
  }
  final groups = event['groups'];
  if (groups is Map && groups.isNotEmpty) {
    return false;
  }
  final properties = event['user_properties'];
  if (properties is! Map) {
    return false;
  }
  if (properties.length != 1 || !properties.containsKey(r'$set')) {
    return false;
  }
  return (properties[r'$set'] is Map);
}

class DesktopIdentifyInterceptor {
  DesktopIdentifyInterceptor({
    required DesktopStorage storage,
    required int identifyBatchIntervalMillis,
    required int Function() clock,
    required void Function() onTimerFired,
    DesktopTimerFactory? timerFactory,
    void Function(String message)? onWarn,
  })  : _storage = storage,
        _clock = clock,
        _onTimerFired = onTimerFired,
        _timerFactory =
            timerFactory ?? ((duration, callback) => Timer(duration, callback)),
        _onWarn = onWarn {
    var interval = identifyBatchIntervalMillis;
    if (interval < desktopMinIdentifyBatchIntervalMillis) {
      _onWarn?.call(
        'identifyBatchIntervalMillis $identifyBatchIntervalMillis is below '
        'the 30000 ms minimum; floored to 30000.',
      );
      interval = desktopMinIdentifyBatchIntervalMillis;
    }
    _interval = Duration(milliseconds: interval);
  }

  final DesktopStorage _storage;
  final int Function() _clock;
  final void Function() _onTimerFired;
  final DesktopTimerFactory _timerFactory;
  final void Function(String message)? _onWarn;
  late final Duration _interval;

  Map<String, dynamic>? _heldSet;
  String? _heldUserId;
  String? _heldDeviceId;
  String? _lastUserId;
  String? _lastDeviceId;
  Timer? _timer;

  /// Restores a held `$identify` persisted by an earlier run.
  Future<void> restore() async {
    try {
      final raw = await _storage.readString(DesktopStoreKeys.heldIdentify);
      if (raw == null) {
        return;
      }
      final held = json.decode(raw) as Map<String, dynamic>;
      final set = held[r'$set'];
      if (set is! Map) {
        await _clearHeld();
        return;
      }
      _heldSet = Map<String, dynamic>.from(set);
      _heldUserId =
          await _storage.readString(DesktopStoreKeys.heldIdentifyUserId);
      _heldDeviceId =
          await _storage.readString(DesktopStoreKeys.heldIdentifyDeviceId);
      // A restored hold still needs its fixed-window deadline: schedule
      // exactly one timer, never duplicating an already-active one.
      _ensureTimer();
    } catch (_) {
      await _clearHeld();
    }
  }

  /// Routes one session-processed event.
  ///
  /// Returns transfers drained from the hold (in order) plus the triggering
  /// event when it passes. The backend enqueues [DesktopInterceptResult]
  /// transfers first via `holdable: false` (so they gain session/event
  /// ids) and then the event; null event means the trigger was held.
  Future<DesktopInterceptResult> process(
    Map<String, dynamic> event,
  ) async {
    final transfers = <Map<String, dynamic>>[];
    Future<void> drain() async {
      final combined = await transfer();
      if (combined != null) {
        transfers.add(combined);
      }
    }

    final userId = _stringId(event['user_id']);
    final deviceId = _stringId(event['device_id']);
    if (_identityChanged(userId, deviceId)) {
      await drain();
    }
    _lastUserId = userId;
    _lastDeviceId = deviceId;

    final type = event['event_type'];
    final properties = event['user_properties'];
    final hasClearAll =
        properties is Map && properties.containsKey(r'$clearAll');

    if (type == r'$identify') {
      // `$identify` with `$clearAll` clears the held batch and passes.
      if (hasClearAll) {
        await _clearHeld();
        return DesktopInterceptResult(transfers: transfers, event: event);
      }
      // Interceptible `$identify` is held; the fixed batch window starts with
      // the first hold and later holds keep that same deadline.
      if (isInterceptibleDesktopIdentify(event)) {
        await _hold(event);
        _ensureTimer();
        return DesktopInterceptResult(transfers: transfers);
      }
      // Any other `$identify` (e.g. with `$add`) flushes the hold first.
      await drain();
      return DesktopInterceptResult(transfers: transfers, event: event);
    }
    // `$groupidentify` passes with the hold untouched.
    if (type == r'$groupidentify') {
      return DesktopInterceptResult(transfers: transfers, event: event);
    }
    // Any other event: `$clearAll` in its properties clears the hold,
    // otherwise the hold transfers first.
    if (hasClearAll) {
      await _clearHeld();
    } else {
      await drain();
    }
    return DesktopInterceptResult(transfers: transfers, event: event);
  }

  /// Combines the held batch into ONE `$identify` (FIFO, shallow-merged
  /// `$set`, source-wins except null keeps old — Swift `mergeUserProperties`
  /// `:189-194`). Returns null when nothing is held.
  Future<Map<String, dynamic>?> transfer() async {
    _timer?.cancel();
    _timer = null;
    final held = _heldSet;
    if (held == null || held.isEmpty) {
      return null;
    }
    final combined = <String, dynamic>{
      'event_type': r'$identify',
      'user_properties': {r'$set': Map<String, dynamic>.from(held)},
      if (_heldUserId != null) 'user_id': _heldUserId,
      if (_heldDeviceId != null) 'device_id': _heldDeviceId,
      'timestamp': _clock(),
    };
    await _clearHeld();
    return combined;
  }

  bool _identityChanged(String? userId, String? deviceId) {
    return (userId != _lastUserId || deviceId != _lastDeviceId) &&
        (_heldSet != null);
  }

  /// Coerces channel ids the way the event translator does: String wins,
  /// num stringifies, anything else drops to null. Never throws on types.
  String? _stringId(dynamic value) {
    if (value == null) {
      return null;
    } else if (value is String) {
      return value;
    } else if (value is num) {
      return value.toString();
    }
    return null;
  }

  Future<void> _hold(Map<String, dynamic> event) async {
    assert(
      isInterceptibleDesktopIdentify(event),
      r'only $set-only identifies may be held',
    );
    final incoming = Map<String, dynamic>.from(
        (event['user_properties'] as Map)[r'$set'] as Map);
    _heldSet ??= <String, dynamic>{};
    // First held event wins the identity snapshot: an identity change
    // transfers before a new identity can be held (see [process]).
    _heldUserId ??= _stringId(event['user_id']);
    _heldDeviceId ??= _stringId(event['device_id']);
    for (final entry in incoming.entries) {
      // Held events hold only `$set` keys by the interceptible definition
      // (asserted above); null values keep the older value per Swift
      // `mergeUserProperties`.
      if (entry.value != null) {
        _heldSet![entry.key] = entry.value;
      }
    }
    await _persistHeld();
  }

  Future<void> _persistHeld() async {
    await _storage.writeString(
      DesktopStoreKeys.heldIdentify,
      json.encode({r'$set': _heldSet}),
    );
    if (_heldUserId == null) {
      await _storage.deleteKey(DesktopStoreKeys.heldIdentifyUserId);
    } else {
      await _storage.writeString(
          DesktopStoreKeys.heldIdentifyUserId, _heldUserId!);
    }
    if (_heldDeviceId == null) {
      await _storage.deleteKey(DesktopStoreKeys.heldIdentifyDeviceId);
    } else {
      await _storage.writeString(
          DesktopStoreKeys.heldIdentifyDeviceId, _heldDeviceId!);
    }
  }

  Future<void> _clearHeld() async {
    _timer?.cancel();
    _timer = null;
    _heldSet = null;
    _heldUserId = null;
    _heldDeviceId = null;
    await _storage.deleteKey(DesktopStoreKeys.heldIdentify);
    await _storage.deleteKey(DesktopStoreKeys.heldIdentifyUserId);
    await _storage.deleteKey(DesktopStoreKeys.heldIdentifyDeviceId);
  }

  /// Starts the batch timer only when none is active.
  ///
  /// WHY: the window is fixed from the first held identify (Swift schedules
  /// the one-shot only when no timer exists). Restarting on every hold would
  /// let a continuous stream postpone delivery indefinitely.
  void _ensureTimer() {
    final current = _timer;
    if (current != null && current.isActive) {
      return;
    }
    current?.cancel();
    _timer = _timerFactory(_interval, _onTimerFired);
  }

  /// Cancels timers. Test/close hook — the backend owns lifecycle.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
