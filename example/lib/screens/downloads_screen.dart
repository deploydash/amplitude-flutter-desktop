import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'download_launcher_stub.dart'
    if (dart.library.js_interop) 'download_launcher_web.dart';

/// File-download autocapture playground (web only).
///
/// The Browser SDK's `fileDownloads` tracking attaches a click listener to DOM
/// anchors whose href has a downloadable extension. Flutter widgets are painted
/// to a canvas, so an anchor has to come from somewhere. This screen offers both
/// routes:
///
/// 1. **JS interop (primary, always works).** Creates a persistent
///    `<a href="sample.pdf" download>` and clicks it programmatically. Works
///    whether or not the accessibility semantics tree is enabled.
/// 2. **Pure-Flutter `Semantics(link:)` (requires semantics).** Flutter renders
///    a link-flagged semantics node as a real `<a href="...">`, so this needs no
///    JS interop — but **only while semantics is enabled**. If semantics is off
///    the node doesn't exist, the tap does nothing, and no event fires. Flutter
///    enables semantics when a screen reader is detected, when the user
///    activates the hidden placeholder button, or via
///    `SemanticsBinding.instance.ensureSemantics()` (see `main.dart`) — the last
///    of which did not reliably take effect on a cold load in testing, so treat
///    this path as conditional.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: ListView(
          children: [
            Text(
              kIsWeb
                  ? 'Two ways to reach [Amplitude] File Downloaded. The button '
                      'clicks a DOM anchor via JS interop and always works. The '
                      'link below is a Semantics(link:) node, which only exists '
                      '(and only captures) while the semantics tree is enabled.'
                  : 'File-download autocapture is web-only; on this platform '
                      'both controls are no-ops. This screen still emits its '
                      '[Amplitude] Screen Viewed event.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const Divider(),
            Text('1. DOM anchor via JS interop (always works)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            ElevatedButton(
              child: const Text('Download sample.pdf'),
              onPressed: launchTestDownload,
            ),
            const Divider(),
            Text('2. Pure-Flutter Semantics link (needs semantics enabled)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Semantics(
              link: true,
              linkUrl: Uri.parse('sample.pdf'),
              child: InkWell(
                // On web the semantics <a> performs the download itself; this
                // fallback keeps the control useful when semantics is off (and
                // on mobile), so a tap is never silently inert.
                onTap: launchTestDownload,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    'Download sample.pdf (semantics link)',
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
