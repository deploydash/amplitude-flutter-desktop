import 'dart:async';
import 'dart:convert';

import '../constants.dart';
import 'desktop_constants.dart';
import 'desktop_dispatch.dart';
import 'desktop_endpoint.dart';
import 'desktop_enricher.dart';
import 'desktop_identify_interceptor.dart';
import 'desktop_identity.dart';
import 'desktop_payload.dart';
import 'desktop_session.dart';
import 'desktop_storage.dart';
import 'desktop_system_info.dart';
import 'desktop_transport.dart';
import 'desktop_uuid.dart';

// Pure-Dart desktop backend (plan Phase 1).
//
// WHY this object exists: Linux and Windows have no native Amplitude SDK to
// bind to, so the fork speaks HTTP ingestion directly (plan Key Decision
// §1). macOS/iOS/Android/Web never touch this class — they keep their
// native/web backends. The pipeline order per event is:
//
//   translate (§E) → identity fill → session (§C) → identify batching (§F)
//   → enrich (§E) → durable append (§B) → batched upload with retry (§A)
//
// All public methods serialize through one async mutex (Dart has no
// isolates in v1; the chain preserves arrival order for host funnels).

/// Terminal per-event outcome (plan §H.9).
///
/// Dart `BaseEvent` has no callback field, so v1 supports config-level
/// callbacks only: every terminal outcome (sent, dropped) invokes this with
/// the event plus the HTTP-style code/message. Null (the default) means
/// diagnostic-log only.
typedef DesktopTerminalCallback = void Function(
  Map<String, dynamic> event,
  int code,
  String message,
);

/// Parsed channel `init` map with desktop defaults (plan §D is
/// authoritative; "noop" rows are read and ignored, never threaded).
class DesktopBackendConfig {
  DesktopBackendConfig.fromChannelMap(Map map) {
    T read<T>(String key, T fallback) {
      final value = map[key];
      return value is T ? value : fallback;
    }

    final rawApiKey = map['apiKey'];
    apiKey = rawApiKey is String ? rawApiKey : '';
    flushQueueSize = _positiveInt(map['flushQueueSize'], 30);
    flushIntervalMillis = _positiveInt(map['flushIntervalMillis'], 30000);
    final rawInstance = map['instanceName'];
    instanceName = rawInstance is String && rawInstance.isNotEmpty
        ? rawInstance
        : Constants.defaultInstanceName;
    initialOptOut = read<bool>('optOut', false);
    logLevel = _parseLogLevel(map['logLevel']);
    final minId = map['minIdLength'];
    minIdLength = minId is int ? minId : null;
    final rawPartner = map['partnerId'];
    partnerId = rawPartner is String ? rawPartner : null;
    flushMaxRetries =
        _positiveInt(map['flushMaxRetries'], Constants.flushMaxRetries);
    useBatch = read<bool>('useBatch', false);
    final rawZone = map['serverZone'];
    serverZone =
        rawZone is String && rawZone == 'eu' ? ServerZone.eu : ServerZone.us;
    final url = map['serverUrl'];
    serverUrl = (url is String && url.isNotEmpty) ? url : null;
    sessionGapMs = _positiveInt(map['minTimeBetweenSessionsMillis'],
        Constants.minTimeBetweenSessionsMillisForMobile);
    final tracking = map['trackingOptions'];
    if (tracking is Map) {
      trackingOptions = {
        for (final entry in tracking.entries)
          entry.key.toString(): entry.value == true,
      };
    } else {
      trackingOptions = const {};
    }
    enableCoppaControl = read<bool>('enableCoppaControl', false);
    flushEventsOnClose = read<bool>('flushEventsOnClose', true);
    identifyBatchIntervalMillis = _positiveInt(
        map['identifyBatchIntervalMillis'],
        Constants.identifyBatchIntervalMillis);
    final rawDevice = map['deviceId'];
    seedDeviceId = rawDevice is String ? rawDevice : null;
    final rawUser = map['userId'];
    initialUserId = rawUser is String ? rawUser : null;
    final rawAppVersion = map['appVersion'];
    appVersion = rawAppVersion is String ? rawAppVersion : null;
    autocaptureSessions = _parseAutocaptureSessions(map['autocapture']);
    // Mobile-only rows below are deliberately unread: migrateLegacyData,
    // locationListening, useAdvertisingIdForDeviceId,
    // useAppSetIdForDeviceId (no such APIs on desktop — §D noop), and the
    // web-only rows (cookieOptions, identityStorage, sessionTimeout copy,
    // transport, fetchRemoteConfig).
  }

  static int _positiveInt(dynamic value, int fallback) {
    return (value is int && value > 0) ? value : fallback;
  }

  static int _parseLogLevel(dynamic value) {
    const order = ['off', 'error', 'warn', 'log', 'debug'];
    final index = value is String ? order.indexOf(value) : -1;
    return index < 0 ? 2 : index;
  }

  static bool _parseAutocaptureSessions(dynamic autocapture) {
    if (autocapture is bool) {
      return autocapture;
    }
    if (autocapture is Map) {
      final sessions = autocapture['sessions'];
      return sessions is bool ? sessions : true;
    }
    return true;
  }

  late final String apiKey;
  late final int flushQueueSize;
  late final int flushIntervalMillis;
  late final String instanceName;
  late final bool initialOptOut;
  late final int logLevel;
  late final int? minIdLength;
  late final String? partnerId;
  late final int flushMaxRetries;
  late final bool useBatch;
  late final ServerZone serverZone;
  late final String? serverUrl;
  late final int sessionGapMs;
  late final Map<String, bool> trackingOptions;
  late final bool enableCoppaControl;
  late final bool flushEventsOnClose;
  late final int identifyBatchIntervalMillis;
  late final String? seedDeviceId;
  late final String? initialUserId;
  late final String? appVersion;
  late final bool autocaptureSessions;
}

class DesktopBackend {
  DesktopBackend({
    DesktopStorage? storage,
    DesktopSystemInfoSource? systemInfo,
    DesktopAppInfoSource? appInfo,
    DesktopTransport? transport,
    int Function()? clock,
    Future<void> Function(Duration)? sleeper,
    Duration? offlineReprobeInterval,
    this.onTerminalEvent,
    void Function(String message)? logger,
  })  : _injectedStorage = storage,
        _systemInfoSource = systemInfo ?? DeviceInfoDesktopSystemInfo(),
        _appInfoSource = appInfo ?? PackageInfoDesktopAppInfo(),
        _transport = transport ?? DesktopTransport(),
        _clock = clock ?? _wallClock,
        _sleeper = sleeper ?? Future.delayed,
        _reprobeInterval = offlineReprobeInterval ??
            const Duration(hours: DesktopRetry.offlineReprobeHours),
        _logger = logger ?? print;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final DesktopStorage? _injectedStorage;
  final DesktopSystemInfoSource _systemInfoSource;
  final DesktopAppInfoSource _appInfoSource;
  final DesktopTransport _transport;
  final int Function() _clock;
  final Future<void> Function(Duration) _sleeper;
  final Duration _reprobeInterval;
  final DesktopTerminalCallback? onTerminalEvent;
  final void Function(String message) _logger;

  DesktopBackendConfig? _config;
  DesktopStorage? _storage;
  DesktopIdentity? _identity;
  DesktopSession? _session;
  DesktopIdentifyInterceptor? _interceptor;
  DesktopOsInfo _osInfo =
      const DesktopOsInfo(platform: 'Unknown', osName: 'unknown');
  DesktopAppVersion _appInfo = const DesktopAppVersion();
  String _language = 'en';
  bool _foreground = true;
  bool _offline = false;
  int _failures = 0;
  int _pendingCount = 0;
  int _throttleUntilMs = 0;
  Timer? _flushTimer;
  Timer? _reprobeTimer;
  Future<void> _tail = Future.value();

  DesktopBackendConfig? get configForTests => _config;

  /// Serializes [op] behind every other backend operation, preserving call
  /// order (host funnels depend on it) and isolating failures.
  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.then((_) {}, onError: (_) {});
    return next;
  }

  void _log(int level, String message) {
    final configLevel = _config?.logLevel ?? 2;
    if (level <= configLevel && configLevel > 0) {
      _logger('amplitude-desktop: $message');
    }
  }

  bool get isInitialized => _config != null;

  /// Initializes from the channel `init` map. Returns false (never throws)
  /// when the map has no usable apiKey.
  Future<bool> init(Map<String, dynamic> configMap) {
    return _serial(() async {
      final config = DesktopBackendConfig.fromChannelMap(configMap);
      if (config.apiKey.isEmpty) {
        _log(1, 'init refused: empty apiKey');
        return false;
      }
      _cancelTimers();
      _config = config;
      _offline = false;
      _failures = 0;
      _pendingCount = 0;
      _throttleUntilMs = 0;

      _storage = _injectedStorage ??
          SharedPreferencesDesktopStorage(
              namespace: 'storage-${config.apiKey}-${config.instanceName}');
      await _storage!.init();

      _identity = DesktopIdentity(storage: _storage!);
      await _identity!.load(
        apiKey: config.apiKey,
        seedDeviceId: config.seedDeviceId,
        initialUserId: config.initialUserId,
        initialOptOut: config.initialOptOut,
      );

      _session = DesktopSession(
        storage: _storage!,
        identity: _identity!,
        clock: _clock,
        sessionGapMs: config.sessionGapMs,
        trackSessionEvents: config.autocaptureSessions,
      );
      await _session!.restore();

      _interceptor = DesktopIdentifyInterceptor(
        storage: _storage!,
        identifyBatchIntervalMillis: config.identifyBatchIntervalMillis,
        clock: _clock,
        onTimerFired: _onIdentifyTimer,
        onWarn: (message) => _log(2, message),
      );
      await _interceptor!.restore();

      try {
        _osInfo = await _systemInfoSource.currentOs();
        _appInfo = await _appInfoSource.current();
      } catch (e) {
        _log(1, 'system info lookup failed, using fallbacks: $e');
      }
      _language = desktopLocaleTag();

      _flushTimer = Timer.periodic(
        Duration(milliseconds: config.flushIntervalMillis),
        (_) => _serial(_flushChain),
      );
      _log(3, 'initialized instance ${config.instanceName}');
      return true;
    });
  }

  void _onIdentifyTimer() {
    unawaited(_serial(() async {
      final combined = await _interceptor?.transfer();
      if (combined != null) {
        await _enqueueRaw(combined, holdable: false);
      }
    }));
  }

  void _cancelTimers() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _reprobeTimer?.cancel();
    _reprobeTimer = null;
    _interceptor?.dispose();
  }

  /// Releases timers and the owned HTTP client. Test/close hook — the
  /// queue stays on disk.
  Future<void> dispose() {
    return _serial(() async {
      _cancelTimers();
      _transport.close();
    });
  }

  // Identity reads resolve before init completes with null/-1 and never
  // hang (the Android `isBuilt` gate analog, plan §1.4).
  Future<String?> getUserId() async => _identity?.userId;
  Future<String?> getDeviceId() async => _identity?.deviceId;
  Future<int> getSessionId() async => _session?.sessionId ?? -1;

  Future<void> setUserId(String? userId) {
    return _serial(() async {
      await _identity?.setUserId(userId);
    });
  }

  Future<void> setDeviceId(String? deviceId) {
    return _serial(() async {
      await _identity?.setDeviceId(deviceId);
    });
  }

  Future<void> setOptOut(bool enabled) {
    return _serial(() async {
      await _identity?.setOptOut(enabled);
    });
  }

  /// Identity-only `reset()` (Swift `Amplitude.reset()` / Kotlin
  /// `doResetWithDeviceId` parity): rotates identity, nothing else.
  Future<void> reset() {
    return _serial(() async {
      await _identity?.reset();
      // Deliberate no-ops: the event queue, session, and held identify
      // batch survive `reset()` — neither native SDK touches them, so
      // queued events keep the previous identity and drain on the next
      // flush (the interceptor's identity-change path transfers the held
      // batch first). Same for `_failures`, `_offline`,
      // `_throttleUntilMs`, and `_pendingCount`: they describe the
      // transport and queue, not identity. Rotating the device id must not
      // mask a dead server, clear a 429 pause, or reset the flush
      // threshold count.
    });
  }

  Future<void> track(Map<String, dynamic> event) {
    return _serial(() => _enqueueRaw(Map<String, dynamic>.from(event)));
  }

  Future<void> identify(Map<String, dynamic> event) {
    return _serial(() => _enqueueRaw(Map<String, dynamic>.from(event)));
  }

  Future<void> groupIdentify(Map<String, dynamic> event) {
    return _serial(() => _enqueueRaw(Map<String, dynamic>.from(event)));
  }

  Future<void> setGroup(Map<String, dynamic> event) {
    return _serial(() => _enqueueRaw(Map<String, dynamic>.from(event)));
  }

  Future<void> revenue(Map<String, dynamic> event) {
    return _serial(() => _enqueueRaw(Map<String, dynamic>.from(event)));
  }

  /// Public flush: transfers held identifies first, then uploads (§F).
  /// Hosts call this on window close; the disk queue is the real delivery
  /// guarantee, flush-on-close is best-effort on top.
  Future<void> flush() {
    return _serial(_flushChain);
  }

  /// Window focus/visibility refinement of the foreground flag (plan §C.7).
  /// Pure-Dart `AppLifecycleListener` states are the floor; a host-wired
  /// window-manager listener refines it.
  void setForeground(bool foreground) {
    _foreground = foreground;
  }

  /// Enter-foreground: flag first, then the dummy start runs with
  /// prior-state `inForeground: false` (Swift `Amplitude.swift:514-531`).
  Future<void> onEnterForeground(int timestampMs) {
    return _serial(() async {
      _foreground = true;
      final result = await _session?.processEvent(
        {'event_type': 'session_start', 'timestamp': timestampMs},
        inForeground: false,
      );
      for (final preceding in result?.preceding ?? const []) {
        await _storeEvent(preceding);
      }
    });
  }

  /// Exit-foreground: stamps `lastEventTime` and flushes iff
  /// `flushEventsOnClose` — no end event (plan §C.5).
  Future<void> onExitForeground(int timestampMs) {
    return _serial(() async {
      _foreground = false;
      await _session?.noteExitForeground(timestampMs);
      if (_config?.flushEventsOnClose ?? true) {
        await _flushChain();
      }
    });
  }

  // Enqueue path: translate -> identity fill -> session -> identify batching
  // -> enrich -> durable append. `holdable: false` re-enters combined
  // identifies and timer drains without re-holding.
  Future<void> _enqueueRaw(
    Map<String, dynamic> event, {
    bool holdable = true,
  }) async {
    final config = _config;
    final identity = _identity;
    final session = _session;
    final interceptor = _interceptor;
    if (config == null || identity == null || session == null) {
      return;
    }
    // `optOut == true` drops synchronously: nothing is enqueued.
    if (identity.optOut) {
      return;
    }
    Map<String, dynamic> translated;
    try {
      translated = translateDesktopEvent(event);
    } catch (_) {
      // Hostile input must never reject the caller's track() future.
      _log(1, 'dropping untranslatable event');
      return;
    }
    // Identity fills here (not in enrich) so identify-batching sees the
    // real ids for its change detection.
    if (translated['user_id'] == null && identity.userId != null) {
      translated['user_id'] = identity.userId;
    }
    if (translated['device_id'] == null && identity.deviceId != null) {
      translated['device_id'] = identity.deviceId;
    }
    DesktopSessionResult result;
    try {
      result = await session.processEvent(
        translated,
        inForeground: _foreground,
      );
    } catch (_) {
      // Hostile types (e.g. String timestamp) must not reject track().
      _log(1, 'dropping event with invalid session fields');
      return;
    }
    for (final preceding in result.preceding) {
      await _storeEvent(preceding);
    }
    final main = result.event;
    if (main == null) {
      return;
    }
    if (holdable && interceptor != null) {
      final intercept = await interceptor.process(main);
      // Transfers emit first via `holdable: false` so they gain
      // session/event ids (plan §F, Swift `pipeline.put`); the hold is
      // never silently dropped.
      for (final transfer in intercept.transfers) {
        await _enqueueRaw(transfer, holdable: false);
      }
      final toStore = intercept.event;
      if (toStore == null) {
        return;
      }
      await _storeEvent(toStore);
    } else {
      await _storeEvent(main);
    }
    _pendingCount += 1;
    // Transfer enqueues never auto-flush: the flush-time transfer runs
    // inside `_flushChain`, and recursing into a second chain there would
    // let the outer loop keep uploading after the inner chain trips
    // offline. Host-event enqueues (holdable) still flush on threshold.
    if (holdable && _pendingCount >= config.flushQueueSize) {
      _pendingCount = 0;
      await _flushChain();
    }
  }

  Future<void> _storeEvent(Map<String, dynamic> event) async {
    final config = _config;
    final identity = _identity;
    final storage = _storage;
    if (config == null || identity == null || storage == null) {
      return;
    }
    late final Map<String, dynamic> enriched;
    try {
      enriched = enrichDesktopEvent(
        event: event,
        tracking: config.trackingOptions,
        coppa: config.enableCoppaControl,
        os: _osInfo,
        app: _appInfo,
        library: desktopLibrary(),
        identityUserId: identity.userId,
        identityDeviceId: identity.deviceId,
        configPartnerId: config.partnerId,
        configAppVersion: config.appVersion,
        language: _language,
      );
    } catch (_) {
      // Hostile input must never reject the caller's track() future.
      _log(1, 'dropping unenrichable event');
      return;
    }
    enriched['insert_id'] ??= generateDesktopUuid();
    late final String line;
    try {
      line = json.encode(stripDesktopNulls(enriched));
    } catch (_) {
      // Non-encodable values (e.g. a DateTime surviving the channel codec)
      // must drop the event, not reject track().
      _log(1, 'dropping non-encodable event');
      return;
    }
    try {
      await storage.appendEvent(line);
    } catch (_) {
      _log(1, 'dropping event the queue refused');
    }
  }

  void _fireTerminal(Map<String, dynamic> event, int code, String message) {
    final callback = onTerminalEvent;
    if (callback != null) {
      try {
        callback(event, code, message);
      } catch (e) {
        _log(1, 'terminal callback threw: $e');
      }
    }
  }

  // Upload chain: oldest-file-first, sequentially (Swift `currentUpload`
  // guard + `sendNextEventFile`). Every send path settles exactly once.
  Future<void> _flushChain() => _flushChainInner(singleAttempt: false);

  Future<void> _flushChainInner({required bool singleAttempt}) async {
    final config = _config;
    final storage = _storage;
    final identity = _identity;
    if (config == null || storage == null || identity == null) {
      return;
    }
    if (identity.optOut) {
      return;
    }
    final now = _clock();
    if (!singleAttempt) {
      if (_offline || now < _throttleUntilMs) {
        return;
      }
    } else if (!_offline) {
      _cancelReprobe();
      return;
    }

    await _discardExpired(now);

    // Explicit flush transfers held identifies first.
    final combined = await _interceptor?.transfer();
    if (combined != null) {
      await _enqueueRaw(combined, holdable: false);
      // Transfer enqueues never recurse into a nested chain (see
      // `_enqueueRaw`), but re-check transport state anyway before
      // touching the network.
      if (_offline || _clock() < _throttleUntilMs) {
        return;
      }
    }
    await storage.sealCurrentFile();
    _pendingCount = 0;

    var files = await storage.listFilesOldestFirst();
    final skip = <String>{};
    var index = 0;
    while (index < files.length) {
      final name = files[index];
      index += 1;
      if (skip.contains(name)) {
        continue;
      }
      final raw = await storage.readFile(name);
      if (raw == null) {
        // Listed but unreadable: in the v1 single-writer design this is
        // corruption by definition (plan §B.3) — quarantine so it can
        // never wedge the queue.
        _log(2, 'quarantining unreadable queue file $name');
        await storage.quarantineFile(name);
        skip.add(name);
        continue;
      }
      late final List<Map<String, dynamic>> events;
      try {
        events = splitDesktopFileContent(raw)
            .map((line) => Map<String, dynamic>.from(json.decode(line) as Map))
            .toList();
      } catch (_) {
        // One corrupt file must never wedge the queue.
        _log(2, 'quarantining unreadable queue file $name');
        await storage.quarantineFile(name);
        skip.add(name);
        continue;
      }
      if (events.isEmpty) {
        await storage.removeFile(name);
        continue;
      }
      final endpoint = deriveDesktopEndpoint(
        serverUrl: config.serverUrl,
        zone: config.serverZone,
        useBatch: config.useBatch,
      );
      final result = await _transport.upload(
        endpoint: endpoint,
        apiKey: config.apiKey,
        events: events,
        minIdLength: config.minIdLength,
        nowMs: _clock(),
      );
      if (result.transportFailed) {
        _failures += 1;
        if (_failures > config.flushMaxRetries) {
          _tripOffline();
          return;
        }
        await _sleeper(_backoffFor(_failures));
        if (singleAttempt) {
          return;
        }
        continue;
      }
      final decision = decideDesktopDispatch(
        statusCode: result.statusCode,
        responseBody: result.body,
        events: events,
      );
      if (decision is DispatchSuccess) {
        await storage.removeFile(name);
        _noteProgress();
        for (final event in events) {
          _fireTerminal(event, 200, 'Event uploaded');
        }
      } else if (decision is DispatchDropFile) {
        await storage.removeFile(name);
        _noteProgress();
        for (final event in events) {
          _fireTerminal(event, decision.code, decision.message);
        }
      } else if (decision is DispatchDropSome) {
        final parts = partitionDesktopEvents(events, decision);
        for (final event in parts.drop) {
          _fireTerminal(event, decision.code, decision.message);
        }
        if (parts.keep.isEmpty) {
          await storage.removeFile(name);
        } else {
          await storage.writeFile(name,
              joinDesktopFileContent(parts.keep.map(json.encode).toList()));
        }
        if (decision.throttle) {
          _throttleUntilMs = _clock() + DesktopRetry.throttleSeconds * 1000;
          _log(2, 'server throttled uploads; pausing for 30 s');
          return;
        }
        _noteProgress();
      } else if (decision is DispatchSplit) {
        final halves = await storage.splitFile(name);
        files = [
          ...files.sublist(0, index - 1),
          ...halves,
          ...files.sublist(index),
        ];
        index -= 1;
        continue;
      } else {
        // DispatchRetry.
        _failures += 1;
        if (_failures > config.flushMaxRetries) {
          _tripOffline();
          return;
        }
        await _sleeper(_backoffFor(_failures));
      }
      if (singleAttempt) {
        return;
      }
    }
  }

  // A final response for this file: reset backoff, and heal offline state.
  void _noteProgress() {
    _failures = 0;
    if (_offline) {
      _offline = false;
      _cancelReprobe();
      _log(3, 'upload recovered; leaving offline state');
    }
  }

  // Backoff between files: `min(60s, 2^(failures-1))`.
  Duration _backoffFor(int failures) {
    var seconds = 1 << (failures - 1);
    if (seconds > DesktopRetry.maxBackoffSeconds) {
      seconds = DesktopRetry.maxBackoffSeconds;
    }
    return Duration(seconds: seconds);
  }

  // Attempts-exhausted: stop the chain, go offline, and keep the files.
  // User-silent by decision (diagnostic log only, no callback yet).
  void _tripOffline() {
    _offline = true;
    _log(
        2,
        'upload failures exceeded flushMaxRetries; '
        'pausing uploads until the next probe');
    _reprobeTimer?.cancel();
    _reprobeTimer = Timer.periodic(_reprobeInterval, (_) {
      unawaited(_serial(() => _flushChainInner(singleAttempt: true)));
    });
  }

  void _cancelReprobe() {
    _reprobeTimer?.cancel();
    _reprobeTimer = null;
  }

  // Backstop: files older than 30 days are discarded, firing the config
  // callback at discard time — the only point data loss becomes explicit.
  // A null creation time means a corrupt envelope (§B.3): quarantine so it
  // can never wedge the queue.
  Future<void> _discardExpired(int nowMs) async {
    final storage = _storage;
    if (storage == null) {
      return;
    }
    final cutoff = nowMs - DesktopRetry.maxFileAgeDays * 24 * 3600 * 1000;
    for (final name in await storage.listFilesOldestFirst()) {
      final createdAt = await storage.fileCreatedAt(name);
      if (createdAt == null) {
        _log(2, 'quarantining unreadable queue file $name');
        await storage.quarantineFile(name);
        continue;
      }
      if (createdAt > cutoff) {
        continue;
      }
      final raw = await storage.readFile(name);
      await storage.removeFile(name);
      _log(2, 'discarding 30-day-old queue file $name');
      if (raw != null) {
        try {
          for (final line in splitDesktopFileContent(raw)) {
            _fireTerminal(
              Map<String, dynamic>.from(json.decode(line) as Map),
              500,
              'Dropped after 30 days in the offline queue',
            );
          }
        } catch (_) {
          // Unparseable and ancient: already removed, nothing to report.
        }
      }
    }
  }
}
