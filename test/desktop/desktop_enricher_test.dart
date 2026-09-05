import 'package:amplitude_flutter/desktop/desktop_enricher.dart';
import 'package:amplitude_flutter/desktop/desktop_system_info.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSystemInfo implements DesktopSystemInfoSource {
  const FakeSystemInfo(this.info);
  final DesktopOsInfo info;

  @override
  Future<DesktopOsInfo> currentOs() async => info;
}

class FakeAppInfo implements DesktopAppInfoSource {
  const FakeAppInfo(this.version);
  final DesktopAppVersion version;

  @override
  Future<DesktopAppVersion> current() async => version;
}

const testOs = DesktopOsInfo(
  platform: 'Linux',
  osName: 'linux',
  osVersion: '24.04',
  deviceModel: 'Ubuntu',
  deviceManufacturer: null,
);
const testApp = DesktopAppVersion(
  appVersion: '1.2.3',
  versionName: '1.2.3',
);

Map<String, dynamic> enrich(
  Map<String, dynamic> event, {
  Map<String, bool> tracking = const {},
  bool coppa = false,
  String? configAppVersion,
  String? language = 'en-US',
}) {
  return enrichDesktopEvent(
    event: translateDesktopEvent(event),
    tracking: tracking,
    coppa: coppa,
    os: testOs,
    app: testApp,
    library: 'amplitude-flutter/4.7.1',
    identityUserId: 'user-1',
    identityDeviceId: 'device-1',
    configPartnerId: 'partner-1',
    configAppVersion: configAppVersion,
    language: language,
  );
}

void main() {
  group('translateDesktopEvent', () {
    test('strips attempts and extra, never throws on types', () {
      final out = translateDesktopEvent({
        'event_type': 'x',
        'attempts': 3,
        'extra': {'debug': true},
        'user_id': 42,
        'device_id': {'nope': true},
        'location_lat': 12,
        'location_lng': 'far',
      });
      expect(out.containsKey('attempts'), isFalse);
      expect(out.containsKey('extra'), isFalse);
      expect(out['user_id'], '42');
      expect(out.containsKey('device_id'), isFalse);
      expect(out['location_lat'], 12.0);
      expect(out.containsKey('location_lng'), isFalse);
    });

    test('rewrites camelCase ingestion metadata to snake_case', () {
      final out = translateDesktopEvent({
        'event_type': 'x',
        'ingestion_metadata': {
          'sourceName': 'ampli',
          'sourceVersion': '2.0',
        },
      });
      expect(out['ingestion_metadata'],
          {'source_name': 'ampli', 'source_version': '2.0'});
    });

    test('drops android ids silently even when explicitly set', () {
      final out = translateDesktopEvent({
        'event_type': 'x',
        'app_set_id': 'set-1',
        'android_id': 'android-1',
        'adid': 'ad-1',
      });
      expect(out.containsKey('app_set_id'), isFalse);
      expect(out.containsKey('android_id'), isFalse);
      expect(out['adid'], 'ad-1');
    });

    test('ingestion metadata without a source is dropped, not half-sent', () {
      final out = translateDesktopEvent({
        'event_type': 'x',
        'ingestion_metadata': {'unrelated': 'kept-out'},
      });
      expect(out.containsKey('ingestion_metadata'), isFalse);
    });

    test('plan keeps known keys and drops unknown or empty plans', () {
      final kept = translateDesktopEvent({
        'event_type': 'x',
        'plan': {'branch': 'b', 'junk': 1},
      });
      expect(kept['plan'], {'branch': 'b'});

      final dropped = translateDesktopEvent({
        'event_type': 'x',
        'plan': {'junk': 1},
      });
      expect(dropped.containsKey('plan'), isFalse);
    });
  });

  group('enrichDesktopEvent', () {
    test('fills ids, library, partner, and desktop context', () {
      final out = enrich({'event_type': 'x'});
      expect(out['user_id'], 'user-1');
      expect(out['device_id'], 'device-1');
      expect(out['library'], 'amplitude-flutter/4.7.1');
      expect(out['partner_id'], 'partner-1');
      expect(out['platform'], 'Linux');
      expect(out['os_name'], 'linux');
      expect(out['os_version'], '24.04');
      expect(out['device_model'], 'Ubuntu');
      expect(out['carrier'], 'Unknown');
      expect(out['app_version'], '1.2.3');
      expect(out['language'], 'en-US');
      // Absent SDK values leave the key absent rather than sending null.
      expect(out.containsKey('device_manufacturer'), isFalse);
      // Never set client-side.
      expect(out.containsKey('ip'), isFalse);
    });

    test('host values survive when the SDK has nothing to stamp', () {
      // Regression: stamp() used to delete host values when the flag was
      // on but the SDK value was null (e.g. device-info lookup failed).
      // Native leaves the host value; so do we.
      final out = enrichDesktopEvent(
        event: {'event_type': 'x', 'os_version': 'host-os'},
        tracking: const {},
        coppa: false,
        os: const DesktopOsInfo(platform: 'Linux', osName: 'linux'),
        app: testApp,
        library: 'amplitude-flutter/4.7.1',
        language: 'en-US',
      );
      expect(out['os_version'], 'host-os');
    });

    test('host-set ids and partner win over identity and config', () {
      final out = enrich({
        'event_type': 'x',
        'user_id': 'host-user',
        'device_id': 'host-device',
        'partner_id': 'host-partner',
      });
      expect(out['user_id'], 'host-user');
      expect(out['device_id'], 'host-device');
      expect(out['partner_id'], 'host-partner');
    });

    test('library always wins over host values', () {
      final out = enrich({'event_type': 'x', 'library': 'custom/1.0'});
      expect(out['library'], 'amplitude-flutter/4.7.1');
    });

    test('disabled flags let host context values survive', () {
      final out = enrich(
        {'event_type': 'x', 'os_version': 'host-os', 'platform': 'host-p'},
        tracking: const {'osVersion': false, 'platform': false},
      );
      expect(out['os_version'], 'host-os');
      expect(out['platform'], 'host-p');
    });

    test('config appVersion wins over package info', () {
      final out = enrich({'event_type': 'x'}, configAppVersion: '9.9.9');
      expect(out['app_version'], '9.9.9');
    });

    test('latLag flag gates explicit location (Dart key, native meaning)', () {
      final withLocation = {
        'event_type': 'x',
        'location_lat': 12.5,
        'location_lng': 3.5,
      };
      expect(enrich(withLocation)['location_lat'], 12.5);
      final gated = enrich(withLocation, tracking: const {'latLag': false});
      expect(gated.containsKey('location_lat'), isFalse);
      expect(gated.containsKey('location_lng'), isFalse);
    });

    test('coppa drops idfa, idfv, city, ip, and location', () {
      final out = enrich(
        {
          'event_type': 'x',
          'idfa': 'idfa-1',
          'idfv': 'idfv-1',
          'city': 'Springfield',
          'ip': '1.2.3.4',
          'location_lat': 12.5,
          'location_lng': 3.5,
        },
        coppa: true,
      );
      for (final key in [
        'idfa',
        'idfv',
        'city',
        'ip',
        'location_lat',
        'location_lng',
      ]) {
        expect(out.containsKey(key), isFalse, reason: key);
      }
    });

    test('idfv flag gates explicit idfv', () {
      expect(enrich({'event_type': 'x', 'idfv': 'v'})['idfv'], 'v');
      expect(
          enrich({'event_type': 'x', 'idfv': 'v'},
              tracking: const {'idfv': false}).containsKey('idfv'),
          isFalse);
    });

    test('adid flag gates explicit adid', () {
      expect(enrich({'event_type': 'x', 'adid': 'a'})['adid'], 'a');
      expect(
          enrich({'event_type': 'x', 'adid': 'a'},
              tracking: const {'adid': false}).containsKey('adid'),
          isFalse);
    });
  });

  group('desktopLibrary', () {
    test('matches the native library format', () {
      expect(desktopLibrary(), 'amplitude-flutter/4.7.1');
    });
  });
}
