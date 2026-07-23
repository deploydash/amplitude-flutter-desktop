import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Creates and clicks a real DOM `<a href="sample.pdf" download>` anchor.
///
/// The Browser SDK's file-download tracking listens for anchor clicks whose
/// href carries a downloadable extension, so this emits
/// `[Amplitude] File Downloaded`. `sample.pdf` is served from `web/`.
void launchTestDownload() {
  final document = globalContext.getProperty<JSObject>('document'.toJS);
  final anchor = document.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
  anchor.setProperty('href'.toJS, 'sample.pdf'.toJS);
  anchor.setProperty('download'.toJS, 'sample.pdf'.toJS);
  final body = document.getProperty<JSObject>('body'.toJS);
  body.callMethod('appendChild'.toJS, anchor);
  anchor.callMethod('click'.toJS);
  anchor.callMethod('remove'.toJS);
}
