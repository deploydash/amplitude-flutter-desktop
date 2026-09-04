import 'package:amplitude_flutter/desktop/desktop_compression.dart';
import 'package:amplitude_flutter/desktop/desktop_http.dart';
import 'package:amplitude_flutter/desktop/desktop_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildDesktopPayload', () {
    test('exact payload without minIdLength has no options key', () {
      final payload = buildDesktopPayload(
        apiKey: 'key-1',
        events: [
          {'event_type': 'a'},
          {'event_type': 'b'},
        ],
        clientUploadTime: '2026-01-02T03:04:05.000Z',
      );
      expect(payload, {
        'api_key': 'key-1',
        'client_upload_time': '2026-01-02T03:04:05.000Z',
        'events': [
          {'event_type': 'a'},
          {'event_type': 'b'},
        ],
      });
    });

    test('options.min_id_length appears only when minIdLength is set', () {
      final payload = buildDesktopPayload(
        apiKey: 'key-1',
        events: const [],
        clientUploadTime: '2026-01-02T03:04:05.000Z',
        minIdLength: 8,
      );
      expect(payload['options'], {'min_id_length': 8});
    });
  });

  group('formatDesktopUploadTime', () {
    test('formats millis as UTC ISO-8601', () {
      expect(formatDesktopUploadTime(0), '1970-01-01T00:00:00.000Z');
    });
  });

  group('desktopHeaders', () {
    test('plain body sends charset content type and accept', () {
      expect(desktopHeaders(gzipped: false), {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
      });
    });

    test('gzipped body adds content encoding', () {
      final headers = desktopHeaders(gzipped: true);
      expect(headers['Content-Encoding'], 'gzip');
      expect(headers['Content-Type'], 'application/json; charset=utf-8');
    });
  });

  group('encodeDesktopBody', () {
    test('default endpoint gzips and round-trips byte-for-byte', () {
      const json = '{"api_key":"k","events":[{"event_type":"x"}]}';
      final encoded = encodeDesktopBody(
        json,
        'https://api2.amplitude.com/2/httpapi',
      );
      expect(encoded.gzipped, isTrue);
      expect(
        decodeDesktopBody(encoded.bytes, gzipped: encoded.gzipped),
        json,
      );
    });

    test('identity compressor sends plain text even on default endpoints', () {
      const json = '{"api_key":"k","events":[]}';
      final encoded = encodeDesktopBody(
        json,
        'https://api2.amplitude.com/2/httpapi',
        compressor: const IdentityDesktopCompressor(),
      );
      expect(encoded.gzipped, isFalse);
      expect(
        decodeDesktopBody(encoded.bytes,
            gzipped: false, compressor: const IdentityDesktopCompressor()),
        json,
      );
    });

    test('custom serverUrl is never gzipped', () {
      const json = '{"api_key":"k","events":[]}';
      final encoded =
          encodeDesktopBody(json, 'https://ingest.example.com/collect');
      expect(encoded.gzipped, isFalse);
      expect(decodeDesktopBody(encoded.bytes, gzipped: false), json);
    });

    test('custom compressor throwing anything falls back uncompressed', () {
      const json = '{"api_key":"k","events":[]}';
      final encoded = encodeDesktopBody(
        json,
        'https://api2.amplitude.com/2/httpapi',
        compressor: const _ThrowingCompressor(),
      );
      expect(encoded.gzipped, isFalse);
      expect(decodeDesktopBody(encoded.bytes, gzipped: false), json);
    });
  });

  group('stripDesktopNulls', () {
    test('coerces hostile key types instead of throwing', () {
      final out = stripDesktopNulls({
        1: 'one',
        'keep': 'yes',
        'drop': null,
      }) as Map<String, dynamic>;
      expect(out, {'1': 'one', 'keep': 'yes'});
    });
  });
}

class _ThrowingCompressor implements DesktopCompressor {
  const _ThrowingCompressor();

  @override
  bool get available => true;

  @override
  List<int> encode(List<int> raw) => throw StateError('boom');

  @override
  List<int> decode(List<int> encoded) => throw StateError('boom');
}
