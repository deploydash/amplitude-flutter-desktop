// Web fallback: no `dart:ffi`, so the architecture is unknown and device
// models stay unqualified.
//
// This variant is selected by `desktop_arch.dart` when `dart:library.ffi`
// is unavailable.

/// The short architecture name for this build, or null when unknown.
String? currentDesktopArch() => null;
