import 'dart:convert';

// §A.5 status dispatch (pure decision function).
//
// WHY pure: every row of the retry table (success / bad-index / bad-key /
// quota / split / backoff / offline-trip) must be pinned by scripted tests
// without HTTP. This function maps (status, body, events) to a decision;
// the backend applies it to storage. Rule of thumb (§A.6): a 400 retried
// verbatim is a poison loop, a 429 dropped is data loss.

/// Outcome of uploading one queue file.
abstract class DesktopDispatch {
  const DesktopDispatch();
}

/// 2xx: delete the file, fire success callbacks, reset the failures counter.
class DispatchSuccess extends DesktopDispatch {
  const DispatchSuccess();
}

/// Final rejection of the whole file (bad apiKey, unparseable 400,
/// single-event 413): delete it, firing [code]/[message] per event.
class DispatchDropFile extends DesktopDispatch {
  const DispatchDropFile({required this.code, required this.message});
  final int code;
  final String message;
}

/// Partial 400: drop the indexed/id-matched events (with callbacks),
/// requeue the survivors at the pipeline front.
class DispatchDropSome extends DesktopDispatch {
  const DispatchDropSome({
    this.dropIndexes = const {},
    this.dropDeviceIds = const {},
    required this.code,
    required this.message,
  });
  final Set<int> dropIndexes;
  final Set<String> dropDeviceIds;
  final int code;
  final String message;
}

/// Retryable (408 / 429 / 5xx / network error / unknown): leave the file in
/// place; the backend bumps `failures` and backs off.
class DispatchRetry extends DesktopDispatch {
  const DispatchRetry();
}

/// 413 on a multi-event file: split into halves and retry.
class DispatchSplit extends DesktopDispatch {
  const DispatchSplit();
}

/// Maps a status code first (TS `base.ts:84-111`): 2xx success, 429 rate
/// limit, 413 too large, 408 timeout, other 4xx invalid, ≥500 failed,
/// anything else unknown (= retry).
DesktopDispatch decideDesktopDispatch({
  required int? statusCode,
  required String responseBody,
  required List<Map<String, dynamic>> events,
}) {
  if (statusCode == null) {
    return const DispatchRetry();
  }
  if (statusCode >= 200 && statusCode < 300) {
    return const DispatchSuccess();
  }
  if (statusCode == 408 || statusCode >= 500) {
    return const DispatchRetry();
  }
  if (statusCode == 413) {
    if (events.length > 1) {
      return const DispatchSplit();
    }
    return const DispatchDropFile(
      code: 413,
      message: 'Payload too large for a single event',
    );
  }
  if (statusCode == 429) {
    // Pinned upstream parity: retain the whole oldest file and retry it
    // through the ordered retry engine. The body is intentionally ignored
    // (canonical snake_case fixtures in tests guard against reintroducing
    // camelCase parsing or event dropping).
    return const DispatchRetry();
  }
  if (statusCode >= 400 && statusCode < 500) {
    return _decideBadRequest(responseBody);
  }
  return const DispatchRetry();
}

DesktopDispatch _decideBadRequest(String body) {
  Map<String, dynamic>? parsed;
  try {
    parsed = json.decode(body) as Map<String, dynamic>?;
  } catch (_) {
    parsed = null;
  }
  if (parsed == null) {
    // A 400 we cannot parse would poison-loop on retry — drop it loudly.
    return const DispatchDropFile(code: 400, message: 'Invalid request');
  }
  final error = parsed['error'];
  if (error is String && error.startsWith('Invalid API key')) {
    return const DispatchDropFile(code: 400, message: 'Invalid API key');
  }
  final dropIndexes = <int>{};
  for (final key in [
    'events_with_invalid_fields',
    'events_with_missing_fields',
    'silenced_events',
  ]) {
    dropIndexes.addAll(_flattenIndexes(parsed[key]));
  }
  final dropDeviceIds = _flattenStrings(parsed['silenced_devices']);
  if (dropIndexes.isEmpty && dropDeviceIds.isEmpty) {
    // A 400 naming no event is still final for the file — retrying the
    // identical body would loop forever.
    final message =
        error is String && error.isNotEmpty ? error : 'Invalid request';
    return DispatchDropFile(code: 400, message: message);
  }
  return DispatchDropSome(
    dropIndexes: dropIndexes,
    dropDeviceIds: dropDeviceIds,
    code: 400,
    message: error is String && error.isNotEmpty ? error : 'Invalid event',
  );
}

/// Collects every int in a nested index structure. 400 index lists arrive
/// either flat (`"events_with_missing_fields": {"event_id": [2]}` values
/// are the arrays) or nested per-key — flatten all values (Swift
/// `handleBadRequestResponse:51-104`).
Set<int> _flattenIndexes(dynamic node) {
  final out = <int>{};
  void visit(dynamic value) {
    if (value is int) {
      out.add(value);
    } else if (value is num) {
      out.add(value.toInt());
    } else if (value is List) {
      for (final item in value) {
        visit(item);
      }
    } else if (value is Map) {
      for (final item in value.values) {
        visit(item);
      }
    }
  }

  visit(node);
  return out;
}

/// Collects every string in a nested structure (quota/silenced id lists).
Set<String> _flattenStrings(dynamic node) {
  final out = <String>{};
  void visit(dynamic value) {
    if (value is String) {
      out.add(value);
    } else if (value is List) {
      for (final item in value) {
        visit(item);
      }
    } else if (value is Map) {
      for (final item in value.values) {
        visit(item);
      }
    }
  }

  visit(node);
  return out;
}

/// Partitions [events] into survivors and drops per a [DispatchDropSome].
/// Index drops win; id drops match `user_id`/`device_id`.
({List<Map<String, dynamic>> keep, List<Map<String, dynamic>> drop})
    partitionDesktopEvents(
  List<Map<String, dynamic>> events,
  DispatchDropSome decision,
) {
  final keep = <Map<String, dynamic>>[];
  final drop = <Map<String, dynamic>>[];
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    final deviceId = event['device_id']?.toString();
    if (decision.dropIndexes.contains(i) ||
        (deviceId != null && decision.dropDeviceIds.contains(deviceId))) {
      drop.add(event);
    } else {
      keep.add(event);
    }
  }
  return (keep: keep, drop: drop);
}
