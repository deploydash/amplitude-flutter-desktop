import '../constants.dart';
import 'desktop_system_info.dart';

// Event shaping for the HTTP wire (plan §E).
//
// Dart `toMap()` keys already equal HTTP wire keys EXCEPT the translations
// in [translateDesktopEvent]. Context stamping in [enrichDesktopEvent]
// follows native precedence: the SDK always wins `library`; the host wins
// ids/plan/ingestion metadata when explicitly set; auto-context fields are
// stamped by the SDK whenever their tracking flag is on (a host that wants
// its own value to survive disables that flag, in which case host-set
// values pass through untouched).

/// `library` value stamped on every desktop event.
///
/// NOTE (documented divergence): the Recommended Approach sketches
/// `amplitude-flutter-desktop/<version>` so traffic splits server-side.
/// §E + pitfall #2 are normative instead — native `FlutterLibraryPlugin`
// unconditionally supersedes with `amplitude-flutter/<version>`, and
// attribution parity outranks traffic splitting. The `platform` field
// (`Linux`/`Windows`/`macOS`) already splits desktop traffic.
String desktopLibrary() =>
    '${Constants.packageName}/${Constants.packageVersion}';

/// Applies the §E translations to a channel-receipt event map.
///
/// - Strips `attempts` (pipeline bookkeeping) and `extra` (stripped before
///   send; Swift behavior unknown — follow TS, note the divergence).
/// - Rewrites camelCase `ingestion_metadata` to the snake_case wire shape.
/// - Coerces `location_lat`/`lng` to double (Swift `as? Double` silently
///   drops ints).
/// - Accepts String user/device ids, coerces num via `toString()`, drops
///   anything else. Never throws on types.
/// - Drops `app_set_id`/`android_id` unconditionally and silently: this
///   backend serves Linux/Windows/macOS only, where they are meaningless
///   (matches Swift `getEvent`, which drops both on iOS).
Map<String, dynamic> translateDesktopEvent(Map<String, dynamic> event) {
  final out = Map<String, dynamic>.from(event);
  out.remove('attempts');
  out.remove('extra');

  final ingestion = out['ingestion_metadata'];
  if (ingestion is Map) {
    final sourceName = ingestion['source_name'] ?? ingestion['sourceName'];
    final sourceVersion =
        ingestion['source_version'] ?? ingestion['sourceVersion'];
    if (sourceName == null && sourceVersion == null) {
      out.remove('ingestion_metadata');
    } else {
      out['ingestion_metadata'] = {
        if (sourceName != null) 'source_name': sourceName,
        if (sourceVersion != null) 'source_version': sourceVersion,
      };
    }
  }

  final plan = out['plan'];
  if (plan is Map) {
    final cleaned = <String, dynamic>{};
    for (final key in ['branch', 'source', 'version', 'versionId']) {
      if (plan[key] != null) {
        cleaned[key] = plan[key];
      }
    }
    if (cleaned.isEmpty) {
      out.remove('plan');
    } else {
      out['plan'] = cleaned;
    }
  }

  for (final key in ['location_lat', 'location_lng']) {
    final value = out[key];
    if (value == null) {
      continue;
    } else if (value is num) {
      out[key] = value.toDouble();
    } else {
      out.remove(key);
    }
  }

  for (final key in ['user_id', 'device_id']) {
    final value = out[key];
    if (value == null) {
      continue;
    } else if (value is String) {
      continue;
    } else if (value is num) {
      out[key] = value.toString();
    } else {
      out.remove(key);
    }
  }

  // Meaningless off Android; dropped with no logging.
  out.remove('app_set_id');
  out.remove('android_id');
  return out;
}

/// Stamps context onto a translated event.
///
/// [tracking] is the `trackingOptions` map; a missing key means tracked
/// (native default). [coppa] is `enableCoppaControl`: it force-drops
/// idfa/idfv/city/ip/latLng. [identityUserId]/[identityDeviceId] fill ids
/// the event lacks. [configPartnerId] stamps `partner_id` when the event
/// has none. [configAppVersion] wins over [app] for `app_version`.
Map<String, dynamic> enrichDesktopEvent({
  required Map<String, dynamic> event,
  required Map<String, bool> tracking,
  required bool coppa,
  required DesktopOsInfo os,
  required DesktopAppVersion app,
  required String library,
  String? identityUserId,
  String? identityDeviceId,
  String? configPartnerId,
  String? configAppVersion,
  String? language,
}) {
  final out = Map<String, dynamic>.from(event);
  bool tracked(String key) => tracking[key] ?? true;

  if (out['user_id'] == null && identityUserId != null) {
    out['user_id'] = identityUserId;
  }
  if (out['device_id'] == null && identityDeviceId != null) {
    out['device_id'] = identityDeviceId;
  }

  // SDK always wins (parity with FlutterLibraryPlugin).
  out['library'] = library;

  if (out['partner_id'] == null && configPartnerId != null) {
    out['partner_id'] = configPartnerId;
  }

  // Auto-context: SDK stamps its value when the flag is on and it has
  // one; an explicit host value survives when the SDK has nothing to
  // stamp (e.g. device-info lookup failed — native leaves it). Host
  // values also pass through untouched when the flag is off.
  void stamp(String key, String flag, String? sdkValue) {
    if (tracked(flag) && sdkValue != null) {
      out[key] = sdkValue;
    }
  }

  stamp('platform', 'platform', os.platform);
  stamp('os_name', 'osName', os.osName);
  stamp('os_version', 'osVersion', os.osVersion);
  stamp('device_model', 'deviceModel', os.deviceModel);
  stamp('device_manufacturer', 'deviceManufacturer', os.deviceManufacturer);
  stamp('language', 'language', language);
  // Swift parity: carrier is always reported as Unknown.
  stamp('carrier', 'carrier', 'Unknown');
  stamp('app_version', 'versionName', configAppVersion ?? app.appVersion);
  stamp('version_name', 'versionName', app.versionName);

  // IP: an explicit host value survives when tracking is on and COPPA is
  // off; otherwise it is removed (desktop privacy policy). With tracking on
  // and no explicit IP, set the `$remote` sentinel so Amplitude derives
  // IP/geolocation server-side (Swift `ContextPlugin` parity).
  if (!tracked('ipAddress') || coppa) {
    out.remove('ip');
  } else {
    out['ip'] ??= r'$remote';
  }

  // Location ids: never auto-collected on desktop. Explicit host values
  // survive when the (misnamed, Dart-serialized) `latLag` flag is on —
  // desktop reads the Dart key and applies the native meaning (§D).
  if (!tracked('latLag') || coppa) {
    out.remove('location_lat');
    out.remove('location_lng');
  }

  // Advertising/vendor ids: never auto-collected. Explicit values survive
  // behind their flags (`idfa` has no flag — it passes unless COPPA).
  if (!tracked('adid')) {
    out.remove('adid');
  }
  if (!tracked('idfv') || coppa) {
    out.remove('idfv');
  }
  if (coppa) {
    out.remove('idfa');
    out.remove('city');
  }
  return out;
}
