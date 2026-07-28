import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// File-download autocapture playground (web only).
///
/// The Browser SDK's `fileDownloads` tracking attaches a click listener to DOM
/// anchors whose href has a downloadable extension. Flutter's accessibility
/// semantics tree renders a link-flagged node as a **real `<a href="...">`
/// element**, so no JS interop is needed: wrapping a widget in
/// `Semantics(link: true, linkUrl: ...)` is enough for
/// `[Amplitude] File Downloaded` to fire (verified live — the captured
/// `[Amplitude] Link ID` is the `flt-semantic-node-*` id).
///
/// Requires semantics to be enabled (see `main.dart`), which is also what makes
/// click and change capture work under CanvasKit.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              kIsWeb
                  ? 'The link below is a link-flagged Semantics node, which '
                      'Flutter renders as a real <a href="sample.pdf"> in the '
                      'semantics tree. Tapping it downloads the file and the '
                      'Browser SDK captures [Amplitude] File Downloaded.'
                  : 'File-download autocapture is web-only. On this platform '
                      'the link below does nothing; the screen still emits its '
                      '[Amplitude] Screen Viewed event.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            Semantics(
              link: true,
              linkUrl: Uri.parse('sample.pdf'),
              child: InkWell(
                // The DOM anchor itself performs the navigation/download on
                // web; this tap handler only exists so the widget is
                // interactive (and is a no-op on mobile).
                onTap: () {},
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    'Download sample.pdf',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
