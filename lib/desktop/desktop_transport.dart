import 'dart:convert';

import 'package:http/http.dart' as http;

import 'desktop_compress.dart';
import 'desktop_http.dart';
import 'desktop_payload.dart';

// Single-file HTTP upload (plan §A.2–A.4).
//
// WHY a thin wrapper around `package:http`: the client is injectable so
// tests script every §A.5 row with `MockClient` instead of hand-rolled HTTP
// fakes. Timeout (60 s per Swift; Node's 10 s is server-side — not copied)
// guarantees every send path settles exactly once — a hanging send must
// never wedge later flushes (the Node `http.ts` SDK-188 lesson).
class DesktopTransport {
  DesktopTransport({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 60),
    DesktopCompressor? compressor,
  })  : _client = client,
        _ownedClient = client == null,
        _compressor = compressor;

  final http.Client? _client;
  final bool _ownedClient;

  /// Per-request timeout. Tests inject milliseconds; production uses 60 s.
  final Duration requestTimeout;
  final DesktopCompressor? _compressor;

  http.Client? _cachedClient;

  /// The HTTP client for uploads. Injected clients are used directly;
  /// otherwise one client is lazily created and reused so every flush
  /// shares a single connection pool instead of leaking one per upload.
  http.Client get client => _client ?? (_cachedClient ??= http.Client());

  /// Uploads one queue file's events. Never throws: transport-level failures
  /// (timeout, DNS, refused connection, malformed URL) all surface as
  /// [DesktopHttpResult.transportFailure], which the pipeline retries.
  Future<DesktopHttpResult> upload({
    required String endpoint,
    required String apiKey,
    required List<Map<String, dynamic>> events,
    required int? minIdLength,
    required int nowMs,
  }) async {
    final stripped = stripDesktopNulls(events);
    final payload = buildDesktopPayload(
      apiKey: apiKey,
      events: (stripped as List).cast<Map<String, dynamic>>(),
      clientUploadTime: formatDesktopUploadTime(nowMs),
      minIdLength: minIdLength,
    );
    final encoded = encodeDesktopBody(
      json.encode(payload),
      endpoint,
      compressor: _compressor,
    );
    final headers = desktopHeaders(gzipped: encoded.gzipped);
    try {
      final response = await client
          .post(Uri.parse(endpoint), headers: headers, body: encoded.bytes)
          .timeout(requestTimeout);
      return DesktopHttpResult(
        statusCode: response.statusCode,
        body: response.body,
      );
    } catch (e) {
      return DesktopHttpResult.transportFailure('$e');
    }
  }

  /// Closes the owned client. No-op for injected (test-owned) clients.
  void close() {
    if (_ownedClient) {
      _cachedClient?.close();
      _cachedClient = null;
    }
  }
}

/// Outcome of one upload attempt.
class DesktopHttpResult {
  const DesktopHttpResult({required this.statusCode, required this.body});

  /// No HTTP response was received (timeout, DNS, refused, ...).
  const DesktopHttpResult.transportFailure(this.body) : statusCode = null;

  /// Null when the transport itself failed (→ retry with backoff).
  final int? statusCode;
  final String body;

  bool get transportFailed => statusCode == null;
}
