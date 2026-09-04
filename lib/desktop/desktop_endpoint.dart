import '../constants.dart';
import 'desktop_constants.dart';

// Derives the ingestion endpoint for a flush.
//
// WHY the order matters (plan §A.1, re-derived per flush, never cached):
//  1. A non-empty `serverUrl` wins verbatim (Swift `HttpClient.swift:79-86`).
//  2. Otherwise the server zone picks the host, and `useBatch` picks the
//     path — batch mode is a different endpoint, not a payload tweak
//     (core `getServerUrl` behavior).
String deriveDesktopEndpoint({
  String? serverUrl,
  required ServerZone zone,
  required bool useBatch,
}) {
  if (serverUrl != null && serverUrl.isNotEmpty) {
    return serverUrl;
  }
  final isEu = zone == ServerZone.eu;
  if (useBatch) {
    return isEu ? DesktopEndpoints.euBatch : DesktopEndpoints.usBatch;
  }
  return isEu ? DesktopEndpoints.eu : DesktopEndpoints.us;
}

// True when [url] is a stock Amplitude endpoint (and therefore gzipped).
//
// WHY: custom `serverUrl` bodies are never gzipped — `Configuration` has no
// `enableRequestBodyCompression` field and Swift defaults it to false, so
// "never" is the parity behavior (plan §A.4).
bool isDefaultDesktopEndpoint(String url) {
  return url == DesktopEndpoints.us ||
      url == DesktopEndpoints.usBatch ||
      url == DesktopEndpoints.eu ||
      url == DesktopEndpoints.euBatch;
}
