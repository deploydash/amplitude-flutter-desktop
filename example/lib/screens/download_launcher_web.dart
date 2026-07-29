import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSObject get _document => globalContext.getProperty<JSObject>('document'.toJS);

/// Creates (once) and clicks a real DOM `<a>` with [href].
///
/// The Browser SDK's file-download plugin discovers anchors through an async
/// `MutationObserver`, so the anchor must already be in the DOM before it is
/// clicked — a create-click-remove sequence in a single task is always missed.
/// The anchor is therefore keyed by [id], kept in the DOM, and the first click
/// is deferred long enough for the listener to attach.
///
/// Set [withDownloadAttr] to add `download`, which makes the browser save the
/// file instead of navigating to / previewing it. It has no effect on capture —
/// the plugin only tests the href's extension.
Future<void> clickSyntheticAnchor({
  required String id,
  required String href,
  bool withDownloadAttr = false,
  bool newTab = false,
}) async {
  var anchor = _document.callMethod<JSObject?>('getElementById'.toJS, id.toJS);
  if (anchor == null) {
    anchor = _document.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
    anchor.setProperty('id'.toJS, id.toJS);
    anchor.setProperty('href'.toJS, href.toJS);
    if (withDownloadAttr) {
      anchor.setProperty('download'.toJS, ''.toJS);
    }
    if (newTab) {
      anchor.setProperty('target'.toJS, '_blank'.toJS);
    }
    _document
        .getProperty<JSObject>('body'.toJS)
        .callMethod('appendChild'.toJS, anchor);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  anchor.callMethod('click'.toJS);
}

/// Opens [href] with `window.open`, the same mechanism `url_launcher` uses on
/// web. No anchor is clicked, so the file-download plugin never sees it.
void openWithWindowOpen(String href) {
  globalContext.callMethod('open'.toJS, href.toJS, '_blank'.toJS);
}

/// Whether Flutter is currently emitting a DOM semantics tree.
///
/// This is the real gate for every DOM-based autocapture feature, and it is not
/// observable from the framework: `SemanticsBinding.semanticsEnabled` reports
/// `true` as soon as a handle exists, while the web engine may still be gated.
/// Counting `flt-semantics` elements reflects what the Browser SDK can actually
/// see.
bool isSemanticsTreeLive() {
  final nodes = _document.callMethod<JSObject>(
      'querySelectorAll'.toJS, 'flt-semantics'.toJS);
  return (nodes.getProperty<JSNumber>('length'.toJS).toDartInt) > 0;
}

/// Turns the semantics tree on by activating the engine's injected
/// "Enable accessibility" placeholder.
///
/// Test tooling only — this is not part of any capture path. The engine enables
/// semantics on a `click` whose target is the placeholder itself and then
/// removes the placeholder, which is exactly what assistive technology triggers.
/// Returns false when the placeholder is absent (semantics already on).
bool enableSemanticsTree() {
  final placeholder = _document.callMethod<JSObject?>(
      'querySelector'.toJS, 'flt-semantics-placeholder'.toJS);
  if (placeholder == null) {
    return false;
  }
  placeholder.callMethod('click'.toJS);
  return true;
}
