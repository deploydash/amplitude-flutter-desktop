import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'download_launcher_stub.dart'
    if (dart.library.js_interop) 'download_launcher_web.dart';

/// File-download autocapture playground (web only).
///
/// The Browser SDK's `fileDownloads` plugin fires `[Amplitude] File Downloaded`
/// when a **DOM anchor whose href ends in a downloadable extension** is clicked.
/// Two gates therefore decide every case below:
///
/// 1. **Is there a real `<a>` element, and does the click land on it?** Flutter
///    paints to a canvas, so the only interop-free source of an anchor is a
///    link-flagged semantics node — which exists only while the accessibility
///    semantics tree is enabled.
/// 2. **Does the href match the plugin's extension regex?**
///    `pdf|xlsx?|docx?|txt|rtf|csv|exe|key|pp(s|t|tx)|7z|pkg|rar|gz|zip|avi|mov|`
///    `mp4|mpe?g|wmv|midi?|mp3|wav|wma`, optionally followed by `?query`.
///
/// Each row states the expected outcome so a tester can diff reality against it.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.all(10.0),
        children: [
          if (kIsWeb)
            Text(
              'Enable the semantics tree first — Tab to the injected "Enable '
              'accessibility" button and press Enter, or click it. Without it, '
              'cases A–C emit nothing. Verify with '
              "document.querySelectorAll('flt-semantics').length > 0. Note "
              'SemanticsBinding.ensureSemantics() does NOT enable it on Flutter '
              '3.29.2.',
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            Text(
              'File-download autocapture is web-only. Every control below is a '
              'no-op on this platform; the screen still emits its '
              '[Amplitude] Screen Viewed event.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),

          // ---- Interop-free paths (what a customer would actually write) ----
          const _SectionHeader('Interop-free (real autocapture)'),

          _DownloadCase(
            id: 'A',
            title: 'Semantics link → sample.pdf',
            detail: 'Semantics(link: true, linkUrl: ...) renders a real '
                '<a href="sample.pdf">. The anchor takes the click and does the '
                'download itself; no Dart tap handler, no interop.',
            captured: true,
            requiresSemantics: true,
            child: _SemanticsLink(
              href: 'sample.pdf',
              label: 'A. Download sample.pdf',
            ),
          ),

          _DownloadCase(
            id: 'B',
            title: 'Semantics link → sample.pdf?v=2 (query string)',
            detail: 'Proves the extension regex tolerates a trailing query '
                'string, so cache-busted or signed URLs still capture.',
            captured: true,
            requiresSemantics: true,
            child: _SemanticsLink(
              href: 'sample.pdf?v=2',
              label: 'B. Download sample.pdf?v=2',
            ),
          ),

          _DownloadCase(
            id: 'C',
            title: 'Semantics link → notes.json (non-downloadable extension)',
            detail: 'An anchor exists and is clicked, but .json is not in the '
                "plugin's extension list, so it is ignored. Isolates the "
                'extension gate from the anchor gate. Navigates away — press '
                'Back to return.',
            captured: false,
            requiresSemantics: true,
            child: _SemanticsLink(
              href: 'notes.json',
              label: 'C. Open notes.json',
            ),
          ),

          _DownloadCase(
            id: 'D',
            title: 'Plain ElevatedButton (no DOM at all)',
            detail: 'What an ordinary Flutter app looks like: the tap never '
                'touches the DOM, so there is nothing for the plugin to '
                'observe. This is the default no-capture case.',
            captured: false,
            requiresSemantics: false,
            child: Builder(
              builder: (context) => ElevatedButton(
                child: const Text('D. Plain button (no anchor)'),
                onPressed: () =>
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content:
                      Text('Tapped — no DOM anchor involved, so no event.'),
                  duration: Duration(seconds: 2),
                )),
              ),
            ),
          ),

          _DownloadCase(
            id: 'E',
            title: 'window.open (what url_launcher does on web)',
            detail: 'Downloads/opens the file, but navigation via window.open '
                'dispatches no anchor click — so url_launcher-style downloads '
                'are never autocaptured.',
            captured: false,
            requiresSemantics: false,
            child: ElevatedButton(
              child: const Text('E. window.open(sample.pdf)'),
              onPressed: () => openWithWindowOpen('sample.pdf'),
            ),
          ),

          // ---- Synthetic controls: diagnostics, not patterns to copy ----
          const _SectionHeader('Synthetic controls — NOT autocapture'),
          Text(
            'These fabricate a DOM anchor via JS interop. No customer should '
            'write this; they exist to isolate a failure — if these fire but '
            'A/B do not, the Browser SDK plugin is fine and the problem is that '
            'Flutter emitted no anchor (usually semantics being off).',
            style: Theme.of(context).textTheme.bodySmall,
          ),

          _DownloadCase(
            id: 'F',
            title: 'Interop anchor → sample.pdf',
            detail: 'Semantics-independent: works even with the semantics tree '
                'disabled, because the app supplies the anchor itself.',
            captured: true,
            requiresSemantics: false,
            child: ElevatedButton(
              child: const Text('F. Interop anchor'),
              onPressed: () => clickSyntheticAnchor(
                id: 'amp-testbed-anchor-plain',
                href: 'sample.pdf',
                newTab: true,
              ),
            ),
          ),

          _DownloadCase(
            id: 'G',
            title: 'Interop anchor + download attribute',
            detail: 'Identical capture to F — the `download` attribute only '
                'changes save-vs-preview behavior, it is not part of the '
                'matching rule. Worth knowing because Semantics(link:) cannot '
                'set it.',
            captured: true,
            requiresSemantics: false,
            child: ElevatedButton(
              child: const Text('G. Interop anchor (download attr)'),
              onPressed: () => clickSyntheticAnchor(
                id: 'amp-testbed-anchor-download',
                href: 'sample.pdf',
                withDownloadAttr: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Text(text, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// One download mode: what it is, whether autocapture should record it, and the
/// control that triggers it.
class _DownloadCase extends StatelessWidget {
  const _DownloadCase({
    required this.id,
    required this.title,
    required this.detail,
    required this.captured,
    required this.requiresSemantics,
    required this.child,
  });

  final String id;
  final String title;
  final String detail;

  /// Whether `[Amplitude] File Downloaded` is expected for this mode.
  final bool captured;

  /// Whether the expectation is conditional on the semantics tree being on.
  final bool requiresSemantics;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final expectation = captured
        ? 'EXPECT [Amplitude] File Downloaded'
            '${requiresSemantics ? ' (only with semantics enabled)' : ''}'
        : 'EXPECT no event';
    final color = captured ? Colors.green.shade800 : Colors.red.shade800;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$id. $title',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(expectation,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// A link-flagged semantics node — the interop-free way to put a real
/// `<a href="...">` in the DOM. [InkWell.onTap] is deliberately a no-op so the
/// only thing that can produce an event is the anchor's own click.
class _SemanticsLink extends StatelessWidget {
  const _SemanticsLink({required this.href, required this.label});

  final String href;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      linkUrl: Uri.parse(href),
      child: InkWell(
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline),
          ),
        ),
      ),
    );
  }
}
