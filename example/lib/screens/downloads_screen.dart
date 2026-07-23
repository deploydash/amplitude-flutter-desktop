import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'download_launcher_stub.dart'
    if (dart.library.js_interop) 'download_launcher_web.dart';

/// File-download autocapture playground (web only).
///
/// The Browser SDK's `fileDownloads` tracking listens for clicks on DOM
/// anchors whose href has a downloadable extension. Flutter widgets never
/// produce such anchors, so the button clicks a real `<a href="sample.pdf"
/// download>` element created via JS interop (see
/// `download_launcher_web.dart`), which emits `[Amplitude] File Downloaded`.
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
                  ? 'Tapping the button clicks a real DOM <a download> anchor '
                      'pointing at sample.pdf; the Browser SDK captures it as '
                      '[Amplitude] File Downloaded.'
                  : 'File-download autocapture is web-only; on this platform '
                      'the button is a no-op. This screen still emits its '
                      '[Amplitude] Screen Viewed event.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              child: const Text('Download sample.pdf'),
              onPressed: launchTestDownload,
            ),
          ],
        ),
      ),
    );
  }
}
