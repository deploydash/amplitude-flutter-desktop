// Web fallback: no compression API, so bodies go out uncompressed.
//
// This variant is selected by `desktop_compress.dart` when `dart:library.io`
// is unavailable. Request headers simply omit `Content-Encoding`.
import 'desktop_compression.dart';

/// The platform-default compressor for this build.
const DesktopCompressor defaultDesktopCompressor = IdentityDesktopCompressor();
