// CPU architecture via the VM's ABI descriptor.
//
// This is the single `dart:ffi` import in `lib/desktop/` (see
// `desktop_arch.dart`): it is only compiled in when `dart.library.ffi`
// exists, so the web build never sees it.
import 'dart:ffi';

/// Short architecture name for [abi], or null when it has no short name.
///
/// Only desktop ABIs map: mobile-only architectures (e.g. 32-bit ARM,
/// 32-bit RISC-V) and non-desktop OSes yield null, and callers fall back
/// to unqualified device models rather than emitting unbounded strings.
String? desktopArchName(Abi abi) {
  return switch (abi) {
    Abi.linuxX64 || Abi.windowsX64 || Abi.macosX64 => 'x64',
    Abi.linuxArm64 || Abi.windowsArm64 || Abi.macosArm64 => 'arm64',
    Abi.linuxIA32 || Abi.windowsIA32 => 'x86',
    Abi.linuxRiscv64 => 'riscv64',
    _ => null,
  };
}

/// The short architecture name for this build, or null when unknown.
String? currentDesktopArch() => desktopArchName(Abi.current());
