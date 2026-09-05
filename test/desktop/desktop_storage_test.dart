import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Conformance suite: every DesktopStorage implementation must behave
// identically, so both run the same cases (the in-memory fake doubles as
// the reference for the persisted default).
void testDesktopStorageConformance(
  String name,
  DesktopStorage Function() factory,
) {
  group(name, () {
    late DesktopStorage storage;

    setUp(() async {
      storage = factory();
      await storage.init();
    });

    test('scalars round-trip and delete', () async {
      expect(await storage.readString('s'), isNull);
      await storage.writeString('s', 'v');
      expect(await storage.readString('s'), 'v');

      expect(await storage.readInt('i'), isNull);
      await storage.writeInt('i', 42);
      expect(await storage.readInt('i'), 42);

      expect(await storage.readBool('b'), isNull);
      await storage.writeBool('b', true);
      expect(await storage.readBool('b'), isTrue);

      await storage.deleteKey('s');
      expect(await storage.readString('s'), isNull);
    });

    test('sealing an empty queue returns null', () async {
      expect(await storage.sealCurrentFile(), isNull);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('append, seal, and list oldest-first', () async {
      await storage.appendEvent('{"event_type":"a"}');
      await storage.appendEvent('{"event_type":"b"}');
      final first = await storage.sealCurrentFile();
      expect(first, 'v2-0');

      await storage.appendEvent('{"event_type":"c"}');
      final second = await storage.sealCurrentFile();
      expect(second, 'v2-1');

      expect(await storage.listFilesOldestFirst(), ['v2-0', 'v2-1']);
      expect(
        await storage.readFile('v2-0'),
        joinDesktopFileContent(['{"event_type":"a"}', '{"event_type":"b"}']),
      );
    });

    test('quarantine removes the file from the queue', () async {
      await storage.appendEvent('{"event_type":"a"}');
      await storage.sealCurrentFile();
      await storage.appendEvent('{"event_type":"b"}');
      await storage.sealCurrentFile();

      await storage.quarantineFile('v2-0');
      // One corrupt file must never wedge the queue: the healthy file
      // stays listed and readable.
      expect(await storage.listFilesOldestFirst(), ['v2-1']);
      expect(await storage.readFile('v2-1'), '{"event_type":"b"}');
      expect(await storage.readFile('v2-0'), isNull);
    });

    test('split halves a multi-event file oldest-half-first', () async {
      await storage.appendEvent('e0');
      await storage.appendEvent('e1');
      await storage.appendEvent('e2');
      await storage.appendEvent('e3');
      await storage.sealCurrentFile();

      final halves = await storage.splitFile('v2-0');
      expect(halves, ['v2-0-1', 'v2-0-2']);
      expect(await storage.listFilesOldestFirst(), ['v2-0-1', 'v2-0-2']);
      expect(await storage.readFile('v2-0-1'),
          joinDesktopFileContent(['e0', 'e1']));
      expect(await storage.readFile('v2-0-2'),
          joinDesktopFileContent(['e2', 'e3']));
    });

    test('split of a single-event file leaves it in place', () async {
      await storage.appendEvent('only');
      await storage.sealCurrentFile();
      expect(await storage.splitFile('v2-0'), ['v2-0']);
      expect(await storage.listFilesOldestFirst(), ['v2-0']);
    });

    test('split of a missing file returns its name and changes nothing',
        () async {
      expect(await storage.splitFile('v2-missing'), ['v2-missing']);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('removing a file drops it; removing again is a no-op', () async {
      await storage.appendEvent('e');
      await storage.sealCurrentFile();
      await storage.removeFile('v2-0');
      expect(await storage.listFilesOldestFirst(), isEmpty);
      expect(await storage.readFile('v2-0'), isNull);
      await storage.removeFile('v2-0');
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });

    test('a full open file seals itself and appends continue past it',
        () async {
      // One line past the 975 KB cap forces the rollover mid-append.
      final big = 'x' * (975 * 1024);
      await storage.appendEvent(big);
      expect(await storage.listFilesOldestFirst(), ['v2-0']);

      await storage.appendEvent('small');
      expect(await storage.sealCurrentFile(), 'v2-1');
      expect(await storage.listFilesOldestFirst(), ['v2-0', 'v2-1']);
      expect((await storage.readFile('v2-0'))!.length, big.length);
      expect(await storage.readFile('v2-1'), 'small');
    });

    test('writeFile requeues survivors preserving creation time', () async {
      await storage.appendEvent('keep');
      await storage.sealCurrentFile();
      await storage.writeFile('v2-0', 'keep', createdAtMs: 7);
      // Compared at one-second granularity: Windows reports modification
      // times truncated to whole seconds, so exact-millisecond equality
      // cannot hold there — while a reset clock (now) would still fail.
      expect((await storage.fileCreatedAt('v2-0'))! ~/ 1000, 0);
      // A rewrite without an explicit timestamp must preserve the
      // original creation time (not reset the 30-day age): this is what
      // the partial-400 path relies on.
      await storage.writeFile('v2-0', 'keep');
      expect((await storage.fileCreatedAt('v2-0'))! ~/ 1000, 0);
      expect(await storage.readFile('v2-0'), 'keep');
    });

    test('clearAll wipes scalars, files, and quarantine', () async {
      await storage.writeString('k', 'v');
      await storage.appendEvent('e');
      await storage.sealCurrentFile();
      await storage.quarantineFile('v2-0');
      await storage.clearAll();

      expect(await storage.readString('k'), isNull);
      expect(await storage.listFilesOldestFirst(), isEmpty);
    });
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testDesktopStorageConformance(
      'InMemoryDesktopStorage', () => InMemoryDesktopStorage());

  group('SharedPreferencesDesktopStorage', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    testDesktopStorageConformance(
      'conformance',
      () => SharedPreferencesDesktopStorage(namespace: 'test-ns'),
    );

    test('namespaces do not overlap', () async {
      final a = SharedPreferencesDesktopStorage(namespace: 'ns-a');
      final b = SharedPreferencesDesktopStorage(namespace: 'ns-b');
      await a.init();
      await b.init();

      await a.writeString('k', 'a-value');
      expect(await b.readString('k'), isNull);

      await a.appendEvent('e');
      await a.sealCurrentFile();
      expect(await b.listFilesOldestFirst(), isEmpty);

      await a.clearAll();
      expect(await a.readString('k'), isNull);
    });

    test('corrupt envelopes read as missing, never throw', () async {
      // Seeded through the live instance: re-seeding mock initial values
      // mid-file races the getInstance cache, so write directly instead.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('test-ns/file/v2-0', 'not-json{{{');
      final storage = SharedPreferencesDesktopStorage(namespace: 'test-ns');
      await storage.init();

      expect(await storage.readFile('v2-0'), isNull);
      expect(await storage.fileCreatedAt('v2-0'), isNull);
      await prefs.remove('test-ns/file/v2-0');
    });

    test('clearAll sweeps the legacy quarantine prefix too', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'test-ns/quarantine/orphan', '{"createdAt": 1, "content": ""}');
      final storage = SharedPreferencesDesktopStorage(namespace: 'test-ns');
      await storage.init();
      await storage.clearAll();

      expect(
        prefs.getKeys().where((k) => k.startsWith('test-ns/')),
        isEmpty,
        reason: 'upgrades must never orphan quarantined entries',
      );
    });
  });

  group('file content helpers', () {
    test('split/join round-trip', () {
      expect(splitDesktopFileContent(''), isEmpty);
      expect(splitDesktopFileContent(joinDesktopFileContent(['a', 'b'])),
          ['a', 'b']);
      // The delimiter is a control character, never valid inside JSON.
      expect(joinDesktopFileContent(['a']), isNot(contains('\u0000')));
      expect(joinDesktopFileContent(['a', 'b']), contains('\u0000'));
    });

    test('unparseable names sort last', () {
      expect(desktopFileSortIndex('v2-3'), 3);
      expect(desktopFileSortIndex('junk'), greaterThan(1000000));
      // Huge digit strings overflow int.parse — they sort last too.
      expect(
        desktopFileSortIndex('v2-99999999999999999999999999'),
        greaterThan(1000000),
      );
    });
  });
}
