// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_web_plugins/url_strategy.dart';

/// Switches Flutter web from the default hash URLs (`/#/downloads`) to path
/// URLs (`/downloads`).
///
/// See https://docs.flutter.dev/ui/navigation/url-strategies. Must be called
/// before `runApp` so the first route is read with the right strategy.
///
/// Note for whoever serves this build: path URLs require the server to rewrite
/// unknown paths to `index.html`, otherwise a reload or deep link to
/// `/downloads` 404s. `flutter run -d chrome` does this already; a plain static
/// file server does not.
void configureUrlStrategy() {
  usePathUrlStrategy();
}
