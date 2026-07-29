import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// ignore_for_file: depend_on_referenced_packages
import 'package:amplitude_flutter/events/base_event.dart';

import '../app_state.dart';
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
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _semanticsLive = false;
  String _lastAction = 'none yet';

  @override
  void initState() {
    super.initState();
    _refreshSemantics();
  }

  void _refreshSemantics() {
    setState(() => _semanticsLive = kIsWeb && isSemanticsTreeLive());
  }

  void _enableSemantics() {
    final activated = enableSemanticsTree();
    // The engine builds the tree on the next frame, so re-read after it lands.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSemantics());
    setState(() => _lastAction = activated
        ? 'clicked the accessibility placeholder'
        : 'placeholder absent (semantics already on, or not web)');
  }

  void _note(String action) => setState(() => _lastAction = action);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.all(10.0),
        children: [
          if (kIsWeb) ...[
            _SemanticsBanner(
              live: _semanticsLive,
              onEnable: _enableSemantics,
              onRecheck: _refreshSemantics,
            ),
            const SizedBox(height: 8),
            Text('Last local action: $_lastAction',
                style: Theme.of(context).textTheme.bodySmall),
          ] else
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
            mode: 'Semantics(link:) -> sample.pdf',
            title: 'Semantics link → sample.pdf',
            detail: 'Semantics(link: true, linkUrl: ...) renders a real '
                '<a href="sample.pdf">. The anchor takes the click and does the '
                'download itself; no Dart tap handler, no interop.',
            captured: true,
            requiresSemantics: true,
            child: _SemanticsLink(
              href: 'sample.pdf',
              label: 'A. Download sample.pdf',
              onTapped: () => _note('A tapped'),
            ),
          ),

          _DownloadCase(
            id: 'B',
            mode: 'Semantics(link:) -> sample.pdf?v=2',
            title: 'Semantics link → sample.pdf?v=2 (query string)',
            detail: 'Proves the extension regex tolerates a trailing query '
                'string, so cache-busted or signed URLs still capture.',
            captured: true,
            requiresSemantics: true,
            child: _SemanticsLink(
              href: 'sample.pdf?v=2',
              label: 'B. Download sample.pdf?v=2',
              onTapped: () => _note('B tapped'),
            ),
          ),

          _DownloadCase(
            id: 'C',
            mode: 'Semantics(link:) -> notes.json',
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
              onTapped: () => _note('C tapped'),
            ),
          ),

          _DownloadCase(
            id: 'D',
            mode: 'plain ElevatedButton, no DOM',
            title: 'Plain ElevatedButton (no DOM at all)',
            detail: 'What an ordinary Flutter app looks like: the tap never '
                'touches the DOM, so there is nothing for the plugin to '
                'observe. This is the default no-capture case.',
            captured: false,
            requiresSemantics: false,
            child: ElevatedButton(
              child: const Text('D. Plain button (no anchor)'),
              onPressed: () => _note('D tapped — no DOM touched, so no event'),
            ),
          ),

          _DownloadCase(
            id: 'E',
            mode: 'window.open(sample.pdf)',
            title: 'window.open (what url_launcher does on web)',
            detail: 'Downloads/opens the file, but navigation via window.open '
                'dispatches no anchor click — so url_launcher-style downloads '
                'are never autocaptured.',
            captured: false,
            requiresSemantics: false,
            child: ElevatedButton(
              child: const Text('E. window.open(sample.pdf)'),
              onPressed: () {
                openWithWindowOpen('sample.pdf');
                _note('E tapped — window.open, no anchor click');
              },
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
            mode: 'JS-interop anchor -> sample.pdf',
            title: 'Interop anchor → sample.pdf',
            detail: 'Semantics-independent: works even with the semantics tree '
                'disabled, because the app supplies the anchor itself.',
            captured: true,
            requiresSemantics: false,
            child: ElevatedButton(
              child: const Text('F. Interop anchor'),
              onPressed: () {
                clickSyntheticAnchor(
                  id: 'amp-testbed-anchor-plain',
                  href: 'sample.pdf',
                  newTab: true,
                );
                _note('F tapped — synthetic anchor clicked');
              },
            ),
          ),

          _DownloadCase(
            id: 'G',
            mode: 'JS-interop anchor + download attr -> sample.pdf',
            title: 'Interop anchor + download attribute',
            detail: 'Identical capture to F — the `download` attribute only '
                'changes save-vs-preview behavior, it is not part of the '
                'matching rule. Worth knowing because Semantics(link:) cannot '
                'set it.',
            captured: true,
            requiresSemantics: false,
            child: ElevatedButton(
              child: const Text('G. Interop anchor (download attr)'),
              onPressed: () {
                clickSyntheticAnchor(
                  id: 'amp-testbed-anchor-download',
                  href: 'sample.pdf',
                  withDownloadAttr: true,
                );
                _note('G tapped — synthetic anchor + download attr');
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows whether Flutter is emitting a DOM semantics tree — the real gate for
/// every DOM-based autocapture feature — and lets the tester turn it on.
///
/// Reads the DOM rather than `SemanticsBinding.semanticsEnabled`, which reports
/// `true` while the web engine is still gated (verified on Flutter 3.29.2).
class _SemanticsBanner extends StatelessWidget {
  const _SemanticsBanner({
    required this.live,
    required this.onEnable,
    required this.onRecheck,
  });

  final bool live;
  final VoidCallback onEnable;
  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final color = live ? Colors.green.shade800 : Colors.red.shade800;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            live ? 'Semantics tree: LIVE' : 'Semantics tree: OFF',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: color, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            live
                ? 'Flutter is emitting DOM nodes, so cases A–C can capture.'
                : 'No DOM nodes exist, so cases A–C are inert — they cannot '
                    'emit anything (F/G still work; they build their own '
                    'anchor). SemanticsBinding.ensureSemantics() does not fix '
                    'this on Flutter 3.29.2; the engine only enables semantics '
                    'when its injected placeholder is activated.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton(
                onPressed: live ? null : onEnable,
                child: const Text('Enable semantics'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: onRecheck,
                child: const Text('Re-check'),
              ),
            ],
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

/// One download mode: what it is, whether autocapture should record it, the
/// control that triggers it, and a marker button that describes the case in the
/// event stream.
class _DownloadCase extends StatelessWidget {
  const _DownloadCase({
    required this.id,
    required this.title,
    required this.mode,
    required this.detail,
    required this.captured,
    required this.requiresSemantics,
    required this.child,
  });

  final String id;
  final String title;

  /// Terse machine-friendly description of the trigger, sent on the marker event
  /// so the stream is readable without cross-referencing this file.
  final String mode;

  final String detail;

  /// Whether `[Amplitude] File Downloaded` is expected for this mode.
  final bool captured;

  /// Whether the expectation is conditional on the semantics tree being on.
  final bool requiresSemantics;

  final Widget child;

  String get _expectedEvent =>
      captured ? '[Amplitude] File Downloaded' : '(none)';

  /// Emits a labeled breadcrumb immediately before the case is exercised, so the
  /// event stream reads "marker → (expected autocapture event or nothing)".
  /// Flushed right away so ordering in the stream is obvious.
  Future<void> _mark(BuildContext context) async {
    final appState = AppState.of(context);
    await appState.analytics.track(BaseEvent(
      'Testbed Marker',
      eventProperties: {
        'surface': 'downloads',
        'case': id,
        'mode': mode,
        'expected event': _expectedEvent,
        'expect capture': captured,
        'requires semantics': requiresSemantics,
      },
    ));
    await appState.analytics.flush();
    appState.setMessage(
        'Marked case $id — next expect: $_expectedEvent. Now trigger it.');
  }

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
          Row(
            children: [
              OutlinedButton(
                onPressed: () => _mark(context),
                child: Text('Mark $id in stream'),
              ),
              const SizedBox(width: 12),
              Flexible(child: child),
            ],
          ),
        ],
      ),
    );
  }
}

/// A link-flagged semantics node — the interop-free way to put a real
/// `<a href="...">` in the DOM. [InkWell.onTap] is deliberately a no-op so the
/// only thing that can produce an event is the anchor's own click.
class _SemanticsLink extends StatelessWidget {
  const _SemanticsLink({
    required this.href,
    required this.label,
    required this.onTapped,
  });

  final String href;
  final String label;

  /// Records the tap locally so an inert case (semantics off, no `<a>` created)
  /// is distinguishable from a tap that never landed. Touches no DOM and sends
  /// no analytics, so it cannot affect which component produced an event.
  final VoidCallback onTapped;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      linkUrl: Uri.parse(href),
      child: InkWell(
        onTap: onTapped,
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
