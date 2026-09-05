// Filesystem event queue for Windows/Linux.
//
// WHY a separate file behind a conditional export: the queue must use
// `dart:io` (real files, atomic renames, fsync), but `lib/desktop/` still
// compiles for web — so this implementation is only exported when
// `dart:io` exists. See `desktop_file_storage.dart`.
export 'desktop_file_storage_stub.dart'
    if (dart.library.io) 'desktop_file_storage_io.dart';
