import 'package:amplitude_flutter/desktop/desktop_system_info.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Fake `DeviceInfoPlugin`: overrides only the per-OS getters so success
/// paths run on any host (no Windows/macOS machine needed — the backend
/// selects the branch via `platformOverride`).
class FakeDeviceInfoPlugin extends DeviceInfoPlugin {
  FakeDeviceInfoPlugin({this.linux, this.windows, this.macos});

  final LinuxDeviceInfo? linux;
  final WindowsDeviceInfo? windows;
  final MacOsDeviceInfo? macos;

  @override
  Future<LinuxDeviceInfo> get linuxInfo async =>
      linux ?? (throw StateError('no linux info'));

  @override
  Future<WindowsDeviceInfo> get windowsInfo async =>
      windows ?? (throw StateError('no windows info'));

  @override
  Future<MacOsDeviceInfo> get macOsInfo async =>
      macos ?? (throw StateError('no macos info'));
}

LinuxDeviceInfo linuxInfo({
  String? versionId,
  String? version,
  String prettyName = 'Ubuntu 24.04 LTS',
}) {
  return LinuxDeviceInfo(
    name: 'Ubuntu',
    version: version,
    id: 'ubuntu',
    prettyName: prettyName,
    machineId: 'machine-1',
    versionId: versionId,
  );
}

WindowsDeviceInfo windowsInfo({String displayVersion = '22H2'}) {
  return WindowsDeviceInfo(
    computerName: 'PC',
    numberOfCores: 8,
    systemMemoryInMegabytes: 16384,
    userName: 'user',
    majorVersion: 10,
    minorVersion: 0,
    buildNumber: 22621,
    platformId: 2,
    csdVersion: '',
    servicePackMajor: 0,
    servicePackMinor: 0,
    suitMask: 0,
    productType: 0,
    reserved: 0,
    buildLab: '',
    buildLabEx: '',
    digitalProductId: Uint8List(0),
    displayVersion: displayVersion,
    editionId: 'Professional',
    installDate: DateTime.utc(2024, 1, 1),
    productId: 'product',
    productName: 'Windows 11 Pro',
    registeredOwner: 'owner',
    releaseId: '',
    deviceId: 'device',
  );
}

// Production-source fallbacks: with no platform mocks every plugin lookup
// throws in unit tests, so each test below proves a lookup failure degrades
// to known platform identity (or absent values) instead of throwing.
void main() {
  group('DeviceInfoDesktopSystemInfo fallbacks', () {
    test('platform identity is always known, details degrade', () async {
      final linux = await DeviceInfoDesktopSystemInfo(
        platformOverride: TargetPlatform.linux,
      ).currentOs();
      expect(linux.platform, 'Linux');
      expect(linux.osName, 'linux');
      expect(linux.osVersion, isNull);
      expect(linux.deviceModel, isNull);

      final windows = await DeviceInfoDesktopSystemInfo(
        platformOverride: TargetPlatform.windows,
      ).currentOs();
      expect(windows.platform, 'Windows');
      expect(windows.osName, 'windows');

      final macos = await DeviceInfoDesktopSystemInfo(
        platformOverride: TargetPlatform.macOS,
      ).currentOs();
      expect(macos.platform, 'macOS');
      expect(macos.osName, 'macos');

      final unknown = await DeviceInfoDesktopSystemInfo(
        platformOverride: TargetPlatform.android,
      ).currentOs();
      expect(unknown.platform, 'Unknown');
      expect(unknown.osName, 'unknown');
    });
  });

  group('PackageInfoDesktopAppInfo fallback', () {
    test('lookup failure yields absent values', () async {
      final version = await PackageInfoDesktopAppInfo().current();
      expect(version.appVersion, isNull);
      expect(version.versionName, isNull);
    });
  });

  group('desktopLocaleTag', () {
    test('returns a non-empty tag from the platform locale', () async {
      expect(desktopLocaleTag(), isNotEmpty);
    });
  });

  group('DeviceInfoDesktopSystemInfo success paths', () {
    test('linux maps distro details, preferring versionId', () async {
      final os = await DeviceInfoDesktopSystemInfo(
        plugin: FakeDeviceInfoPlugin(
          linux: linuxInfo(versionId: '24.04', version: 'ignored'),
        ),
        platformOverride: TargetPlatform.linux,
      ).currentOs();

      expect(os.platform, 'Linux');
      expect(os.osName, 'linux');
      expect(os.osVersion, '24.04');
      expect(os.deviceModel, isNull,
          reason: 'distro name is OS fact, not hardware model');
      expect(os.deviceManufacturer, isNull);
    });

    test('linux falls back through version to prettyName', () async {
      var os = await DeviceInfoDesktopSystemInfo(
        plugin: FakeDeviceInfoPlugin(
          linux: linuxInfo(version: '24.04 (Noble Numbat)'),
        ),
        platformOverride: TargetPlatform.linux,
      ).currentOs();
      expect(os.osVersion, '24.04 (Noble Numbat)');

      os = await DeviceInfoDesktopSystemInfo(
        plugin: FakeDeviceInfoPlugin(linux: linuxInfo()),
        platformOverride: TargetPlatform.linux,
      ).currentOs();
      expect(os.osVersion, 'Ubuntu 24.04 LTS');
    });

    test('windows combines displayVersion and buildNumber', () async {
      final os = await DeviceInfoDesktopSystemInfo(
        plugin: FakeDeviceInfoPlugin(windows: windowsInfo()),
        platformOverride: TargetPlatform.windows,
      ).currentOs();

      expect(os.platform, 'Windows');
      expect(os.osName, 'windows');
      expect(os.osVersion, contains('Windows 11 Pro'));
      expect(os.osVersion, contains('22H2'));
      expect(os.osVersion, contains('22621'));
      expect(os.deviceModel, isNull,
          reason: 'Windows edition is OS fact, not hardware model');
      expect(os.deviceManufacturer, isNull);
    });

    test('windows without displayVersion reports the build number', () async {
      final os = await DeviceInfoDesktopSystemInfo(
        plugin: FakeDeviceInfoPlugin(windows: windowsInfo(displayVersion: '')),
        platformOverride: TargetPlatform.windows,
      ).currentOs();

      expect(os.osVersion, contains('Windows 11 Pro'));
      expect(os.osVersion, contains('22621'));
      expect(os.deviceModel, isNull);
    });

    test('macOS maps release, model, and Apple manufacturer', () async {
      final os = await DeviceInfoDesktopSystemInfo(
        plugin: FakeDeviceInfoPlugin(
          macos: MacOsDeviceInfo.setMockInitialValues(
            computerName: 'mac',
            hostName: 'mac.local',
            arch: 'arm64',
            model: 'Mac16,2',
            modelName: 'MacBook Air',
            kernelVersion: 'kernel',
            osRelease: '24.1.0',
            majorVersion: 15,
            minorVersion: 1,
            patchVersion: 0,
            activeCPUs: 8,
            memorySize: 17179869184,
            cpuFrequency: 0,
            systemGUID: 'guid',
          ),
        ),
        platformOverride: TargetPlatform.macOS,
      ).currentOs();

      expect(os.platform, 'macOS');
      expect(os.osName, 'macos');
      expect(os.osVersion, '24.1.0');
      expect(os.deviceModel, 'Mac16,2');
      expect(os.deviceManufacturer, 'Apple');
    });
  });

  // NOTE: `PackageInfo.fromPlatform` caches process-wide, so this group
  // must stay after the fallback group above: once the mock is set, every
  // later `fromPlatform` call in this file sees it.
  group('PackageInfoDesktopAppInfo success path', () {
    test('reports the platform version', () async {
      PackageInfo.setMockInitialValues(
        appName: 'Test App',
        packageName: 'com.example.test',
        version: '9.9.9',
        buildNumber: '99',
        buildSignature: '',
      );

      final version = await PackageInfoDesktopAppInfo().current();
      expect(version.appVersion, '9.9.9');
      expect(version.versionName, '9.9.9');
    });
  });
}
