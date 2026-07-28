import 'dart:js_interop';
import 'dart:js_interop_unsafe';

const String _anchorId = 'amp-testbed-download-anchor';

/// Clicks a real, persistent DOM `<a href="sample.pdf" download>` anchor.
///
/// The Browser SDK's file-download tracking attaches a per-anchor click
/// listener, discovering new anchors through a `MutationObserver`. Observer
/// callbacks are asynchronous, so the anchor must already be in the DOM well
/// before it is clicked — a create-click-remove sequence in one task is
/// guaranteed to be missed. The anchor is therefore created once, kept in the
/// DOM, and the very first click is deferred long enough for the observer to
/// attach the listener.
Future<void> launchTestDownload() async {
  final document = globalContext.getProperty<JSObject>('document'.toJS);

  var anchor = document.callMethod<JSObject?>(
      'getElementById'.toJS, _anchorId.toJS);
  if (anchor == null) {
    anchor = document.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
    anchor.setProperty('id'.toJS, _anchorId.toJS);
    anchor.setProperty('href'.toJS, 'sample.pdf'.toJS);
    anchor.setProperty('download'.toJS, 'sample.pdf'.toJS);
    document
        .getProperty<JSObject>('body'.toJS)
        .callMethod('appendChild'.toJS, anchor);
    // Give the file-download plugin's MutationObserver time to see the new
    // anchor and attach its click listener before the first click.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  anchor.callMethod('click'.toJS);
}
