/// Non-web platforms: file-download autocapture is a Browser SDK feature, so
/// these DOM helpers are no-ops here.
Future<void> clickSyntheticAnchor({
  required String id,
  required String href,
  bool withDownloadAttr = false,
  bool newTab = false,
}) async {}

void openWithWindowOpen(String href) {}
