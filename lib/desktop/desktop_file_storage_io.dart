import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_constants.dart';
import 'desktop_storage.dart';

// Crash-recoverable filesystem event queue (round 1: basic operations).
//
// WHY files instead of preferences: an acknowledged event must survive a
// kill -9 between the backend's `await storage.appendEvent` returning and
// the next upload. One JSON preferences file rewriting every queue entry on
// every append cannot promise that; separate files with same-directory
// atomic renames can.
//
// Layout under `<app-support>/<safe-namespace>/`:
//   `v2-<n>.tmp`   open (appendable) queue file for index `<n>`.
//   `v2-<n>`       sealed (uploadable) queue file.
//   `kv/<key>`     scalar identity/session values (atomic small files).
//   `.quarantine/` renamed-aside corrupt files (never uploaded).
//
// The raw API key never appears in a path: the namespace directory name is
// the base64url encoding of the full `storage-<apiKey>-<instanceName>`
// namespace (crash recovery in `init`, collision-safe sealing, and byte
// measurement arrive in later rounds).
class FileDesktopStorage implements DesktopStorage {
  FileDesktopStorage({
    required String namespace,
    Directory? directory,
    int Function()? clock,
  })  : _namespace = namespace,
        _parentOverride = directory,
        _nowMs = clock ?? _wallClock {
    // An empty namespace would resolve to the parent directory itself, so
    // `clearAll` could delete sibling namespaces: refuse it up front.
    if (namespace.isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'must not be empty');
    }
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final String _namespace;
  final Directory? _parentOverride;
  final int Function() _nowMs;

  late Directory _dir;
  int _nextIndex = 0;
  bool _initialized = false;

  /// Open queue files look exactly like `v2-<digits>.tmp`. Transaction
  /// sidecars (`*.rw.tmp`, `*.sp.tmp`) never match, so recovery can tell an
  /// abandoned append from staged transaction bytes.
  static final RegExp _openPattern = RegExp(r'^v2-\d+\.tmp$');

  /// Resolved namespace directory. Visible for tests (fault seeding) and
  /// for hosts diagnosing the on-disk queue.
  @visibleForTesting
  Directory get directoryForTests {
    _requireInit();
    return _dir;
  }

  /// Directory name for the namespace. Base64url uses only
  /// `A-Za-z0-9-_`, so the raw API key can never escape into a path.
  String get _safeName =>
      base64Url.encode(utf8.encode(_namespace)).replaceAll('=', '');

  void _requireInit() {
    assert(_initialized, 'DesktopStorage.init() must be awaited first');
  }

  /// Rejects names that could escape the queue directory.
  void _checkName(String name) {
    if (RegExp(r'[/\\:]').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'must stay inside the queue');
    }
  }

  File _file(String name) => File(p.join(_dir.path, name));

  @override
  Future<void> init() async {
    final parent = _parentOverride ?? await getApplicationSupportDirectory();
    _dir = Directory(p.join(parent.path, _safeName));
    await _dir.create(recursive: true);
    await _recoverRewriteTransactions();
    await _recoverSplitTransactions();
    await _recoverOpenFiles();
    _nextIndex = await _scanNextIndex();
    _initialized = true;
  }

  /// Resolves interrupted survivor rewrites (`writeFile`). The marker
  /// `<sealed>.rw.txn` (empty: existence is the signal) brackets a
  /// Windows-safe replace that never assumes rename-over-existing:
  /// stage `<sealed>.rw.tmp`, move the original to `<sealed>.bak`, rename
  /// the stage into place, then remove backup and marker. Restart keeps one
  /// complete copy: the untouched original when the rewrite never landed,
  /// the landed rewrite otherwise — never a truncated mixture.
  Future<void> _recoverRewriteTransactions() async {
    await for (final entity in _dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (!name.endsWith('.rw.txn')) {
        continue;
      }
      final sealedName = name.substring(0, name.length - '.rw.txn'.length);
      final target = File(p.join(_dir.path, sealedName));
      final staged = File(p.join(_dir.path, '$sealedName.rw.tmp'));
      final backup = File(p.join(_dir.path, '$sealedName.bak'));
      if (!await target.exists() && await backup.exists()) {
        // The original was moved aside but the stage never landed.
        await backup.rename(target.path);
      }
      if (await staged.exists()) {
        await staged.delete();
      }
      if (await target.exists() && await backup.exists()) {
        await backup.delete();
      }
      await entity.delete();
    }
  }

  /// Resolves interrupted 413 splits (`splitFile`). The marker
  /// `<source>.sp.txn` (empty: existence is the signal) brackets child
  /// staging, landing, and moving the source aside:
  /// stage `<child>.sp.tmp` files, rename them to `<source>-1`/`-2`, move
  /// the source to `<source>.bak`, then remove backup and marker. Restart
  /// either rolls back to the untouched source (the move never happened) or
  /// completes the committed children — never both at once.
  Future<void> _recoverSplitTransactions() async {
    await for (final entity in _dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (!name.endsWith('.sp.txn')) {
        continue;
      }
      final source = name.substring(0, name.length - '.sp.txn'.length);
      final children = [
        DesktopQueueFiles.splitName(source, 1),
        DesktopQueueFiles.splitName(source, 2),
      ];
      final sourceFile = File(p.join(_dir.path, source));
      final backup = File(p.join(_dir.path, '$source.bak'));
      if (await sourceFile.exists()) {
        // The source never moved aside: drop staged and landed children.
        for (final child in children) {
          final staged = File(p.join(_dir.path, '$child.sp.tmp'));
          if (await staged.exists()) {
            await staged.delete();
          }
          final landed = File(p.join(_dir.path, child));
          if (await landed.exists()) {
            await landed.delete();
          }
        }
      } else {
        var landed = 0;
        for (final child in children) {
          if (await File(p.join(_dir.path, child)).exists()) {
            landed += 1;
          }
        }
        if (landed == 2) {
          // Both halves committed: drop the backup and marker.
          if (await backup.exists()) {
            await backup.delete();
          }
        } else if (await backup.exists()) {
          // The backup survived: restore the untouched source and drop
          // every partial child.
          await backup.rename(sourceFile.path);
          for (final child in children) {
            final staged = File(p.join(_dir.path, '$child.sp.tmp'));
            if (await staged.exists()) {
              await staged.delete();
            }
            final landedFile = File(p.join(_dir.path, child));
            if (await landedFile.exists()) {
              await landedFile.delete();
            }
          }
        } else {
          // No source to restore: drop scratch temps, keep landed finals.
          for (final child in children) {
            final staged = File(p.join(_dir.path, '$child.sp.tmp'));
            if (await staged.exists()) {
              await staged.delete();
            }
          }
        }
      }
      await entity.delete();
    }
  }

  /// delimiter-terminated record is sealed for upload, an incomplete final
  /// tail is discarded (only whole records ever upload), and an empty
  /// abandoned file is removed. Ages are preserved so recovery never resets
  /// the 30-day clock.
  Future<void> _recoverOpenFiles() async {
    await for (final entity in _dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (!_openPattern.hasMatch(name)) {
        continue;
      }
      final content = await entity.readAsString();
      final age = await entity.lastModified();
      var lines = splitDesktopFileContent(content);
      if (lines.isNotEmpty && !content.endsWith(DesktopQueueFiles.delimiter)) {
        // The final record was cut mid-write: keep only whole records.
        lines = lines.sublist(0, lines.length - 1);
      }
      if (lines.isEmpty) {
        await entity.delete();
        continue;
      }
      final sealed = File(p.join(
          _dir.path, await _sealedCollisionFree(desktopFileSortIndex(name))));
      if (content.endsWith(DesktopQueueFiles.delimiter)) {
        // Untouched rename: atomic and preserves the age.
        await entity.rename(sealed.path);
      } else {
        await sealed.writeAsString(
            joinDesktopFileContent(lines) + DesktopQueueFiles.delimiter,
            flush: true);
        await sealed.setLastModified(age);
        await entity.delete();
      }
    }
  }

  /// First free path for [base] inside [dirPath]: the base itself, else
  /// `base-1`, `base-2`, ... Never overwrites: a killed process may leave a
  /// previous attempt behind, and evidence must survive retries.
  Future<String> _firstFreePath(String dirPath, String base) async {
    var candidate = p.join(dirPath, base);
    var suffix = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dirPath, '$base-$suffix');
      suffix += 1;
    }
    return candidate;
  }

  /// First free sealed name for [index]: `v2-<n>`, else `v2-<n>-1`,
  /// `v2-<n>-2`, ... Suffixes sort after the bare name
  /// (`desktopFileSortIndex` reads the leading digits), so the colliding
  /// content still uploads oldest-first right behind its namesake.
  Future<String> _sealedCollisionFree(int index) async {
    final full =
        await _firstFreePath(_dir.path, DesktopQueueFiles.sealedName(index));
    return p.basename(full);
  }

  /// Derives the next sequence number by scanning the directory, so a
  /// crashed process never reuses an index (no persisted counter to lose).
  Future<int> _scanNextIndex() async {
    var max = -1;
    await for (final entity in _dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (!name.startsWith('v2-')) {
        continue;
      }
      final index = desktopFileSortIndex(name);
      if (index < (1 << 62) && index > max) {
        max = index;
      }
    }
    return max + 1;
  }

  @override
  Future<String?> readString(String key) async {
    _requireInit();
    final file = File(p.join(_dir.path, 'kv', key));
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
  }

  @override
  Future<void> writeString(String key, String value) async {
    _requireInit();
    final target = File(p.join(_dir.path, 'kv', key));
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(target.path);
  }

  @override
  Future<int?> readInt(String key) async {
    final raw = await readString(key);
    return raw == null ? null : int.tryParse(raw);
  }

  @override
  Future<void> writeInt(String key, int value) async {
    await writeString(key, value.toString());
  }

  @override
  Future<bool?> readBool(String key) async {
    final raw = await readString(key);
    if (raw == null) {
      return null;
    }
    if (raw == 'true') {
      return true;
    }
    if (raw == 'false') {
      return false;
    }
    return null;
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    await writeString(key, value.toString());
  }

  @override
  Future<void> deleteKey(String key) async {
    _requireInit();
    final file = File(p.join(_dir.path, 'kv', key));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Uploadable queue files are exactly `v2-<n>` and `v2-<n>-<k>`
  /// (sealed files, split halves, collision siblings). Transaction sidecars
  /// (`*.tmp`, `*.txn`, `*.bak`) and unrelated files never upload.
  static final RegExp _queuePattern = RegExp(r'^v2-\d+(-\d+)?$');

  bool _isUploadable(String name) => _queuePattern.hasMatch(name);

  @override
  Future<void> appendEvent(String jsonLine) async {
    _requireInit();
    final bytes = utf8.encode('$jsonLine${DesktopQueueFiles.delimiter}');
    var open = File(p.join(_dir.path, DesktopQueueFiles.openName(_nextIndex)));
    if (await open.exists() && await open.length() > 0) {
      final size = await open.length();
      if (size + bytes.length > DesktopQueueFiles.maxFileSizeBytes) {
        await sealCurrentFile();
        // Sealing advanced the index: re-resolve the open file instead of
        // appending into the just-sealed one.
        open = File(p.join(_dir.path, DesktopQueueFiles.openName(_nextIndex)));
      }
    }
    final sink = await open.open(mode: FileMode.append);
    try {
      sink.writeFromSync(bytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await open.length() >= DesktopQueueFiles.maxFileSizeBytes) {
      await sealCurrentFile();
    }
  }

  @override
  Future<String?> sealCurrentFile() async {
    _requireInit();
    final open =
        File(p.join(_dir.path, DesktopQueueFiles.openName(_nextIndex)));
    if (!await open.exists()) {
      return null;
    }
    final content = await open.readAsString();
    if (splitDesktopFileContent(content).isEmpty) {
      await open.delete();
      return null;
    }
    final sealed = await _sealedCollisionFree(_nextIndex);
    await open.rename(p.join(_dir.path, sealed));
    _nextIndex += 1;
    return sealed;
  }

  @override
  Future<List<String>> listFilesOldestFirst() async {
    _requireInit();
    if (!await _dir.exists()) {
      return [];
    }
    final names = <String>[];
    await for (final entity in _dir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (_isUploadable(name)) {
        names.add(name);
      }
    }
    names.sort((a, b) {
      final order = desktopFileSortIndex(a).compareTo(desktopFileSortIndex(b));
      return order != 0 ? order : a.compareTo(b);
    });
    return names;
  }

  @override
  Future<String?> readFile(String name) async {
    _requireInit();
    _checkName(name);
    final file = _file(name);
    if (!await file.exists()) {
      return null;
    }
    final content = await file.readAsString();
    // The physical append format ends each record with one delimiter; the
    // logical content hides that final delimiter (callers split into lines).
    if (content.endsWith(DesktopQueueFiles.delimiter)) {
      return content.substring(
          0, content.length - DesktopQueueFiles.delimiter.length);
    }
    return content;
  }

  @override
  Future<int?> fileCreatedAt(String name) async {
    _requireInit();
    _checkName(name);
    final file = _file(name);
    if (!await file.exists()) {
      return null;
    }
    return (await file.lastModified()).millisecondsSinceEpoch;
  }

  @override
  Future<void> writeFile(String name, String content,
      {int? createdAtMs}) async {
    _requireInit();
    _checkName(name);
    // Same-directory transactional replace (Windows has no atomic
    // rename-over-existing): stage, bracket with a marker, move the
    // original aside, land the stage, then clean up. Any crash between
    // these steps restarts into exactly one complete copy (see recovery).
    final target = _file(name);
    final staged = File('${target.path}.rw.tmp');
    final marker = File('${target.path}.rw.txn');
    final backup = File('${target.path}.bak');
    final age = createdAtMs ??
        (await target.exists()
            ? (await target.lastModified()).millisecondsSinceEpoch
            : _nowMs());
    await staged.writeAsString(content, flush: true);
    await staged.setLastModified(DateTime.fromMillisecondsSinceEpoch(age));
    await marker.writeAsString('', flush: true);
    if (await target.exists()) {
      await target.rename(backup.path);
    }
    await staged.rename(target.path);
    if (await backup.exists()) {
      await backup.delete();
    }
    await marker.delete();
  }

  @override
  Future<void> removeFile(String name) async {
    _requireInit();
    _checkName(name);
    final file = _file(name);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<List<String>> splitFile(String name) async {
    _requireInit();
    _checkName(name);
    final file = _file(name);
    if (!await file.exists()) {
      return [name];
    }
    final lines = splitDesktopFileContent(await file.readAsString());
    if (lines.length < 2) {
      return [name];
    }
    // Same-directory transactional split (see recovery): bracket with a
    // marker, stage and land both halves, move the source aside, then
    // clean up. Any crash restarts into the untouched source or the
    // committed children — never both.
    final age = (await file.lastModified()).millisecondsSinceEpoch;
    final half = lines.length ~/ 2;
    final first = DesktopQueueFiles.splitName(name, 1);
    final second = DesktopQueueFiles.splitName(name, 2);
    final marker = File(p.join(_dir.path, '$name.sp.txn'));
    final backup = File(p.join(_dir.path, '$name.bak'));
    final firstTmp = File(p.join(_dir.path, '$first.sp.tmp'));
    final secondTmp = File(p.join(_dir.path, '$second.sp.tmp'));
    await marker.writeAsString('', flush: true);
    await firstTmp.writeAsString(joinDesktopFileContent(lines.sublist(0, half)),
        flush: true);
    await firstTmp.setLastModified(DateTime.fromMillisecondsSinceEpoch(age));
    await secondTmp.writeAsString(joinDesktopFileContent(lines.sublist(half)),
        flush: true);
    await secondTmp.setLastModified(DateTime.fromMillisecondsSinceEpoch(age));
    await firstTmp.rename(p.join(_dir.path, first));
    await secondTmp.rename(p.join(_dir.path, second));
    await file.rename(backup.path);
    await backup.delete();
    await marker.delete();
    return [first, second];
  }

  @override
  Future<void> quarantineFile(String name) async {
    _requireInit();
    _checkName(name);
    final file = _file(name);
    if (!await file.exists()) {
      return;
    }
    final dir = Directory(p.join(_dir.path, '.quarantine'));
    await dir.create(recursive: true);
    // Collision-safe: earlier evidence under the same name is never
    // overwritten (a killed process may quarantine the same name twice).
    await file.rename(await _firstFreePath(dir.path, name));
  }

  /// Stores diagnostic [bytes] under [name] in the quarantine directory
  /// without ever overwriting earlier evidence.
  Future<void> _quarantineBytes(String name, List<int> bytes) async {
    final dir = Directory(p.join(_dir.path, '.quarantine'));
    await dir.create(recursive: true);
    final dest = await _firstFreePath(dir.path, p.basename(name));
    await File(dest).writeAsBytes(bytes, flush: true);
  }

  /// Imports a legacy `shared_preferences` event queue (written by
  /// `SharedPreferencesDesktopStorage` for existing fork installations)
  /// into this filesystem queue. Idempotent: rerunning after a crash
  /// verifies and reuses an already-committed destination instead of
  /// duplicating events, and only then removes the legacy key.
  ///
  /// WHY a method here instead of in the backend: the frozen legacy key
  /// layout (`<namespace>/file/<name>`, `<namespace>/.quarantine/<name>`)
  /// and the filesystem commit/verify steps both live with the code that
  /// owns the destination format. Undecodable envelopes are preserved as
  /// quarantined bytes for diagnosis — never silently deleted.
  Future<void> importLegacyPreferenceQueue(SharedPreferences prefs) async {
    _requireInit();
    final filePrefix = '$_namespace/file/';
    final names = prefs
        .getKeys()
        .where((key) => key.startsWith(filePrefix))
        .map((key) => key.substring(filePrefix.length))
        .toList()
      ..sort();
    for (final name in names) {
      final key = '$filePrefix$name';
      // `get` (not `getString`): a foreign-typed value under our prefix
      // must be skipped, and `getString` throws on it instead of null.
      final raw = prefs.get(key);
      if (raw is! String) {
        continue;
      }
      String? content;
      int? createdAt;
      try {
        final envelope = json.decode(raw) as Map<String, dynamic>;
        final body = envelope['content'];
        final stamped = envelope['createdAt'];
        if (body is String) {
          content = body;
        }
        if (stamped is num) {
          createdAt = stamped.toInt();
        }
      } catch (_) {
        // Falls through to the quarantine path below.
      }
      final logical = name.endsWith('.tmp')
          ? name.substring(0, name.length - '.tmp'.length)
          : name;
      if (content == null || createdAt == null || !_isUploadable(logical)) {
        await _quarantineBytes(name, utf8.encode(raw));
        await prefs.remove(key);
        continue;
      }
      if (content.isEmpty) {
        await prefs.remove(key);
        continue;
      }
      if (await readFile(logical) == content) {
        // A previous run committed the destination but died before
        // removing the source: reuse it instead of duplicating.
        await prefs.remove(key);
        continue;
      }
      final dest = p.basename(await _firstFreePath(_dir.path, logical));
      final file = File(p.join(_dir.path, dest));
      await file.writeAsBytes(
          utf8.encode('$content${DesktopQueueFiles.delimiter}'),
          flush: true);
      await file
          .setLastModified(DateTime.fromMillisecondsSinceEpoch(createdAt));
      if (await readFile(dest) != content) {
        throw StateError('legacy migration verification failed for $name');
      }
      await prefs.remove(key);
    }
    for (final quarantinePrefix in [
      '$_namespace/.quarantine/',
      '$_namespace/quarantine/',
    ]) {
      final quarantined = prefs
          .getKeys()
          .where((key) => key.startsWith(quarantinePrefix))
          .map((key) => key.substring(quarantinePrefix.length))
          .toList()
        ..sort();
      for (final name in quarantined) {
        final key = '$quarantinePrefix$name';
        final raw = prefs.get(key);
        if (raw is! String) {
          continue;
        }
        await _quarantineBytes(name, utf8.encode(raw));
        await prefs.remove(key);
      }
    }
  }

  @override
  Future<void> clearAll() async {
    _requireInit();
    if (await _dir.exists()) {
      await _dir.delete(recursive: true);
    }
  }
}
