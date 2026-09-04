import 'dart:math';

// Generates an RFC 4122 version-4 UUID.
//
// WHY a hand-rolled helper instead of the `uuid` package: the fork only
// accepts dependencies from the plan allowlist, and 16 random bytes plus a
// few bit-twiddles are not worth a new dependency. Used for `device_id`
// seeding and per-event `insert_id` (native `mergeContext` behavior).
String generateDesktopUuid([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Set the version (4) and variant (RFC 4122) bits.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
