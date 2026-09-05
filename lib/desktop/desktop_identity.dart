import 'desktop_storage.dart';
import 'desktop_uuid.dart';

// Device/user identity lifecycle for one backend instance (plan §B.4).
//
// WHY a separate object: identity rules (seed-once, apiKey-change wipe,
// reset rotation) must hold identically whether the values are touched via
// `setUserId`, `identify` options, or session-event filling — so they live
// here, not scattered across call sites.
class DesktopIdentity {
  DesktopIdentity({required DesktopStorage storage}) : _storage = storage;

  final DesktopStorage _storage;

  String? _deviceId;
  String? _userId;
  bool _optOut = false;
  bool _loaded = false;

  String? get deviceId => _deviceId;
  String? get userId => _userId;
  bool get optOut => _optOut;

  /// Restores persisted identity. When the configured [apiKey] differs from
  /// the stored one, wipes the whole store first so switching projects can
  /// never leak one project's identity into another's (Kotlin
  /// `FileIdentityStorage` safety check).
  Future<void> load({
    required String apiKey,
    String? seedDeviceId,
    String? initialUserId,
    bool initialOptOut = false,
  }) async {
    final storedApiKey =
        await _storage.readString(DesktopStoreKeys.storedApiKey);
    if (storedApiKey != null && storedApiKey != apiKey) {
      await _storage.clearAll();
    }
    await _storage.writeString(DesktopStoreKeys.storedApiKey, apiKey);

    _deviceId = await _storage.readString(DesktopStoreKeys.deviceId);
    if (_deviceId == null) {
      _deviceId = seedDeviceId ?? generateDesktopUuid();
      await _storage.writeString(DesktopStoreKeys.deviceId, _deviceId!);
    }
    _userId =
        await _storage.readString(DesktopStoreKeys.userId) ?? initialUserId;
    if (_userId != null) {
      await _storage.writeString(DesktopStoreKeys.userId, _userId!);
    }
    // Current configuration owns opt-out (upstream parity): a newly supplied
    // `true` must suppress tracking immediately and can never be defeated by
    // an older stored `false`. The stored key is legacy migration only — it
    // is deleted here so a future regression cannot read it.
    _optOut = initialOptOut;
    await _storage.deleteKey(DesktopStoreKeys.optOut);
    _loaded = true;
  }

  void _requireLoaded() {
    assert(_loaded, 'DesktopIdentity.load() must be awaited first');
  }

  /// Persists a new user id immediately (may be null to clear).
  Future<void> setUserId(String? userId) async {
    _requireLoaded();
    _userId = userId;
    if (userId == null) {
      await _storage.deleteKey(DesktopStoreKeys.userId);
    } else {
      await _storage.writeString(DesktopStoreKeys.userId, userId);
    }
  }

  /// Persists a new device id immediately (may be null to clear).
  Future<void> setDeviceId(String? deviceId) async {
    _requireLoaded();
    _deviceId = deviceId;
    if (deviceId == null) {
      await _storage.deleteKey(DesktopStoreKeys.deviceId);
    } else {
      await _storage.writeString(DesktopStoreKeys.deviceId, deviceId);
    }
  }

  /// Updates the in-memory opt-out policy only. Mechanism only — who sets
  /// it is host policy (plan §B.5). Upstream parity: configuration owns the
  /// value, so it is not persisted across launches; the host supplies its
  /// consent-derived configuration on every startup.
  Future<void> setOptOut(bool optOut) async {
    _requireLoaded();
    _optOut = optOut;
  }

  /// Identity-only `reset()` (Swift `Amplitude.reset()` / Kotlin
  /// `doResetWithDeviceId` parity): clears the user id and rotates the
  /// device id. The event queue, session, held identify batch, opt-out flag,
  /// and stored apiKey all survive — queued events keep the previous
  /// identity and drain on the next flush.
  Future<void> reset() async {
    _requireLoaded();
    _userId = null;
    await _storage.deleteKey(DesktopStoreKeys.userId);
    _deviceId = generateDesktopUuid();
    await _storage.writeString(DesktopStoreKeys.deviceId, _deviceId!);
  }
}
