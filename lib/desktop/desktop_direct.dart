import 'package:flutter/services.dart';

// In-process desktop routing for the public `Amplitude` API (web/mobile
// default: the engine channel owns every call).
//
// WHY this file exists: `amplitude.dart` is compiled for every platform
// including web, so it cannot import `dart:io` (directly or transitively).
// This default implementation keeps non-IO targets on the channel; the
// `dart.library.io` variant routes Linux/Windows to the in-process
// desktop backend. See `desktop_direct_io.dart`.
//
// Contract (both variants): resolve with the backend result on desktop,
// otherwise invoke [channel] exactly as before. No caller API changes.
Future<dynamic> invokeDesktopMethod(
  MethodChannel channel,
  String method,
  dynamic arguments,
) {
  return channel.invokeMethod(method, arguments);
}
