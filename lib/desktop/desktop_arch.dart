// Platform wiring for CPU architecture lookup.
//
// The `dart.library.ffi` condition resolves at compile time: VM builds
// (Linux/Windows/macOS and `flutter test`) read `Abi.current()`, web
// builds get the null fallback. Callers program against
// [currentDesktopArch] only; [desktopArchName] is exposed for tests.
export 'desktop_arch_stub.dart' if (dart.library.ffi) 'desktop_arch_io.dart';
