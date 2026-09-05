// Executable 100% line-and-branch coverage gate for `lib/desktop/` (T-12).
//
// WHY executable instead of a CI badge: the desktop suite once reported
// 100% while missing protocol, lifecycle, and platform-real behavior, and
// nothing failed when coverage dropped. This gate runs the desktop tests
// with branch coverage, requires every instrumented line and branch hit,
// and censuses the source tree so a new file cannot slip in unmeasured.
// Exit code 0 means 100% lines and 100% branches; anything else is nonzero.
//
// Usage: `dart run tool/check_desktop_coverage.dart
// [--coverage-path=coverage/desktop-lcov.info]`
//
// The LCOV parser is pure (`evaluateDesktopCoverage`) and unit-tested in
// `test/desktop_coverage_gate_test.dart`: a gate that cannot fail is worse
// than no gate.
import 'dart:io';

import 'package:path/path.dart' as p;

/// Files that must exist in the coverage report's allowlist but never gain
/// executable records. A row without code is a protocol that will be
/// reimplemented; a row without a check rots — so the gate fails when an
/// exempt file disappears from the tree or unexpectedly starts appearing
/// in LCOV (meaning it grew real code and needs tests, not exemption).
const Map<String, String> desktopCoverageExemptions = {
  'lib/desktop/desktop_compress.dart':
      'export-only file: conditional export plus re-export, no statements',
  'lib/desktop/desktop_compress_stub.dart':
      'non-IO conditional stub: never compiled into the VM build',
  'lib/desktop/desktop_file_storage.dart':
      'export-only file: conditional export, no statements',
  'lib/desktop/desktop_file_storage_stub.dart':
      'non-IO conditional stub: never compiled into the VM build',
};

/// Outcome of one gate evaluation.
class DesktopCoverageResult {
  const DesktopCoverageResult({required this.ok, required this.report});

  /// True only when every instrumented desktop line and branch was hit.
  final bool ok;
  final String report;
}

class _FileCoverage {
  var linesFound = 0;
  var linesHit = 0;
  var branchesFound = 0;
  var branchesHit = 0;
  final missedLines = <int>[];
}

/// Normalizes an LCOV `SF:` path to `lib/desktop/<name>` with forward
/// slashes, so absolute, relative, and Windows spellings all match the
/// census. Falls back to treating the basename as a desktop file.
String desktopCoverageKey(String sfPath) {
  final forward = sfPath.replaceAll('\\', '/');
  const marker = 'lib/desktop/';
  final at = forward.lastIndexOf(marker);
  if (at >= 0) {
    return forward.substring(at);
  }
  return marker + p.basename(forward);
}

/// Pure gate evaluation: fails on any uncovered line/branch, on any
/// tracked file with no records (unless exempt), on stale exemptions, and
/// on empty reports (a vacuous 100%).
DesktopCoverageResult evaluateDesktopCoverage({
  required String lcovText,
  required Set<String> trackedDesktopFiles,
  required Map<String, String> exemptFiles,
}) {
  final byFile = <String, _FileCoverage>{};
  var currentKey = '';
  for (final rawLine in lcovText.split('\n')) {
    final line = rawLine.trim();
    if (line.startsWith('SF:')) {
      currentKey = desktopCoverageKey(line.substring(3).trim());
      byFile.putIfAbsent(currentKey, _FileCoverage.new);
    } else if (line.startsWith('DA:') && currentKey.isNotEmpty) {
      final parts = line.substring(3).split(',');
      if (parts.length >= 2) {
        final record = byFile[currentKey]!;
        record.linesFound += 1;
        final hits = int.tryParse(parts[1]) ?? 0;
        if (hits > 0) {
          record.linesHit += 1;
        } else {
          record.missedLines.add(int.tryParse(parts[0]) ?? -1);
        }
      }
    } else if (line.startsWith('BRDA:') && currentKey.isNotEmpty) {
      final parts = line.substring(5).split(',');
      if (parts.length >= 4) {
        final record = byFile[currentKey]!;
        record.branchesFound += 1;
        final taken = parts[3];
        if (taken != '-' && (int.tryParse(taken) ?? 0) > 0) {
          record.branchesHit += 1;
        }
      }
    }
  }

  final failures = <String>[];
  final details = <String>[];
  var totalLinesFound = 0;
  var totalLinesHit = 0;
  var totalBranchesFound = 0;
  var totalBranchesHit = 0;

  for (final file in trackedDesktopFiles.toList()..sort()) {
    final record = byFile[file];
    final exemptReason = exemptFiles[file];
    if (record == null) {
      if (exemptReason == null) {
        failures.add('$file: tracked but has no coverage records');
      } else {
        details.add('$file: exempt ($exemptReason)');
      }
      continue;
    }
    if (exemptReason != null) {
      failures.add(
        '$file: exempt but has coverage records — remove the exemption '
        'and cover its code instead',
      );
      continue;
    }
    totalLinesFound += record.linesFound;
    totalLinesHit += record.linesHit;
    totalBranchesFound += record.branchesFound;
    totalBranchesHit += record.branchesHit;
    final fileOk =
        record.linesHit == record.linesFound &&
        record.branchesHit == record.branchesFound;
    details.add(
      '$file: lines ${record.linesHit}/${record.linesFound}, '
      'branches ${record.branchesHit}/${record.branchesFound}',
    );
    if (!fileOk) {
      final missed = record.missedLines.take(5).join(', ');
      failures.add(
        '$file: uncovered lines ${record.linesHit}/${record.linesFound}, '
        'branches ${record.branchesHit}/${record.branchesFound}'
        '${missed.isEmpty ? '' : ' (e.g. line $missed)'}',
      );
    }
  }
  for (final exempt in exemptFiles.keys.toList()..sort()) {
    if (!trackedDesktopFiles.contains(exempt)) {
      failures.add('$exempt: exemption is stale (file no longer tracked)');
    }
  }
  if (totalLinesFound == 0 || totalBranchesFound == 0) {
    failures.add(
      'no desktop lines ($totalLinesFound) or branches '
      '($totalBranchesFound) discovered — refusing a vacuous pass',
    );
  }

  final buffer = StringBuffer()
    ..writeln(
      'desktop coverage: lines $totalLinesHit/$totalLinesFound, '
      'branches $totalBranchesHit/$totalBranchesFound',
    )
    ..writeln(details.join('\n'));
  if (failures.isNotEmpty) {
    buffer.writeln('FAILURES:');
    buffer.writeln(failures.join('\n'));
  }
  return DesktopCoverageResult(ok: failures.isEmpty, report: '$buffer');
}

/// Lists every tracked `lib/desktop/*.dart` file as `lib/desktop/<name>`.
Set<String> censusDesktopFiles() {
  return Directory('lib/desktop')
      .listSync()
      .whereType<File>()
      .map((file) => p.basename(file.path))
      .where((name) => name.endsWith('.dart'))
      .map((name) => 'lib/desktop/$name')
      .toSet();
}

Future<void> main(List<String> args) async {
  var coveragePath = 'coverage/desktop-lcov.info';
  for (final arg in args) {
    if (arg.startsWith('--coverage-path=')) {
      coveragePath = arg.substring('--coverage-path='.length);
    } else {
      stderr.writeln(
        'usage: dart run tool/check_desktop_coverage.dart '
        '[--coverage-path=<lcov.info>]',
      );
      exitCode = 2;
      return;
    }
  }

  final tracked = censusDesktopFiles();
  final outFile = File(coveragePath);
  await outFile.parent.create(recursive: true);

  final testRun = await Process.run('flutter', [
    'test',
    'test/desktop',
    '--branch-coverage',
    '--coverage-path',
    outFile.path,
  ], runInShell: true);
  final testLog = File('${outFile.parent.path}/desktop-test.log');
  await testLog.writeAsString(
    '--- stdout ---\n${testRun.stdout}\n--- stderr ---\n${testRun.stderr}\n',
  );
  if (testRun.exitCode != 0) {
    stdout.writeln(testRun.stdout);
    stderr.writeln(testRun.stderr);
    stderr.writeln(
      'desktop tests failed (exit ${testRun.exitCode}); refusing coverage. '
      'Full log: ${testLog.path}',
    );
    exitCode = 1;
    return;
  }

  final result = evaluateDesktopCoverage(
    lcovText: await outFile.readAsString(),
    trackedDesktopFiles: tracked,
    exemptFiles: desktopCoverageExemptions,
  );
  stdout.writeln(result.report);
  stdout.writeln('LCOV: ${outFile.path}; test log: ${testLog.path}');
  if (!result.ok) {
    exitCode = 1;
  }
}
