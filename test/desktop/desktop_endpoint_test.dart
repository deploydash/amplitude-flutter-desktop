import 'package:amplitude_flutter/constants.dart';
import 'package:amplitude_flutter/desktop/desktop_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deriveDesktopEndpoint', () {
    test('US non-batch endpoint by default', () {
      expect(
        deriveDesktopEndpoint(zone: ServerZone.us, useBatch: false),
        'https://api2.amplitude.com/2/httpapi',
      );
    });

    test('US batch endpoint when useBatch', () {
      expect(
        deriveDesktopEndpoint(zone: ServerZone.us, useBatch: true),
        'https://api2.amplitude.com/batch',
      );
    });

    test('EU endpoints for both modes', () {
      expect(
        deriveDesktopEndpoint(zone: ServerZone.eu, useBatch: false),
        'https://api.eu.amplitude.com/2/httpapi',
      );
      expect(
        deriveDesktopEndpoint(zone: ServerZone.eu, useBatch: true),
        'https://api.eu.amplitude.com/batch',
      );
    });

    test('custom serverUrl wins verbatim and ignores zone and batch', () {
      const custom = 'https://ingest.example.com/collect';
      expect(
        deriveDesktopEndpoint(
          serverUrl: custom,
          zone: ServerZone.eu,
          useBatch: true,
        ),
        custom,
      );
      expect(
        deriveDesktopEndpoint(
          serverUrl: custom,
          zone: ServerZone.us,
          useBatch: false,
        ),
        custom,
      );
    });

    test('empty serverUrl falls back to zone routing', () {
      expect(
        deriveDesktopEndpoint(
          serverUrl: '',
          zone: ServerZone.eu,
          useBatch: false,
        ),
        'https://api.eu.amplitude.com/2/httpapi',
      );
    });
  });

  group('isDefaultDesktopEndpoint', () {
    test('stock endpoints are default', () {
      expect(isDefaultDesktopEndpoint('https://api2.amplitude.com/2/httpapi'),
          isTrue);
      expect(
          isDefaultDesktopEndpoint('https://api2.amplitude.com/batch'), isTrue);
      expect(isDefaultDesktopEndpoint('https://api.eu.amplitude.com/2/httpapi'),
          isTrue);
      expect(isDefaultDesktopEndpoint('https://api.eu.amplitude.com/batch'),
          isTrue);
    });

    test('custom urls are not default', () {
      expect(isDefaultDesktopEndpoint('https://ingest.example.com/x'), isFalse);
    });
  });
}
