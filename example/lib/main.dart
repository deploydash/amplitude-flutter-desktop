import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'my_app.dart';
import 'url_strategy_stub.dart'
    if (dart.library.js_interop) 'url_strategy_web.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Path URLs (`/downloads`) instead of the default hash URLs (`/#/downloads`).
  // Must run before runApp so the initial route is parsed with this strategy.
  // No-op off the web. See lib/url_strategy_web.dart for the server-rewrite
  // requirement that comes with path URLs.
  configureUrlStrategy();
  // On web, the Browser SDK's DOM-based autocapture (elementInteractions,
  // formInteractions, fileDownloads) can only observe real DOM elements. With
  // the default CanvasKit renderer the UI is painted to a canvas, so the
  // semantics tree is what renders interactive widgets as real DOM nodes
  // (text fields become <input>s — NOT wrapped in a <form>, which is why form
  // interactions cannot be captured — and buttons become role="button"
  // elements).
  //
  // NOTE: this enables semantics at the *framework* level only. On Flutter
  // 3.29.2 the web *engine* keeps its DOM semantics tree gated until its
  // injected "Enable accessibility" placeholder is activated, so DOM-based
  // autocapture may still see nothing. The Downloads lab has a banner showing
  // the real state plus a button to turn it on.
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();
  }
  runApp(const MyApp('API_KEY'));
}
