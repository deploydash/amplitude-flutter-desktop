// Desktop compression via the VM's gzip codec.
//
// This is the single `dart:io` import in `lib/desktop/` (see
// `desktop_compress.dart`): it is only compiled in when `dart.library.io`
// exists, so the web build never sees it.
import 'dart:io';

import 'desktop_compression.dart';

/// Gzip compressor for real desktop runtimes (plan §A.4).
class GzipDesktopCompressor implements DesktopCompressor {
  const GzipDesktopCompressor();

  @override
  bool get available => true;

  @override
  List<int> encode(List<int> raw) {
    try {
      return gzip.encode(raw);
    } catch (e) {
      throw DesktopCompressError('gzip encode failed: $e');
    }
  }

  @override
  List<int> decode(List<int> encoded) {
    try {
      return gzip.decode(encoded);
    } catch (e) {
      throw DesktopCompressError('gzip decode failed: $e');
    }
  }
}

/// The platform-default compressor for this build.
const DesktopCompressor defaultDesktopCompressor = GzipDesktopCompressor();
