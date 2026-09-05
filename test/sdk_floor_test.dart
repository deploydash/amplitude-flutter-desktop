import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Package compatibility-floor guard (T-11).
//
// WHY a test instead of a comment: the advertised Dart/Flutter minimums
// once disagreed with the resolved dependencies, so consumers on the
// documented floor could not resolve the package. This pins pubspec,
// README, example, and CHANGELOG to the effective dependency floor and
// fails when they drift. Re-verify the hardcoded dependency floors below
// with `flutter pub outdated` whenever a direct dependency moves.
void main() {
  late String pubspec;
  late String readme;
  late String changelog;
  late String examplePubspec;

  setUpAll(() {
    pubspec = File('pubspec.yaml').readAsStringSync();
    readme = File('README.md').readAsStringSync();
    changelog = File('CHANGELOG.md').readAsStringSync();
    examplePubspec = File('example/pubspec.yaml').readAsStringSync();
  });

  /// Compares dotted versions numerically (`3.9.0` < `3.10.0`).
  int compareVersions(String a, String b) {
    final as = a.split('.').map(int.parse).toList();
    final bs = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (as[i] != bs[i]) {
        return as[i].compareTo(bs[i]);
      }
    }
    return 0;
  }

  group('SDK compatibility floor', () {
    test('pubspec declares the effective dependency floor', () {
      expect(pubspec, contains('sdk: ">=3.10.0 <4.0.0"'));
      expect(pubspec, contains('flutter: ">=3.38.1"'));
    });

    test('README agrees with pubspec and keeps no old floor', () {
      expect(readme, contains('>=3.10.0 <4.0.0'));
      expect(readme, contains('>=3.38.1'));
      expect(readme, isNot(contains('3.3.0')));
      expect(readme, isNot(contains('3.19.0')));
    });

    test('the example app resolves on the same floor', () {
      expect(examplePubspec, contains('3.10.0'));
      expect(examplePubspec, isNot(contains('3.3.0')));
    });

    test('CHANGELOG states the raised Linux/Windows floor', () {
      final unreleased =
          changelog.substring(0, changelog.indexOf('## [4.7.1]'));
      expect(unreleased, contains('3.38.1'));
    });

    test('declared floor covers every direct dependency floor', () {
      const sdkFloor = '3.10.0';
      const flutterFloor = '3.38.1';
      // Resolved-version floors, verified in the pub cache; re-check on
      // every `flutter pub outdated` dependency move.
      const dependencyFloors = <String, (String, String?)>{
        'device_info_plus 13.2.0': ('3.10.0', '3.38.1'),
        'package_info_plus 10.2.1': ('3.10.0', '3.38.1'),
        'shared_preferences 2.5.5': ('3.9.0', '3.35.0'),
        'path 1.9.1': ('3.4.0', null),
        'path_provider 2.1.6': ('3.10.0', '3.38.0'),
      };
      for (final entry in dependencyFloors.entries) {
        expect(
          compareVersions(sdkFloor, entry.value.$1),
          greaterThanOrEqualTo(0),
          reason: '${entry.key} needs Dart ${entry.value.$1}',
        );
        final flutterNeed = entry.value.$2;
        if (flutterNeed != null) {
          expect(
            compareVersions(flutterFloor, flutterNeed),
            greaterThanOrEqualTo(0),
            reason: '${entry.key} needs Flutter $flutterNeed',
          );
        }
      }
    });
  });
}
