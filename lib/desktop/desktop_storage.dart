import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_constants.dart';

// Persisted scalar keys (plan §B.4). Identity, session bookkeeping, and the
// queue index all live behind these names so every [DesktopStorage]
// implementation restores the same state.
class DesktopStoreKeys {
  static const deviceId = 'deviceId';
  static const userId = 'userId';
  // Legacy migration only: opt-out is config-owned and never persisted in
  // normal operation. `DesktopIdentity.load` deletes any value left by older
  // builds so a regression cannot read it.
  static const optOut = 'optOut';
  static const lastEventId = 'lastEventId';
  static const sessionId = 'sessionId';
  static const lastEventTime = 'lastEventTime';
  static const storedApiKey = 'storedApiKey';
  static const fileIndex = 'fileIndex';

  /// Persisted held `$identify` for identify batching (plan §F).
  static const heldIdentify = 'heldIdentify';
  static const heldIdentifyUserId = 'heldIdentifyUserId';
  static const heldIdentifyDeviceId = 'heldIdentifyDeviceId';
}

// Injectable queue + identity store (plan §B.1).
//
// WHY this exact shape: it copies Aptabase's `StorageManager` seam
// (init/get/add/delete, `shared_preferences` default, host-injectable
// override) extended with the file operations the Amplitude §A.5 dispatch
// needs (split on 413, quarantine on corruption). The SDK owns the
// lifecycle; the host owns the location by injecting an implementation.
// Single-writer: all operations go through the backend's async mutex — no
// isolates in v1.
abstract class DesktopStorage {
  /// Prepares the store (loads caches, creates directories, ...).
  Future<void> init();

  Future<String?> readString(String key);
  Future<void> writeString(String key, String value);
  Future<int?> readInt(String key);
  Future<void> writeInt(String key, int value);
  Future<bool?> readBool(String key);
  Future<void> writeBool(String key, bool value);
  Future<void> deleteKey(String key);

  /// Appends one JSON-encoded event to the open file, sealing early past
  /// 975,000 bytes (plan §B.2).
  Future<void> appendEvent(String jsonLine);

  /// Seals the open file for upload. Returns the sealed name, or null when
  /// the open file is empty.
  Future<String?> sealCurrentFile();

  /// Sealed file names, oldest first.
  Future<List<String>> listFilesOldestFirst();

  /// Raw content of a sealed file (events joined by the queue delimiter).
  Future<String?> readFile(String name);

  /// Creation time of a sealed file in millis since epoch, or null when the
  /// file does not exist. Drives the 30-day discard backstop.
  Future<int?> fileCreatedAt(String name);

  /// Overwrites a sealed file (used to requeue survivors of a partial 400).
  /// A null [createdAtMs] preserves the file's original creation time.
  Future<void> writeFile(String name, String content, {int? createdAtMs});

  Future<void> removeFile(String name);

  /// Splits a multi-event file into `<name>-1` / `<name>-2` (413 handling).
  /// Returns the new names, oldest half first.
  Future<List<String>> splitFile(String name);

  /// Moves an unreadable file to the hidden quarantine dir so one corrupt
  /// file can never wedge the queue (plan §B.3).
  Future<void> quarantineFile(String name);

  /// Removes everything (scalars, files, quarantine) for this namespace.
  Future<void> clearAll();
}

/// Splits stored file content into its event lines.
List<String> splitDesktopFileContent(String content) {
  return content
      .split(DesktopQueueFiles.delimiter)
      .where((line) => line.isNotEmpty)
      .toList();
}

/// Joins event lines into stored file content.
String joinDesktopFileContent(List<String> lines) {
  return lines.join(DesktopQueueFiles.delimiter);
}

/// Leading numeric index of a sealed file name (`v2-12` → 12,
/// `v2-12-1` → 12 for split halves). Unparseable names sort last.
int desktopFileSortIndex(String name) {
  final withoutPrefix = name.startsWith('v2-') ? name.substring(3) : name;
  final leading = RegExp(r'^\d+').firstMatch(withoutPrefix)?.group(0);
  // Huge digit strings overflow `int.parse` — fall back to sorting last.
  return leading == null ? 1 << 62 : int.tryParse(leading) ?? (1 << 62);
}

/// In-memory [DesktopStorage]. The default for tests and the reference for
/// the persisted implementation's semantics.
class InMemoryDesktopStorage implements DesktopStorage {
  InMemoryDesktopStorage({int Function()? clock})
      : _nowMs = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final int Function() _nowMs;
  final Map<String, Object?> _scalars = {};
  final Map<String, _StoredFile> _files = {};
  final Map<String, _StoredFile> _quarantine = {};
  bool _initialized = false;

  @override
  Future<void> init() async {
    _initialized = true;
  }

  void _requireInit() {
    assert(_initialized, 'DesktopStorage.init() must be awaited first');
  }

  String _openName() {
    final index = _scalars[DesktopStoreKeys.fileIndex] as int? ?? 0;
    return DesktopQueueFiles.openName(index);
  }

  @override
  Future<String?> readString(String key) async {
    _requireInit();
    return _scalars[key] as String?;
  }

  @override
  Future<void> writeString(String key, String value) async {
    _requireInit();
    _scalars[key] = value;
  }

  @override
  Future<int?> readInt(String key) async {
    _requireInit();
    return _scalars[key] as int?;
  }

  @override
  Future<void> writeInt(String key, int value) async {
    _requireInit();
    _scalars[key] = value;
  }

  @override
  Future<bool?> readBool(String key) async {
    _requireInit();
    return _scalars[key] as bool?;
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    _requireInit();
    _scalars[key] = value;
  }

  @override
  Future<void> deleteKey(String key) async {
    _requireInit();
    _scalars.remove(key);
  }

  @override
  Future<void> appendEvent(String jsonLine) async {
    _requireInit();
    final name = _openName();
    final existing = _files[name];
    final lines = existing == null
        ? <String>[]
        : splitDesktopFileContent(existing.content);
    lines.add(jsonLine);
    final createdAt = existing?.createdAtMs ?? _nowMs();
    _files[name] = _StoredFile(
      createdAtMs: createdAt,
      content: joinDesktopFileContent(lines),
    );
    if (_files[name]!.content.length >= DesktopQueueFiles.maxFileSizeBytes) {
      await sealCurrentFile();
    }
  }

  @override
  Future<String?> sealCurrentFile() async {
    _requireInit();
    final open = _openName();
    final file = _files.remove(open);
    if (file == null || splitDesktopFileContent(file.content).isEmpty) {
      return null;
    }
    final index = _scalars[DesktopStoreKeys.fileIndex] as int? ?? 0;
    final sealed = DesktopQueueFiles.sealedName(index);
    _files[sealed] = file;
    _scalars[DesktopStoreKeys.fileIndex] = index + 1;
    return sealed;
  }

  @override
  Future<List<String>> listFilesOldestFirst() async {
    _requireInit();
    final names = _files.keys.where((name) => !name.endsWith('.tmp')).toList()
      ..sort((a, b) {
        final order =
            desktopFileSortIndex(a).compareTo(desktopFileSortIndex(b));
        return order != 0 ? order : a.compareTo(b);
      });
    return names;
  }

  @override
  Future<String?> readFile(String name) async {
    _requireInit();
    return _files[name]?.content;
  }

  @override
  Future<int?> fileCreatedAt(String name) async {
    _requireInit();
    return _files[name]?.createdAtMs;
  }

  @override
  Future<void> writeFile(String name, String content,
      {int? createdAtMs}) async {
    _requireInit();
    final existing = _files[name];
    _files[name] = _StoredFile(
      createdAtMs: createdAtMs ?? existing?.createdAtMs ?? _nowMs(),
      content: content,
    );
  }

  @override
  Future<void> removeFile(String name) async {
    _requireInit();
    _files.remove(name);
  }

  @override
  Future<List<String>> splitFile(String name) async {
    _requireInit();
    final file = _files[name];
    final lines =
        file == null ? <String>[] : splitDesktopFileContent(file.content);
    if (lines.length < 2) {
      return [name];
    }
    final half = lines.length ~/ 2;
    final first = DesktopQueueFiles.splitName(name, 1);
    final second = DesktopQueueFiles.splitName(name, 2);
    _files[first] = _StoredFile(
      createdAtMs: file!.createdAtMs,
      content: joinDesktopFileContent(lines.sublist(0, half)),
    );
    _files[second] = _StoredFile(
      createdAtMs: file.createdAtMs,
      content: joinDesktopFileContent(lines.sublist(half)),
    );
    _files.remove(name);
    return [first, second];
  }

  @override
  Future<void> quarantineFile(String name) async {
    _requireInit();
    final file = _files.remove(name);
    if (file != null) {
      _quarantine[name] = file;
    }
  }

  @override
  Future<void> clearAll() async {
    _requireInit();
    _scalars.clear();
    _files.clear();
    _quarantine.clear();
  }
}

class _StoredFile {
  const _StoredFile({required this.createdAtMs, required this.content});
  final int createdAtMs;
  final String content;
}

// Explicitly-injected compatibility [DesktopStorage] backed by
// `shared_preferences`.
//
// Durability limits (read before relying on this): the plugin writes may be
// persisted asynchronously after the returned future completes, so this
// store must not be used for critical delivery data — a kill can lose an
// acknowledged event. It is kept only for hosts that explicitly inject it
// (and for the one-time migration source in `importLegacyPreferenceQueue`);
// production Windows/Linux defaults to the crash-safe filesystem queue.
// It ships a web implementation, so `lib/desktop/` keeps compiling for web
// (the plan §1.6 ban on `dart:io`), and needs no host-provided directory.
class SharedPreferencesDesktopStorage implements DesktopStorage {
  SharedPreferencesDesktopStorage({
    required String namespace,
    int Function()? clock,
  })  : _namespace = namespace,
        _nowMs = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final String _namespace;
  final int Function() _nowMs;
  SharedPreferences? _prefs;

  String _scalarKey(String key) => '$_namespace/kv/$key';
  String _fileKey(String name) => '$_namespace/file/$name';
  String _quarantineKey(String name) =>
      '$_namespace/${DesktopQueueFiles.quarantinePrefix}$name';
  String _filePrefix() => '$_namespace/file/';
  String _quarantinePrefix() =>
      '$_namespace/${DesktopQueueFiles.quarantinePrefix}';

  SharedPreferences _requirePrefs() {
    final prefs = _prefs;
    assert(prefs != null, 'DesktopStorage.init() must be awaited first');
    return prefs!;
  }

  @override
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  @override
  Future<String?> readString(String key) async {
    return _requirePrefs().getString(_scalarKey(key));
  }

  @override
  Future<void> writeString(String key, String value) async {
    await _requirePrefs().setString(_scalarKey(key), value);
  }

  @override
  Future<int?> readInt(String key) async {
    return _requirePrefs().getInt(_scalarKey(key));
  }

  @override
  Future<void> writeInt(String key, int value) async {
    await _requirePrefs().setInt(_scalarKey(key), value);
  }

  @override
  Future<bool?> readBool(String key) async {
    return _requirePrefs().getBool(_scalarKey(key));
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    await _requirePrefs().setBool(_scalarKey(key), value);
  }

  @override
  Future<void> deleteKey(String key) async {
    await _requirePrefs().remove(_scalarKey(key));
  }

  Future<int> _fileIndex() async {
    return _requirePrefs().getInt(_scalarKey(DesktopStoreKeys.fileIndex)) ?? 0;
  }

  String _encodeFile(int createdAtMs, String content) {
    return json.encode({'createdAt': createdAtMs, 'content': content});
  }

  ({int createdAtMs, String content})? _decodeFile(String? raw) {
    if (raw == null) {
      return null;
    }
    try {
      final map = json.decode(raw) as Map<String, dynamic>;
      return (
        createdAtMs: (map['createdAt'] as num).toInt(),
        content: map['content'] as String,
      );
    } catch (_) {
      // A prefs entry we cannot decode is corruption: callers treat a null
      // body as unreadable and quarantine the file.
      return null;
    }
  }

  @override
  Future<void> appendEvent(String jsonLine) async {
    final prefs = _requirePrefs();
    final index = await _fileIndex();
    final open = DesktopQueueFiles.openName(index);
    final existing = _decodeFile(prefs.getString(_fileKey(open)));
    final lines = existing == null
        ? <String>[]
        : splitDesktopFileContent(existing.content);
    lines.add(jsonLine);
    final content = joinDesktopFileContent(lines);
    await prefs.setString(
      _fileKey(open),
      _encodeFile(existing?.createdAtMs ?? _nowMs(), content),
    );
    if (content.length >= DesktopQueueFiles.maxFileSizeBytes) {
      await sealCurrentFile();
    }
  }

  @override
  Future<String?> sealCurrentFile() async {
    final prefs = _requirePrefs();
    final index = await _fileIndex();
    final open = DesktopQueueFiles.openName(index);
    final existing = _decodeFile(prefs.getString(_fileKey(open)));
    if (existing == null || splitDesktopFileContent(existing.content).isEmpty) {
      return null;
    }
    final sealed = DesktopQueueFiles.sealedName(index);
    await prefs.setString(
      _fileKey(sealed),
      _encodeFile(existing.createdAtMs, existing.content),
    );
    await prefs.remove(_fileKey(open));
    await prefs.setInt(_scalarKey(DesktopStoreKeys.fileIndex), index + 1);
    return sealed;
  }

  @override
  Future<List<String>> listFilesOldestFirst() async {
    final prefs = _requirePrefs();
    final prefix = _filePrefix();
    final names = prefs
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .map((key) => key.substring(prefix.length))
        .where((name) => !name.endsWith('.tmp'))
        .toList()
      ..sort((a, b) {
        final order =
            desktopFileSortIndex(a).compareTo(desktopFileSortIndex(b));
        return order != 0 ? order : a.compareTo(b);
      });
    return names;
  }

  @override
  Future<String?> readFile(String name) async {
    final raw = _requirePrefs().getString(_fileKey(name));
    return _decodeFile(raw)?.content;
  }

  @override
  Future<int?> fileCreatedAt(String name) async {
    final raw = _requirePrefs().getString(_fileKey(name));
    return _decodeFile(raw)?.createdAtMs;
  }

  @override
  Future<void> writeFile(String name, String content,
      {int? createdAtMs}) async {
    final prefs = _requirePrefs();
    final existing = _decodeFile(prefs.getString(_fileKey(name)));
    await prefs.setString(
      _fileKey(name),
      _encodeFile(createdAtMs ?? existing?.createdAtMs ?? _nowMs(), content),
    );
  }

  @override
  Future<void> removeFile(String name) async {
    await _requirePrefs().remove(_fileKey(name));
  }

  @override
  Future<List<String>> splitFile(String name) async {
    final prefs = _requirePrefs();
    final existing = _decodeFile(prefs.getString(_fileKey(name)));
    final lines = existing == null
        ? <String>[]
        : splitDesktopFileContent(existing.content);
    if (lines.length < 2) {
      return [name];
    }
    final half = lines.length ~/ 2;
    final first = DesktopQueueFiles.splitName(name, 1);
    final second = DesktopQueueFiles.splitName(name, 2);
    await prefs.setString(
      _fileKey(first),
      _encodeFile(existing!.createdAtMs,
          joinDesktopFileContent(lines.sublist(0, half))),
    );
    await prefs.setString(
      _fileKey(second),
      _encodeFile(
          existing.createdAtMs, joinDesktopFileContent(lines.sublist(half))),
    );
    await prefs.remove(_fileKey(name));
    return [first, second];
  }

  @override
  Future<void> quarantineFile(String name) async {
    final prefs = _requirePrefs();
    final raw = prefs.getString(_fileKey(name));
    if (raw != null) {
      await prefs.setString(_quarantineKey(name), raw);
      await prefs.remove(_fileKey(name));
    }
  }

  @override
  Future<void> clearAll() async {
    final prefs = _requirePrefs();
    // The legacy `quarantine/` prefix (pre-`quarantinePrefix` wiring) is
    // cleared too so upgrades never orphan quarantined entries.
    const legacyQuarantinePrefix = 'quarantine/';
    final mine = prefs.getKeys().where((key) =>
        key.startsWith('$_namespace/kv/') ||
        key.startsWith(_filePrefix()) ||
        key.startsWith(_quarantinePrefix()) ||
        key.startsWith('$_namespace/$legacyQuarantinePrefix'));
    for (final key in mine.toList()) {
      await prefs.remove(key);
    }
  }
}
