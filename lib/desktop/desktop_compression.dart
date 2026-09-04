// Shared compression types (platform-independent side of the seam).
//
// WHY a seam at all: the desktop backend must compile for web (where no
// compression API exists) while gzipping on real desktops. See
// `desktop_compress.dart` for the conditional wiring.

/// Compresses upload bodies. One implementation per platform.
abstract class DesktopCompressor {
  /// Whether [encode] actually compresses (false = identity fallback).
  bool get available;

  /// Encodes [raw] bytes, or throws [DesktopCompressError] on failure so
  /// callers can fall back to sending uncompressed (never drop).
  List<int> encode(List<int> raw);

  /// Decodes bytes previously produced by [encode].
  List<int> decode(List<int> encoded);
}

/// Thrown when compression fails; callers must send uncompressed instead.
class DesktopCompressError implements Exception {
  const DesktopCompressError(this.message);
  final String message;

  @override
  String toString() => 'DesktopCompressError: $message';
}

/// Identity compressor: returns bytes untouched. Used on web (no compression
/// API) and by tests that want to assert on plain-text bodies.
class IdentityDesktopCompressor implements DesktopCompressor {
  const IdentityDesktopCompressor();

  @override
  bool get available => false;

  @override
  List<int> encode(List<int> raw) => raw;

  @override
  List<int> decode(List<int> encoded) => encoded;
}
