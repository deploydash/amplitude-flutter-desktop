import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'my_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // On web, the Browser SDK's DOM-based autocapture (elementInteractions,
  // formInteractions, fileDownloads) can only observe real DOM elements. With
  // the default CanvasKit renderer the UI is painted to a canvas, so enable
  // the semantics tree, which renders interactive widgets as real DOM nodes
  // (text fields become <input>s inside a <form>, buttons become
  // role="button" elements).
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();
  }
  runApp(const MyApp('API_KEY'));
}
