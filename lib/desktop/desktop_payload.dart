// Builds the exact HTTP upload payload (Swift `getRequestData`, plan §A.3).
//
// - `clientUploadTime` is an ISO-8601 UTC timestamp for the flush.
// - `"options": {"min_id_length": N}` is included ONLY when `minIdLength`
//   is set (follow Swift; the TS client always sends the key — rejected).
// - `request_metadata` is omitted: diagnostics-only, no diagnostics client.
Map<String, dynamic> buildDesktopPayload({
  required String apiKey,
  required List<Map<String, dynamic>> events,
  required String clientUploadTime,
  int? minIdLength,
}) {
  final payload = <String, dynamic>{
    'api_key': apiKey,
    'client_upload_time': clientUploadTime,
    'events': events,
  };
  if (minIdLength != null) {
    payload['options'] = {'min_id_length': minIdLength};
  }
  return payload;
}

/// Formats [msSinceEpoch] as the `client_upload_time` string.
String formatDesktopUploadTime(int msSinceEpoch) {
  return DateTime.fromMillisecondsSinceEpoch(msSinceEpoch, isUtc: true)
      .toIso8601String();
}

/// Deep-strips null-valued keys (maps) and null items (lists).
///
/// WHY: channel maps can carry explicit nulls (nested `plan`/`ingestion`
/// `toMap()`s include them), and the server rejects or misreads null
/// fields. Stripping once at upload keeps every enqueue path honest.
dynamic stripDesktopNulls(dynamic value) {
  if (value is Map) {
    final out = <String, dynamic>{};
    value.forEach((key, item) {
      if (item != null) {
        // Never throw on hostile key types (§E): coerce via toString.
        final name = key is String ? key : key.toString();
        out[name] = stripDesktopNulls(item);
      }
    });
    return out;
  }
  if (value is List) {
    return [
      for (final item in value)
        if (item != null) stripDesktopNulls(item),
    ];
  }
  return value;
}
