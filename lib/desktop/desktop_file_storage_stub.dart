import 'desktop_storage.dart';

// Non-IO stub: importing the desktop file queue on a target without
// `dart:io` (web) fails loudly instead of silently misbehaving.
//
// This file is intentionally excluded from the desktop coverage gate: the
// Linux/Windows VM build never compiles it (see the conditional export in
// `desktop_file_storage.dart`).
class FileDesktopStorage implements DesktopStorage {
  FileDesktopStorage({required String namespace, dynamic directory}) {
    throw UnsupportedError(
      'FileDesktopStorage needs dart:io and is unavailable on this target',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
