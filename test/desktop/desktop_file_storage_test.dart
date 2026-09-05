import 'dart:io';

import 'package:amplitude_flutter/desktop/desktop_file_storage_io.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_storage_test.dart' show testDesktopStorageConformance;

// Fault-injection and crash-recovery suite for the filesystem event queue.
//
// WHY real temporary directories everywhere: crash safety is a property of
// bytes on a filesystem, and no fake can prove a rename is atomic. Each
// interruption below is seeded directly as filesystem state (a leftover
// `.tmp`, a transaction marker, a colliding sealed name) because that is
// exactly what a killed process leaves behind.

/// Creates a file-backed store in a fresh temporary directory.
Future<(FileDesktopStorage, Directory)> makeFileStorage({
  String namespace = 'storage-test-key-test',
}) async {
  final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
  final storage = FileDesktopStorage(namespace: namespace, directory: root);
  await storage.init();
  return (storage, root);
}

void main() {
  group('FileDesktopStorage conformance', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('amplitude-desktop-');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    testDesktopStorageConformance(
      'filesystem',
      () => FileDesktopStorage(
        namespace: 'storage-test-key-test',
        directory: root,
      ),
    );
  });

  group('crash recovery', () {
    test('events survive a restart in order', () async {
      final (first, root) = await makeFileStorage();
      try {
        await first.appendEvent('{"event_type":"a"}');
        await first.appendEvent('{"event_type":"b"}');

        // Simulate a kill: drop the object without sealing or flushing.
        final second = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await second.init();

        final files = await second.listFilesOldestFirst();
        expect(files, hasLength(1));
        expect(
          splitDesktopFileContent((await second.readFile(files.single))!),
          ['{"event_type":"a"}', '{"event_type":"b"}'],
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a stale open file never overwrites its sealed namesake', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        final storage = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await storage.init();
        await storage.appendEvent('{"event_type":"old"}');
        await storage.sealCurrentFile();

        // A previous process sealed v2-0, then died after renaming but
        // before moving on: the abandoned open file still carries index 0.
        final nsDir = storage.directoryForTests;
        await File('${nsDir.path}/v2-0.tmp')
            .writeAsString('{"event_type":"new"}\u0000', flush: true);

        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();

        final files = await recovered.listFilesOldestFirst();
        expect(files, hasLength(2));
        final bodies = [
          for (final name in files) await recovered.readFile(name),
        ];
        expect(bodies[0], contains('old'));
        expect(bodies[1], contains('new'));
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('rollover measures UTF-8 bytes, not Dart string length', () async {
      final (storage, root) = await makeFileStorage();
      try {
        // 'é' is 2 UTF-8 bytes: 487,499 chars = 974,998 bytes, well under
        // 975,000 chars but 11 bytes short of 975,000 bytes.
        final pad = 'é' * 487499;
        await storage.appendEvent(pad);
        await storage.appendEvent('1234567890');

        // A String.length implementation would keep one open file; the byte
        // implementation must have sealed the first and continued in v2-1.
        expect(await storage.listFilesOldestFirst(), ['v2-0']);
        expect(await storage.sealCurrentFile(), 'v2-1');
        expect(await storage.readFile('v2-0'), pad);
        expect(await storage.readFile('v2-1'), '1234567890');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a partial trailing write keeps only whole records', () async {
      final (storage, root) = await makeFileStorage();
      try {
        final nsDir = storage.directoryForTests;
        // Fresh instance with no queue yet; plant the crash leftover, then
        // recover with a second instance on the same directory.
        await File('${nsDir.path}/v2-3.tmp')
            .writeAsString('{"a":1}\u0000{"b":2}\u0000{"cut', flush: true);

        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();

        final files = await recovered.listFilesOldestFirst();
        expect(files, hasLength(1));
        expect(
          splitDesktopFileContent((await recovered.readFile(files.single))!),
          ['{"a":1}', '{"b":2}'],
        );
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  group('survivor rewrite transactions', () {
    test('temp leftovers without a commit keep the original', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.appendEvent('{"event_type":"old"}');
        await storage.sealCurrentFile();
        final nsDir = storage.directoryForTests;
        // Crash during the temp write: new bytes staged, marker and backup
        // absent, original untouched.
        await File('${nsDir.path}/v2-0.rw.tmp')
            .writeAsString('new-content', flush: true);
        await File('${nsDir.path}/v2-0.rw.txn').writeAsString('', flush: true);

        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();

        expect(await recovered.readFile('v2-0'), contains('old'));
        expect(await recovered.listFilesOldestFirst(), ['v2-0']);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a moved-aside original is restored when the commit never landed',
        () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.appendEvent('{"event_type":"old"}');
        await storage.sealCurrentFile();
        final nsDir = storage.directoryForTests;
        // Crash between moving the original aside and landing the rewrite:
        // final name missing, backup and staged rewrite present.
        await File('${nsDir.path}/v2-0').rename('${nsDir.path}/v2-0.bak');
        await File('${nsDir.path}/v2-0.rw.tmp')
            .writeAsString('new-content', flush: true);
        await File('${nsDir.path}/v2-0.rw.txn').writeAsString('', flush: true);

        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();

        // The complete old copy wins over the uncommitted rewrite.
        expect(await recovered.readFile('v2-0'), contains('old'));
        expect(await recovered.listFilesOldestFirst(), ['v2-0']);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a landed rewrite discards its backup and marker', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.appendEvent('{"event_type":"old"}');
        await storage.sealCurrentFile();
        final nsDir = storage.directoryForTests;
        // Crash after landing the rewrite, before cleanup.
        await File('${nsDir.path}/v2-0')
            .writeAsString('new-content', flush: true);
        await File('${nsDir.path}/v2-0.bak')
            .writeAsString('{"event_type":"old"}\u0000', flush: true);
        await File('${nsDir.path}/v2-0.rw.txn').writeAsString('', flush: true);

        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();

        expect(await recovered.readFile('v2-0'), 'new-content');
        expect(await recovered.listFilesOldestFirst(), ['v2-0']);
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  group('quarantine', () {
    test('a colliding quarantine name never overwrites evidence', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.appendEvent('{"event_type":"a"}');
        await storage.sealCurrentFile();

        // Earlier evidence already sits under the same quarantine name.
        final qDir = Directory('${storage.directoryForTests.path}/.quarantine');
        await qDir.create(recursive: true);
        await File('${qDir.path}/v2-0')
            .writeAsString('planted-evidence', flush: true);

        await storage.quarantineFile('v2-0');

        expect(await storage.listFilesOldestFirst(), isEmpty);
        expect(
            await File('${qDir.path}/v2-0').readAsString(), 'planted-evidence');
        var found = false;
        await for (final entity in qDir.list()) {
          if (entity is File &&
              entity.path != '${qDir.path}/v2-0' &&
              (await entity.readAsString()).contains('event_type')) {
            found = true;
          }
        }
        expect(found, isTrue,
            reason: 'the quarantined queue file must survive beside evidence');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('quarantining a missing file is a no-op', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.quarantineFile('v2-missing');
        expect(await storage.listFilesOldestFirst(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  group('split transactions', () {
    Future<Directory> seedSplitState(
      Directory root, {
      bool source = true,
      bool child1 = false,
      bool child2 = false,
      bool childTemp = false,
      bool backup = false,
      bool marker = true,
    }) async {
      final storage = FileDesktopStorage(
        namespace: 'storage-test-key-test',
        directory: root,
      );
      await storage.init();
      final dir = storage.directoryForTests;
      if (source) {
        await File('${dir.path}/v2-4').writeAsString(
            ['e0', 'e1', 'e2', 'e3'].join('\u0000'),
            flush: true);
      }
      if (child1) {
        await File('${dir.path}/v2-4-1')
            .writeAsString(['e0', 'e1'].join('\u0000'), flush: true);
      }
      if (child2) {
        await File('${dir.path}/v2-4-2')
            .writeAsString(['e2', 'e3'].join('\u0000'), flush: true);
      }
      if (childTemp) {
        await File('${dir.path}/v2-4-1.sp.tmp')
            .writeAsString('scratch', flush: true);
      }
      if (backup) {
        await File('${dir.path}/v2-4.bak').writeAsString('backup', flush: true);
      }
      if (marker) {
        await File('${dir.path}/v2-4.sp.txn').writeAsString('', flush: true);
      }
      return dir;
    }

    Future<FileDesktopStorage> recover(Directory root) async {
      final storage = FileDesktopStorage(
        namespace: 'storage-test-key-test',
        directory: root,
      );
      await storage.init();
      return storage;
    }

    test('source with staged children rolls back to the source', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        await seedSplitState(root, child1: true, childTemp: true);
        final storage = await recover(root);

        // Never both: the untouched source wins, staged children vanish.
        expect(await storage.listFilesOldestFirst(), ['v2-4']);
        expect(
          splitDesktopFileContent((await storage.readFile('v2-4'))!),
          ['e0', 'e1', 'e2', 'e3'],
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a lone marker is cleaned without touching the source', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        await seedSplitState(root);
        final storage = await recover(root);

        expect(await storage.listFilesOldestFirst(), ['v2-4']);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('committed children complete and the backup goes away', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        await seedSplitState(root,
            source: false, child1: true, child2: true, backup: true);
        final storage = await recover(root);

        expect(
          await storage.listFilesOldestFirst(),
          ['v2-4-1', 'v2-4-2'],
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('partial children restore the moved-aside source', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        await seedSplitState(root,
            source: false, child1: true, childTemp: true, backup: true);
        final storage = await recover(root);

        expect(await storage.listFilesOldestFirst(), ['v2-4']);
        expect(await storage.readFile('v2-4'), 'backup');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('committed children without a backup still complete', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        await seedSplitState(root, source: false, child1: true, child2: true);
        final storage = await recover(root);

        expect(
          await storage.listFilesOldestFirst(),
          ['v2-4-1', 'v2-4-2'],
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('partials without a backup are kept, scratch is dropped', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        await seedSplitState(root,
            source: false, child1: true, childTemp: true);
        final storage = await recover(root);

        expect(await storage.listFilesOldestFirst(), ['v2-4-1']);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a backup alone restores the source', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        await seedSplitState(root, source: false, backup: true);
        final storage = await recover(root);

        expect(await storage.listFilesOldestFirst(), ['v2-4']);
        expect(await storage.readFile('v2-4'), 'backup');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('split halves keep the original creation time', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.appendEvent('e0');
        await storage.appendEvent('e1');
        await storage.appendEvent('e2');
        await storage.appendEvent('e3');
        await storage.sealCurrentFile();
        final before = await storage.fileCreatedAt('v2-0');

        final halves = await storage.splitFile('v2-0');
        expect(halves, ['v2-0-1', 'v2-0-2']);
        expect(await storage.fileCreatedAt('v2-0-1'), before);
        expect(await storage.fileCreatedAt('v2-0-2'), before);
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  group('hardening', () {
    test('namespaces cannot see or delete one another', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        final a = FileDesktopStorage(namespace: 'ns-a', directory: root);
        final b = FileDesktopStorage(namespace: 'ns-b', directory: root);
        await a.init();
        await b.init();

        await a.writeString('k', 'a-value');
        await a.appendEvent('e');
        await a.sealCurrentFile();
        expect(await b.readString('k'), isNull);
        expect(await b.listFilesOldestFirst(), isEmpty);

        await a.clearAll();
        expect(await a.readString('k'), isNull);
        expect(await b.readString('k'), isNull,
            reason: 'clearAll must not touch sibling namespaces');
        await b.appendEvent('still-there');
        expect(await b.sealCurrentFile(), isNotNull);
        expect(await b.listFilesOldestFirst(), hasLength(1));
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('an empty namespace is rejected', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        expect(
          () => FileDesktopStorage(namespace: '', directory: root),
          throwsArgumentError,
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('clearAll twice is a no-op the second time', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.appendEvent('e');
        await storage.clearAll();
        await storage.clearAll();
        expect(await storage.listFilesOldestFirst(), isEmpty);
      } finally {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      }
    });

    test('failed appends surface instead of reporting success', () async {
      final (storage, root) = await makeFileStorage();
      try {
        // A directory where the open file should be makes every write fail.
        final blocker = Directory('${storage.directoryForTests.path}/v2-0.tmp');
        await blocker.create();

        await expectLater(storage.appendEvent('e'), throwsA(isA<Object>()));
        expect(await storage.listFilesOldestFirst(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('hostile names stay inside the queue', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await expectLater(storage.readFile('../escape'), throwsArgumentError);
        await expectLater(storage.writeFile('a/b', 'x'), throwsArgumentError);
        await expectLater(storage.removeFile('C:\\evil'), throwsArgumentError);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('garbage scalars read as missing', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.writeString('i', 'not-a-number');
        await storage.writeString('b', 'maybe');
        expect(await storage.readInt('i'), isNull);
        expect(await storage.readBool('b'), isNull);
        expect(await storage.fileCreatedAt('v2-missing'), isNull);
        await storage.deleteKey('v2-missing');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('an abandoned empty open file seals to nothing', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await File('${storage.directoryForTests.path}/v2-9.tmp')
            .writeAsString('', flush: true);
        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();
        expect(await recovered.listFilesOldestFirst(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('unrelated files never join the queue', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await File('${storage.directoryForTests.path}/notes.txt')
            .writeAsString('hello', flush: true);
        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();
        expect(await recovered.listFilesOldestFirst(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a fresh rewrite stamps the current time', () async {
      final (storage, root) = await makeFileStorage();
      try {
        final before = DateTime.now().millisecondsSinceEpoch;
        await storage.writeFile('v2-new', 'content');
        final created = await storage.fileCreatedAt('v2-new');
        expect(created, greaterThanOrEqualTo(before));
        expect(
          created!,
          lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch),
        );
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('false persists as false, not as missing', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.writeBool('flag', false);
        expect(await storage.readBool('flag'), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('sealing an existing but empty open file returns null', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await File('${storage.directoryForTests.path}/v2-0.tmp')
            .writeAsString('', flush: true);
        expect(await storage.sealCurrentFile(), isNull);
        expect(await storage.listFilesOldestFirst(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('a second collision takes the next free suffix', () async {
      final (storage, root) = await makeFileStorage();
      try {
        await storage.appendEvent('{"event_type":"old"}');
        await storage.sealCurrentFile();
        final nsDir = storage.directoryForTests;
        await File('${nsDir.path}/v2-0-1')
            .writeAsString('sibling\u0000', flush: true);
        await File('${nsDir.path}/v2-0.tmp')
            .writeAsString('{"event_type":"new"}\u0000', flush: true);

        final recovered = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await recovered.init();

        final files = await recovered.listFilesOldestFirst();
        expect(files, ['v2-0', 'v2-0-1', 'v2-0-2']);
        expect(await recovered.readFile('v2-0-2'), contains('new'));
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('re-init sees previous scalars, files, and directories', () async {
      final root = await Directory.systemTemp.createTemp('amplitude-desktop-');
      try {
        final first = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await first.init();
        await first.writeString('k', 'v');
        await first.appendEvent('{"event_type":"a"}');
        await first.sealCurrentFile();

        final second = FileDesktopStorage(
          namespace: 'storage-test-key-test',
          directory: root,
        );
        await second.init();

        expect(await second.readString('k'), 'v');
        expect(await second.listFilesOldestFirst(), ['v2-0']);
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('the default location resolves under application support', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final temp = await Directory.systemTemp.createTemp('amplitude-support-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return temp.path;
        }
        return null;
      });
      try {
        final storage = FileDesktopStorage(namespace: 'storage-k-s');
        await storage.init();
        expect(
          storage.directoryForTests.path,
          startsWith(temp.path),
        );
        await storage.appendEvent('{"event_type":"a"}');
        expect(await storage.listFilesOldestFirst(), isEmpty);
        await storage.sealCurrentFile();
        expect(await storage.listFilesOldestFirst(), hasLength(1));
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        await temp.delete(recursive: true);
      }
    });
  });
}
