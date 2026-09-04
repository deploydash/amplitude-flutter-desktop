import 'dart:convert';

import 'desktop_compress.dart';
import 'desktop_endpoint.dart';

// Request headers for an upload (Swift `HttpClient.swift:105-112`; plan §A.2).
//
// `api_key` travels in the body, so there is no auth header. `path only,
// no query`. `Content-Encoding: gzip` is sent if and only if the body is
// gzipped.
Map<String, String> desktopHeaders({required bool gzipped}) {
  return {
    'Content-Type': 'application/json; charset=utf-8',
    'Accept': 'application/json',
    if (gzipped) 'Content-Encoding': 'gzip',
  };
}

/// Encoded upload body plus whether it ended up gzipped.
///
/// Honors §A.4: stock endpoints compress, custom `serverUrl` bodies never
// do. A compression failure falls back to sending uncompressed — it never
// drops events (Swift fallback).
({List<int> bytes, bool gzipped}) encodeDesktopBody(
  String json,
  String endpoint, {
  DesktopCompressor? compressor,
}) {
  final raw = utf8.encode(json);
  final codec = compressor ?? defaultDesktopCompressor;
  if (!isDefaultDesktopEndpoint(endpoint) || !codec.available) {
    return (bytes: raw, gzipped: false);
  }
  try {
    return (bytes: codec.encode(raw), gzipped: true);
  } catch (_) {
    // Any compressor failure (including a custom compressor throwing
    // outside `DesktopCompressError`) falls back to uncompressed — the
    // upload path never throws.
    return (bytes: raw, gzipped: false);
  }
}

/// Decodes a body produced by [encodeDesktopBody] (used by tests to assert
/// the gzip round-trip byte-for-byte).
String decodeDesktopBody(
  List<int> bytes, {
  required bool gzipped,
  DesktopCompressor? compressor,
}) {
  if (!gzipped) {
    return utf8.decode(bytes);
  }
  final codec = compressor ?? defaultDesktopCompressor;
  return utf8.decode(codec.decode(bytes));
}
