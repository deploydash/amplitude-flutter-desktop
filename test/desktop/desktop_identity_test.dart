import 'package:amplitude_flutter/desktop/desktop_identity.dart';
import 'package:amplitude_flutter/desktop/desktop_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopIdentity', () {
    late InMemoryDesktopStorage storage;

    setUp(() async {
      storage = InMemoryDesktopStorage();
      await storage.init();
    });

    Future<DesktopIdentity> load({
      String apiKey = 'key-1',
      String? seedDeviceId,
      String? initialUserId,
      bool initialOptOut = false,
    }) async {
      final identity = DesktopIdentity(storage: storage);
      await identity.load(
        apiKey: apiKey,
        seedDeviceId: seedDeviceId,
        initialUserId: initialUserId,
        initialOptOut: initialOptOut,
      );
      return identity;
    }

    test('seeds a fresh device id and persists it', () async {
      final identity = await load(seedDeviceId: 'seed-1');
      expect(identity.deviceId, 'seed-1');
      expect(await storage.readString(DesktopStoreKeys.deviceId), 'seed-1');

      // A second load (simulated restart) restores the stored id, and the
      // seed is ignored once an id exists.
      final reloaded = await load(seedDeviceId: 'other-seed');
      expect(reloaded.deviceId, 'seed-1');
    });

    test('generates a UUID when no seed or stored id exists', () async {
      final identity = await load();
      expect(identity.deviceId, isNotNull);
      expect(
        identity.deviceId!.split('-'),
        hasLength(5),
        reason: 'device_id must be a UUID',
      );
    });

    test('setUserId and setDeviceId persist immediately', () async {
      final identity = await load();
      await identity.setUserId('user-9');
      await identity.setDeviceId('device-9');
      expect(await storage.readString(DesktopStoreKeys.userId), 'user-9');
      expect(await storage.readString(DesktopStoreKeys.deviceId), 'device-9');

      await identity.setUserId(null);
      expect(await storage.readString(DesktopStoreKeys.userId), isNull);

      await identity.setDeviceId(null);
      expect(identity.deviceId, isNull);
      expect(await storage.readString(DesktopStoreKeys.deviceId), isNull);
    });

    test('initial userId from init is persisted, not just held', () async {
      final identity = await load(initialUserId: 'init-user');
      expect(identity.userId, 'init-user');
      expect(
        await storage.readString(DesktopStoreKeys.userId),
        'init-user',
        reason: 'a restart must restore the init-provided user, not null',
      );
    });

    test('apiKey change wipes stored identity and queue', () async {
      final first = await load(apiKey: 'key-1');
      final oldDeviceId = first.deviceId;
      await first.setUserId('user-1');
      await first.setOptOut(false);
      await storage.appendEvent('{"event_type":"queued"}');
      await storage.sealCurrentFile();

      final second = await load(apiKey: 'key-2');
      expect(second.deviceId, isNot(oldDeviceId),
          reason: 'key change must not leak the old install identity');
      expect(second.userId, isNull);
      expect(await storage.listFilesOldestFirst(), isEmpty,
          reason: 'key change must not leak the old queue');
      expect(await storage.readString(DesktopStoreKeys.storedApiKey), 'key-2');
    });

    test('reset rotates device id, clears user, and leaves the queue',
        () async {
      final identity = await load();
      final oldDeviceId = identity.deviceId;
      await identity.setUserId('user-1');
      await identity.setOptOut(true);
      await storage.appendEvent('{"event_type":"queued"}');
      await storage.sealCurrentFile();

      await identity.reset();

      expect(identity.deviceId, isNot(oldDeviceId));
      expect(identity.userId, isNull);
      // Swift `Amplitude.reset()` / Kotlin `doResetWithDeviceId` parity:
      // queued events keep the previous identity and still drain.
      expect(await storage.listFilesOldestFirst(), hasLength(1));
      // Opt-out is host policy, not analytics identity: reset keeps the
      // in-memory value but never persists it.
      expect(identity.optOut, isTrue);
      expect(await storage.readBool(DesktopStoreKeys.optOut), isNull);
    });

    test('opt-out is config-owned, not restored across loads', () async {
      final identity = await load(initialOptOut: true);
      expect(identity.optOut, isTrue);

      final reloaded = await load();
      expect(reloaded.optOut, isFalse,
          reason: 'host must supply consent config on every startup');

      await reloaded.setOptOut(true);
      expect((await load()).optOut, isFalse,
          reason: 'setOptOut is in-memory only');
    });

    test('current true dominates stored false and clears legacy key',
        () async {
      await storage.writeBool(DesktopStoreKeys.optOut, false);
      final identity = await load(initialOptOut: true);
      expect(identity.optOut, isTrue);
      expect(await storage.readBool(DesktopStoreKeys.optOut), isNull);
    });

    test('current false dominates stored true and clears legacy key',
        () async {
      await storage.writeBool(DesktopStoreKeys.optOut, true);
      final identity = await load(initialOptOut: false);
      expect(identity.optOut, isFalse);
      expect(await storage.readBool(DesktopStoreKeys.optOut), isNull);
    });

    test('initialization truth table owns opt-out, storage never wins',
        () async {
      final storedValues = <bool?>[null, false, true];
      for (final stored in storedValues) {
        for (final configured in [false, true]) {
          storage = InMemoryDesktopStorage();
          await storage.init();
          if (stored != null) {
            await storage.writeBool(DesktopStoreKeys.optOut, stored);
          }
          final identity = await load(initialOptOut: configured);
          expect(identity.optOut, configured,
              reason:
                  'stored $stored with configured $configured must be $configured');
          expect(await storage.readBool(DesktopStoreKeys.optOut), isNull,
              reason: 'legacy key must be removed for stored $stored');
        }
      }
    });

    test('setOptOut does not persist across restart', () async {
      final identity = await load(initialOptOut: false);
      await identity.setOptOut(true);
      expect(identity.optOut, isTrue);
      final reloaded = await load(initialOptOut: false);
      expect(reloaded.optOut, isFalse);
    });
  });
}
