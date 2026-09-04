// Platform wiring for upload compression (plan §A.4).
//
// The `dart.library.io` condition resolves at compile time: VM builds
// (Linux/Windows/macOS and `flutter test`) get real gzip, web builds get
// the identity fallback. Callers program against [DesktopCompressor] and
// [defaultDesktopCompressor] only.
export 'desktop_compress_stub.dart'
    if (dart.library.io) 'desktop_compress_io.dart';
export 'desktop_compression.dart';
