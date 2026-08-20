import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'my_app.dart';

void main() {
  const apiKey = String.fromEnvironment('AMPLITUDE_API_KEY');

  // On Flutter web with the default CanvasKit renderer, the Amplitude Browser
  // SDK's DOM-based autocapture (elementInteractions / formInteractions /
  // fileDownloads) can only observe Flutter's accessibility semantics tree.
  // That tree is off until something enables it, so enable it here to
  // demonstrate web click/form capture. Enabling semantics app-wide has a
  // runtime cost and known side effects, so only do this if you actually want
  // DOM-based web capture.
  if (kIsWeb) {
    WidgetsFlutterBinding.ensureInitialized();
    SemanticsBinding.instance.ensureSemantics();
  }

  if (apiKey.isEmpty) {
    runApp(const _MissingApiKeyApp());
    return;
  }

  runApp(const MyApp(apiKey));
}

class _MissingApiKeyApp extends StatelessWidget {
  const _MissingApiKeyApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Amplitude test API key required',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                Text(
                  'Run the example with:',
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                SelectableText(
                  'flutter run -d <device> '
                  '--dart-define=AMPLITUDE_API_KEY=<test-project-key>',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
