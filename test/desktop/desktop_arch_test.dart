import 'dart:ffi';

import 'package:amplitude_flutter/desktop/desktop_arch.dart';
import 'package:amplitude_flutter/desktop/desktop_arch_io.dart' as arch_io;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktopArchName', () {
    test('maps desktop ABIs to short names', () {
      expect(arch_io.desktopArchName(Abi.linuxX64), 'x64');
      expect(arch_io.desktopArchName(Abi.windowsX64), 'x64');
      expect(arch_io.desktopArchName(Abi.macosX64), 'x64');
      expect(arch_io.desktopArchName(Abi.linuxArm64), 'arm64');
      expect(arch_io.desktopArchName(Abi.windowsArm64), 'arm64');
      expect(arch_io.desktopArchName(Abi.macosArm64), 'arm64');
      expect(arch_io.desktopArchName(Abi.linuxIA32), 'x86');
      expect(arch_io.desktopArchName(Abi.windowsIA32), 'x86');
      expect(arch_io.desktopArchName(Abi.linuxRiscv64), 'riscv64');
    });

    test('returns null for ABIs with no short name', () {
      for (final abi in [
        Abi.androidArm,
        Abi.androidArm64,
        Abi.androidIA32,
        Abi.androidX64,
        Abi.androidRiscv64,
        Abi.fuchsiaArm64,
        Abi.fuchsiaX64,
        Abi.fuchsiaRiscv64,
        Abi.iosArm,
        Abi.iosArm64,
        Abi.iosX64,
        Abi.linuxArm,
        Abi.linuxRiscv32,
      ]) {
        expect(arch_io.desktopArchName(abi), isNull, reason: '$abi');
      }
    });

    test('is total over Abi.values', () {
      for (final abi in Abi.values) {
        arch_io.desktopArchName(abi);
      }
    });
  });

  group('currentDesktopArch', () {
    test('matches the mapping for the current ABI', () {
      expect(currentDesktopArch(), arch_io.desktopArchName(Abi.current()));
    });
  });
}
