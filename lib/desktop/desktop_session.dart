import 'desktop_identity.dart';
import 'desktop_storage.dart';

// Session lifecycle for one backend instance (plan §C).
//
// WHY a port instead of a new design: session ids, start/end events, and
// timeout extension are server-visible semantics — freelancing here splits
// funnels between mobile and desktop. Every rule below cites Swift
// `Sessions.swift`. Dart is single-threaded, so no `NSLock` equivalent is
// needed (documented, not omitted).
class DesktopSession {
  DesktopSession({
    required DesktopStorage storage,
    required DesktopIdentity identity,
    required int Function() clock,
    required int sessionGapMs,
    required bool trackSessionEvents,
  })  : _storage = storage,
        _identity = identity,
        _clock = clock,
        _gapMs = sessionGapMs,
        _trackSessionEvents = trackSessionEvents;

  final DesktopStorage _storage;
  final DesktopIdentity _identity;
  final int Function() _clock;
  final int _gapMs;
  final bool _trackSessionEvents;

  // State (plan §C.1). `_sessionId` of -1 means "no session".
  int _sessionId = -1;
  int _lastEventId = 0;
  int _lastEventTime = -1;

  /// Current session id, or -1 when there is none (plan §C.7).
  int get sessionId => _sessionId;

  /// Restores the three persisted keys.
  Future<void> restore() async {
    _sessionId = await _storage.readInt(DesktopStoreKeys.sessionId) ?? -1;
    _lastEventId = await _storage.readInt(DesktopStoreKeys.lastEventId) ?? 0;
    _lastEventTime =
        await _storage.readInt(DesktopStoreKeys.lastEventTime) ?? -1;
  }

  Future<void> _persistSession() async {
    await _storage.writeInt(DesktopStoreKeys.sessionId, _sessionId);
  }

  Future<void> _persistEventId() async {
    await _storage.writeInt(DesktopStoreKeys.lastEventId, _lastEventId);
  }

  Future<void> _persistEventTime() async {
    await _storage.writeInt(DesktopStoreKeys.lastEventTime, _lastEventTime);
  }

  /// Processes one channel-receipt event map (plan §C.2, in order).
  ///
  /// Returns which events to enqueue: [DesktopSessionResult.preceding]
  /// session-end/start events go straight to the queue, while [event] (null
  /// when a session_start dummy was consumed) continues through identify
  /// interception and enrichment.
  Future<DesktopSessionResult> processEvent(
    Map<String, dynamic> event, {
    required bool inForeground,
  }) async {
    final preceding = <Map<String, dynamic>>[];
    // Never throw on hostile types (§E): non-num timestamps fall back to
    // the clock, non-String event types are ordinary events, and a
    // non-num session_id is ignored rather than adopted.
    final rawTs = event['timestamp'];
    final ts = rawTs is num ? rawTs.toInt() : _clock();
    event['timestamp'] = ts;
    final rawType = event['event_type'];
    final type = rawType is String ? rawType : null;

    if (type == 'session_start') {
      final rawAdopted = event['session_id'];
      if (rawAdopted == null) {
        // Dummy start (Swift `skipEvent`): never enqueued; evaluates
        // extend-vs-new whether or not a session is live, so entering
        // foreground past the gap rotates the session here instead of
        // silently extending a stale one.
        preceding.addAll(
            await _startNewSessionIfNeeded(ts, inForeground: inForeground));
        return DesktopSessionResult(preceding: preceding);
      }
      // Adopt the explicitly-started session, then fall through so the
      // event itself is enqueued with ids assigned. A non-numeric id is
      // hostile, not an adoption: time still stamps, the id resets below.
      if (rawAdopted is num) {
        _sessionId = rawAdopted.toInt();
        await _persistSession();
      }
      _lastEventTime = ts;
      await _persistEventTime();
    } else if (type != 'session_end') {
      // Every ordinary event evaluates extend-vs-new — that is what starts
      // the very first session. An explicitly-set per-event id only
      // changes what the event keeps afterwards (Swift checks the -1
      // sentinel here; in Dart, null means absent — same effect).
      preceding.addAll(
          await _startNewSessionIfNeeded(ts, inForeground: inForeground));
    }
    // `session_end` passes through with no state change (§C.2 step 3).

    // Hostile ids never survive: num coerces, anything else (including a
    // String) resets to the current session/event sequence (§E).
    final rawSid = event['session_id'];
    if (rawSid is int) {
      // Keep explicit ids.
    } else if (rawSid is num) {
      event['session_id'] = rawSid.toInt();
    } else {
      event['session_id'] = _sessionId;
    }
    final rawEid = event['event_id'];
    if (rawEid is int) {
      // Keep explicit ids.
    } else if (rawEid is num) {
      event['event_id'] = rawEid.toInt();
    } else {
      _lastEventId += 1;
      await _persistEventId();
      event['event_id'] = _lastEventId;
    }
    return DesktopSessionResult(preceding: preceding, event: event);
  }

  /// Extend-vs-new decision (Swift `:133-143`, plan §C.3).
  Future<List<Map<String, dynamic>>> _startNewSessionIfNeeded(
    int ts, {
    required bool inForeground,
  }) async {
    if (_sessionId >= 0 && (inForeground || ts - _lastEventTime < _gapMs)) {
      _lastEventTime = ts;
      await _persistEventTime();
      return const [];
    }
    return startNewSession(ts);
  }

  /// Starts a new session, emitting end/start events when enabled
  /// (Swift `:145-171`, plan §C.4).
  Future<List<Map<String, dynamic>>> startNewSession(int ts) async {
    final out = <Map<String, dynamic>>[];
    final previousId = _sessionId;
    if (_trackSessionEvents && previousId >= 0) {
      out.add(await _sessionEvent(
        'session_end',
        timestamp: _lastEventTime > 0 ? _lastEventTime : null,
        sessionId: previousId,
      ));
    }
    _sessionId = ts;
    await _persistSession();
    _lastEventTime = ts;
    await _persistEventTime();
    if (_trackSessionEvents) {
      out.add(await _sessionEvent(
        'session_start',
        timestamp: ts,
        sessionId: ts,
      ));
    }
    return out;
  }

  /// Ends the current session, emitting an end event when enabled
  /// (Swift `:173-187`, plan §C.5).
  ///
  /// NOTE: exit-foreground does NOT call this — it only stamps
  /// `lastEventTime` (see [noteExitForeground]). The end event for a quit
  /// session is emitted at the *next* session start. Closing the session on
  /// exit feels right and is wrong; the session test pins it.
  Future<Map<String, dynamic>?> endCurrentSession() async {
    if (!_trackSessionEvents || _sessionId < 0) {
      if (_sessionId >= 0) {
        _sessionId = -1;
        await _persistSession();
      }
      return null;
    }
    final end = await _sessionEvent(
      'session_end',
      timestamp: _lastEventTime > 0 ? _lastEventTime : null,
      sessionId: _sessionId,
    );
    _sessionId = -1;
    await _persistSession();
    return end;
  }

  /// Exit-foreground bookkeeping: stamp `lastEventTime` only, no end event
  /// (Swift `Amplitude.swift:533-541`).
  Future<void> noteExitForeground(int ts) async {
    _lastEventTime = ts;
    await _persistEventTime();
  }

  /// Builds a session event with user/device ids filled like normal events.
  Future<Map<String, dynamic>> _sessionEvent(
    String type, {
    required int? timestamp,
    required int sessionId,
  }) async {
    _lastEventId += 1;
    await _persistEventId();
    return {
      'event_type': type,
      if (timestamp != null) 'timestamp': timestamp,
      'event_id': _lastEventId,
      'session_id': sessionId,
      if (_identity.userId != null) 'user_id': _identity.userId,
      if (_identity.deviceId != null) 'device_id': _identity.deviceId,
    };
  }
}

/// Outcome of [DesktopSession.processEvent].
class DesktopSessionResult {
  const DesktopSessionResult({this.preceding = const [], this.event});

  /// Session-end/start events to enqueue directly (no re-processing).
  final List<Map<String, dynamic>> preceding;

  /// The processed input event, or null when a dummy was consumed.
  final Map<String, dynamic>? event;
}
