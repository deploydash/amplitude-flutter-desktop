import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

// OS/app facts for enrichment, behind wrapper interfaces (plan §H.5).
//
// WHY wrappers instead of calling the plugins inline: every enrichment
// field is gated by a `trackingOptions` flag and must be unit-testable with
// fake distro values (Ubuntu vs Arch vs Windows 10 vs 11). Fakes implement
// these two interfaces; production uses the defaults below. No `dart:io`
// anywhere — platform identity comes from `defaultTargetPlatform` with a
// `device_info_plus` detail lookup, so this file compiles for web too.

/// OS facts stamped onto events.
class DesktopOsInfo {
  const DesktopOsInfo({
    required this.platform,
    required this.osName,
    this.osVersion,
    this.deviceModel,
    this.deviceManufacturer,
  });

  /// `Linux`, `Windows`, or `macOS` (new desktop convention — the server
  /// takes free strings).
  final String platform;

  /// Lowercase sibling of [platform].
  final String osName;
  final String? osVersion;
  final String? deviceModel;
  final String? deviceManufacturer;
}

/// App facts stamped onto events.
class DesktopAppVersion {
  const DesktopAppVersion({this.appVersion, this.versionName});

  final String? appVersion;
  final String? versionName;
}

/// Source of [DesktopOsInfo]. Fake it in tests.
abstract class DesktopSystemInfoSource {
  Future<DesktopOsInfo> currentOs();
}

/// Source of [DesktopAppVersion]. Fake it in tests.
abstract class DesktopAppInfoSource {
  Future<DesktopAppVersion> current();
}

/// Production OS facts via `device_info_plus` (the ported Aptabase
/// `sys_info.dart` shape). Any lookup failure degrades to the
/// `_platformFallbackOsInfo` pattern: platform identity is always known,
/// detail fields simply stay absent.
class DeviceInfoDesktopSystemInfo implements DesktopSystemInfoSource {
  DeviceInfoDesktopSystemInfo({
    DeviceInfoPlugin? plugin,
    TargetPlatform? platformOverride,
  })  : _plugin = plugin ?? DeviceInfoPlugin(),
        _override = platformOverride;

  final DeviceInfoPlugin _plugin;
  final TargetPlatform? _override;

  @override
  Future<DesktopOsInfo> currentOs() async {
    final platform = _override ?? defaultTargetPlatform;
    try {
      switch (platform) {
        case TargetPlatform.linux:
          final info = await _plugin.linuxInfo;
          return DesktopOsInfo(
            platform: 'Linux',
            osName: 'linux',
            osVersion: info.versionId ?? info.version ?? info.prettyName,
            deviceModel: info.name,
            deviceManufacturer: null,
          );
        case TargetPlatform.windows:
          final info = await _plugin.windowsInfo;
          final display = info.displayVersion.isNotEmpty
              ? '${info.displayVersion} (${info.buildNumber})'
              : '${info.buildNumber}';
          return DesktopOsInfo(
            platform: 'Windows',
            osName: 'windows',
            osVersion: display,
            deviceModel: info.productName,
            deviceManufacturer: null,
          );
        case TargetPlatform.macOS:
          final info = await _plugin.macOsInfo;
          return DesktopOsInfo(
            platform: 'macOS',
            osName: 'macos',
            osVersion: info.osRelease,
            deviceModel: info.model,
            deviceManufacturer: 'Apple',
          );
        default:
          return _fallback(platform);
      }
    } catch (_) {
      return _fallback(platform);
    }
  }

  DesktopOsInfo _fallback(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.linux =>
        const DesktopOsInfo(platform: 'Linux', osName: 'linux'),
      TargetPlatform.windows =>
        const DesktopOsInfo(platform: 'Windows', osName: 'windows'),
      TargetPlatform.macOS =>
        const DesktopOsInfo(platform: 'macOS', osName: 'macos'),
      _ => const DesktopOsInfo(platform: 'Unknown', osName: 'unknown'),
    };
  }
}

/// Production app facts via `package_info_plus`. Lookup failure yields
/// absent values; the config `appVersion` still applies downstream.
class PackageInfoDesktopAppInfo implements DesktopAppInfoSource {
  @override
  Future<DesktopAppVersion> current() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return DesktopAppVersion(
        appVersion: info.version,
        versionName: info.version,
      );
    } catch (_) {
      return const DesktopAppVersion();
    }
  }
}

/// BCP-47 locale tag for the `language` field (e.g. `en-US`).
///
/// WHY a function and not inline: enrichment stays a pure function of its
/// arguments (testable), while this platform lookup lives at the call site.
///
/// No try/catch: `PlatformDispatcher.locale` always yields a locale in
/// practice (never throws), so a fallback arm would be uncoverable dead
/// code. Callers needing a default handle absence themselves.
String desktopLocaleTag() {
  return PlatformDispatcher.instance.locale.toLanguageTag();
}
