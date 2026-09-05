import 'package:flutter_test/flutter_test.dart';

import '../tool/check_desktop_coverage.dart' as gate;

// Unit tests for the coverage gate parser (T-12).
//
// WHY test the gate: an unenforced or vacuous gate is worse than none —
// it prints 100% while guarding nothing. These fixtures prove the parser
// fails on every way out: a missed line, a missed branch, a file with no
// records at all, a stale exemption, and an empty report.

const _goodLcov = '''
SF:lib/desktop/a.dart
DA:1,1
DA:2,3
BRDA:1,0,0,1
BRDA:1,0,1,2
end_of_record
SF:lib/desktop/b.dart
DA:1,1
BRDA:1,0,0,1
end_of_record
''';

const _missedLine = '''
SF:lib/desktop/a.dart
DA:1,1
DA:2,0
BRDA:1,0,0,1
end_of_record
''';

const _missedBranch = '''
SF:lib/desktop/a.dart
DA:1,1
BRDA:1,0,0,-
end_of_record
''';

void main() {
  const tracked = {'lib/desktop/a.dart', 'lib/desktop/b.dart'};

  group('evaluateDesktopCoverage', () {
    test('a fully covered tree passes', () {
      final result = gate.evaluateDesktopCoverage(
        lcovText: _goodLcov,
        trackedDesktopFiles: tracked,
        exemptFiles: const {},
      );
      expect(result.ok, isTrue);
      expect(result.report, contains('2/2'));
    });

    test('a missed line fails and names the file', () {
      final result = gate.evaluateDesktopCoverage(
        lcovText: _missedLine,
        trackedDesktopFiles: {'lib/desktop/a.dart'},
        exemptFiles: const {},
      );
      expect(result.ok, isFalse);
      expect(result.report, contains('lib/desktop/a.dart'));
    });

    test('a missed branch fails', () {
      final result = gate.evaluateDesktopCoverage(
        lcovText: _missedBranch,
        trackedDesktopFiles: {'lib/desktop/a.dart'},
        exemptFiles: const {},
      );
      expect(result.ok, isFalse);
    });

    test('a tracked file with no records fails unless exempt', () {
      final missing = gate.evaluateDesktopCoverage(
        lcovText: _goodLcov,
        trackedDesktopFiles: {'lib/desktop/a.dart', 'lib/desktop/gone.dart'},
        exemptFiles: const {},
      );
      expect(missing.ok, isFalse);
      expect(missing.report, contains('gone.dart'));

      final exempted = gate.evaluateDesktopCoverage(
        lcovText: _goodLcov,
        trackedDesktopFiles: {'lib/desktop/a.dart', 'lib/desktop/gone.dart'},
        exemptFiles: const {'lib/desktop/gone.dart': 'export-only'},
      );
      expect(exempted.ok, isTrue);
    });

    test('an exempt file with records fails the allowlist', () {
      final result = gate.evaluateDesktopCoverage(
        lcovText: _goodLcov,
        trackedDesktopFiles: tracked,
        exemptFiles: const {'lib/desktop/a.dart': 'stale reason'},
      );
      expect(result.ok, isFalse);
    });

    test('an exemption for an untracked file fails as stale', () {
      final result = gate.evaluateDesktopCoverage(
        lcovText: _goodLcov,
        trackedDesktopFiles: tracked,
        exemptFiles: const {'lib/desktop/deleted.dart': 'stale reason'},
      );
      expect(result.ok, isFalse);
    });

    test('an empty report fails instead of passing vacuously', () {
      final result = gate.evaluateDesktopCoverage(
        lcovText: '',
        trackedDesktopFiles: tracked,
        exemptFiles: const {},
      );
      expect(result.ok, isFalse);
    });
  });
}
