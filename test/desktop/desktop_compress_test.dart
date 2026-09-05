import 'dart:collection';

import 'package:amplitude_flutter/desktop/desktop_compress.dart';
import 'package:flutter_test/flutter_test.dart';

// A List whose every access throws: proves the gzip wrapper converts ANY
// codec/hostile-input failure into DesktopCompressError (plan §A.4: gzip
// failure sends uncompressed, never drops, never throws).
class _ThrowingList extends ListBase<int> {
  @override
  int get length => throw StateError('hostile length');
  @override
  set length(int value) => throw StateError('hostile length=');
  @override
  int operator [](int index) => throw StateError('hostile read');
  @override
  void operator []=(int index, int value) => throw StateError('hostile write');
}

void main() {
  group('IdentityDesktopCompressor', () {
    test('reports unavailable and passes bytes through untouched', () {
      const compressor = IdentityDesktopCompressor();
      expect(compressor.available, isFalse);
      const raw = [1, 2, 3];
      expect(compressor.encode(raw), same(raw));
      expect(compressor.decode(raw), same(raw));
    });
  });

  group('defaultDesktopCompressor', () {
    test('round-trips bytes', () {
      const raw = [72, 101, 108, 108, 111];
      expect(
          defaultDesktopCompressor.decode(defaultDesktopCompressor.encode(raw)),
          raw);
    });

    test('encode failure surfaces as DesktopCompressError, never raw', () {
      expect(
        () => defaultDesktopCompressor.encode(_ThrowingList()),
        throwsA(isA<DesktopCompressError>()),
      );
    });

    test('decode failure surfaces as DesktopCompressError, never raw', () {
      expect(
        () => defaultDesktopCompressor.decode([1, 2, 3]),
        throwsA(isA<DesktopCompressError>()),
      );
    });
  });

  group('DesktopCompressError', () {
    test('message round-trips through toString', () {
      expect(
        const DesktopCompressError('boom').toString(),
        'DesktopCompressError: boom',
      );
    });
  });
}
