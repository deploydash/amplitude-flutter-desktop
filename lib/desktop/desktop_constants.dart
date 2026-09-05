// Desktop backend constants.
//
// WHY this file exists: the retry/backoff, file-size, and retention numbers
// below mirror the production Swift/Kotlin pipelines (see the citations).
// They live in one place so a tuning change cannot drift between the
// transport, the queue, and the tests.

/// HTTPS ingestion endpoints (Swift `Constants.swift:82-85`).
class DesktopEndpoints {
  static const us = 'https://api2.amplitude.com/2/httpapi';
  static const usBatch = 'https://api2.amplitude.com/batch';
  static const eu = 'https://api.eu.amplitude.com/2/httpapi';
  static const euBatch = 'https://api.eu.amplitude.com/batch';
}

/// Queue file layout (Swift `PersistentStorage.swift:251-308`).
class DesktopQueueFiles {
  /// Open (appendable) file name for a given index.
  static String openName(int index) => 'v2-$index.tmp';

  /// Sealed (uploadable) file name for a given index.
  static String sealedName(int index) => 'v2-$index';

  /// Suffix halves get when a 413 splits a file (Swift `splitBlock`).
  static String splitName(String name, int half) => '$name-$half';

  /// Hidden quarantine dir for unreadable files (Swift `QUARANTINE_DIR_NAME`).
  static const quarantinePrefix = '.quarantine/';

  /// Seal the open file early once it grows past this (Swift `MAX_FILE_SIZE`).
  static const maxFileSizeBytes = 975 * 1024;

  /// Events are stored as JSON lines separated by this (Swift `DELMITER`).
  static const delimiter = '\u0000';
}

/// Retry and retention tuning.
class DesktopRetry {
  /// Backoff between files is `min(60s, 2^(failures-1))` (Swift `EventPipeline`).
  static const maxBackoffSeconds = 60;

  /// While offline, re-probe with a single attempt on this interval so
  /// long-running desktop apps self-heal without a restart.
  static const offlineReprobeHours = 6;

  /// Backstop: files older than this are discarded with a callback — the only
  /// point at which data loss becomes explicit.
  static const maxFileAgeDays = 30;
}

/// Smallest identify-batch interval (Swift `Constants.swift:90`).
const desktopMinIdentifyBatchIntervalMillis = 30 * 1000;
