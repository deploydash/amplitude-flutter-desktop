import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'download_launcher_stub.dart'
    if (dart.library.js_interop) 'download_launcher_web.dart';

/// File-download autocapture playground (web only).
///
/// The Browser SDK's `fileDownloads` tracking attaches a click listener to DOM
/// anchors whose href has a downloadable extension. Flutter widgets are painted
/// to a canvas, so an anchor has to come from somewhere.
///
/// **The only genuine autocapture route is `Semantics(link: true, linkUrl: ...)`**
/// (section 1). Flutter renders a link-flagged semantics node as a real
/// `<a href="...">`; that anchor receives the user's click, performs the
/// download natively, and is what the Browser SDK captures — no JS interop and
/// no Dart tap handler required.
///
/// It works **only while the semantics tree is enabled** (screen reader
/// detected, the hidden placeholder activated, or
/// `SemanticsBinding.instance.ensureSemantics()` — see `main.dart`, which did
/// not reliably take effect on a cold load in testing). With semantics off no
/// anchor exists and nothing fires.
///
/// Section 2 is a **synthetic control**, not a pattern to copy: it fabricates an
/// anchor via JS interop purely to isolate SDK-plugin failures from
/// Flutter-emitted-no-DOM failures.
///
/// Caveat: `Semantics` cannot set the anchor's `download` attribute, so the
/// browser may navigate to / preview the file instead of saving it.
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
            Text('1. Real autocapture: Semantics link (no interop)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Semantics(
              link: true,
              linkUrl: Uri.parse('sample.pdf'),
              child: InkWell(
                // Deliberately a no-op: the DOM <a> that Flutter renders for
                // this link-flagged node receives the real click and performs
                // the download itself, and it is that anchor click the Browser
                // SDK captures. Calling a JS-interop helper here would fire a
                // second, synthetic anchor click and make it impossible to tell
                // which path produced the event. If semantics is disabled this
                // control does nothing at all — that is the honest behavior.
                onTap: () {},
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
            const Divider(),
            Text('2. Synthetic control — NOT autocapture',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Text(
              'Creates and clicks a DOM anchor via JS interop. No customer '
              'would write this; it exists only to isolate a failure — if this '
              'fires but the link above does not, the Browser SDK plugin is '
              'fine and the problem is that Flutter emitted no anchor (usually '
              'semantics being off).',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              child: const Text('Download sample.pdf (synthetic)'),
              onPressed: launchTestDownload,
            ),
          ],
        ),
      ),
    );
  }
}
