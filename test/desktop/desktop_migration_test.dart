import 'dart:convert';
import 'dart:io';

import 'package:amplitude_flutter/desktop/desktop_file_storage_io.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// One-time migration: legacy `shared_preferences` queue entries into the
// crash-safe filesystem queue (T-10B).
//
// WHY these tests seed mock preferences directly: the migration reads the
// exact frozen key layout (`<ns>/file/<name>`, `<ns>/.quarantine/<name>`)
// that `SharedPreferencesDesktopStorage` wrote for existing fork
// installations. Seeding through a live prefs instance exercises the real
// envelope decoding, including corrupt and foreign entries.

const _ns = 'storage-migrate-key-test';

String _envelope(int createdAt, String content) =>
    json.encode({'createdAt': createdAt, 'content': content});

/// File storage that misreads every file: proves a failed verification
/// aborts migration loudly instead of deleting the legacy source.
class TamperingFileStorage extends FileDesktopStorage {
  TamperingFileStorage({required super.namespace, super.directory});

  @override
  Future<String?> readFile(String name) async => 'tampered';
}

Future<FileDesktopStorage> _files(Directory root) async {
  final storage = FileDesktopStorage(namespace: _ns, directory: root);
  await storage.init();
  return storage;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Installs the mock preferences backend once; each test then clears and
  // seeds through the live instance (re-seeding here would race the cache).
  SharedPreferences.setMockInitialValues({});

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('amplitude-migrate-');
    // Clear through the live instance: re-seeding mock initial values
    // after `getInstance` cached would leave stale keys behind.
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      await prefs.remove(key);
    }
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  /// Seeds legacy string entries through the live preferences instance.
  Future<SharedPreferences> seed(Map<String, String> values) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in values.entries) {
      await prefs.setString(entry.key, entry.value);
    }
    return prefs;
  }

  group('importLegacyPreferenceQueue', () {
    test('migrates open, sealed, split, and quarantine entries once', () async {
      final prefs = await seed({
        '$_ns/file/v2-0': _envelope(1000, joinDesktopFileContent(['a', 'b'])),
        '$_ns/file/v2-0.tmp': _envelope(2000, 'c'),
        '$_ns/file/v2-2-1': _envelope(3000, 'd'),
        '$_ns/file/junk': _envelope(6000, 'junk-bytes'),
        '$_ns/.quarantine/v2-9': _envelope(4000, 'bad{{{'),
        '$_ns/quarantine/v2-8': _envelope(5000, 'legacy-q'),
        'other-ns/file/v2-0': _envelope(1000, 'foreign'),
        '$_ns/kv/deviceId': 'scalar-stays',
      });
      final storage = await _files(root);

      await storage.importLegacyPreferenceQueue(prefs);

      // Order, content, and age survive; the open entry lands sealed, and
      // sharing an index with the sealed entry earns a collision suffix.
      expect(
          await storage.listFilesOldestFirst(), ['v2-0', 'v2-0-1', 'v2-2-1']);
      expect(await storage.readFile('v2-0'), 'a\u0000b');
      expect(await storage.readFile('v2-0-1'), 'c');
      expect(await storage.readFile('v2-2-1'), 'd');
      expect(await storage.fileCreatedAt('v2-0'), 1000);
      expect(await storage.fileCreatedAt('v2-0-1'), 2000);
      expect(await storage.fileCreatedAt('v2-2-1'), 3000);
      // Legacy queue keys are gone; foreign namespaces and scalars stay.
      expect(
        prefs.getKeys().where((k) => k.startsWith('$_ns/file/')),
        isEmpty,
      );
      expect(
        prefs.getKeys().where((k) => k.contains('quarantine')),
        isEmpty,
      );
      expect(prefs.getString('other-ns/file/v2-0'), isNotNull);
      expect(prefs.getString('$_ns/kv/deviceId'), 'scalar-stays');
      // Quarantined evidence (current prefix, legacy prefix, and the
      // unrecognized name) is preserved, not deleted.
      final qDir = Directory('${storage.directoryForTests.path}/.quarantine');
      final kept = <String>[];
      await for (final entity in qDir.list()) {
        if (entity is File) {
          kept.add(await entity.readAsString());
        }
      }
      expect(kept.length, 3);
      expect(kept.join(), contains('bad'));
      expect(kept.join(), contains('legacy-q'));
      expect(kept.join(), contains('junk-bytes'));
    });

    test('an already-migrated entry is reused, never duplicated', () async {
      final prefs = await seed({
        '$_ns/file/v2-0': _envelope(1000, 'a'),
      });
      final storage = await _files(root);

      await storage.importLegacyPreferenceQueue(prefs);
      // Crash before the preference delete would rerun migration: the
      // identical destination is verified and reused instead.
      await prefs.setString('$_ns/file/v2-0', _envelope(1000, 'a'));
      await storage.importLegacyPreferenceQueue(prefs);

      expect(await storage.listFilesOldestFirst(), ['v2-0']);
      expect(await storage.readFile('v2-0'), 'a');
      expect(
        prefs.getKeys().where((k) => k.startsWith('$_ns/file/')),
        isEmpty,
      );
    });

    test('malformed envelopes are quarantined with a diagnostic', () async {
      final prefs = await seed({
        '$_ns/file/v2-0': 'not-json{{{',
        '$_ns/file/v2-1': '{"createdAt": "x", "content": 42}',
        '$_ns/file/v2-2': _envelope(1000, ''),
      });
      final storage = await _files(root);

      await storage.importLegacyPreferenceQueue(prefs);

      // Nothing silently deleted: corrupt entries land in quarantine, the
      // empty one is dropped as content-free, and no queue file appears.
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(
        prefs.getKeys().where((k) => k.startsWith('$_ns/file/')),
        isEmpty,
      );
      final qDir = Directory('${storage.directoryForTests.path}/.quarantine');
      final kept = <String>[];
      await for (final entity in qDir.list()) {
        if (entity is File) {
          kept.add(await entity.readAsString());
        }
      }
      expect(kept.length, 2);
      expect(kept.join(), contains('not-json'));
    });

    test('foreign-typed entries are left alone', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$_ns/file/v2-0', 7);
      await prefs.setInt('$_ns/.quarantine/v2-1', 8);
      final storage = await _files(root);

      await storage.importLegacyPreferenceQueue(prefs);

      expect(prefs.getInt('$_ns/file/v2-0'), 7);
      expect(prefs.getInt('$_ns/.quarantine/v2-1'), 8);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('a failed verification aborts loudly and keeps the source', () async {
      final prefs = await seed({
        '$_ns/file/v2-0': _envelope(1000, 'a'),
      });
      final storage = TamperingFileStorage(namespace: _ns, directory: root);
      await storage.init();

      await expectLater(
        storage.importLegacyPreferenceQueue(prefs),
        throwsStateError,
      );
      expect(prefs.getString('$_ns/file/v2-0'), isNotNull);
    });
  });
}
