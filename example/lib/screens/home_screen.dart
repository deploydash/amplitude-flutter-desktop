import 'package:flutter/material.dart';

import '../app_state.dart';

/// Hub for the autocapture testbed. Every destination is a named route, so
/// navigating to it emits an `[Amplitude] Screen Viewed` event (with the route
/// name) through the `AmplitudeNavigatorObserver`.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Widget _link(
      BuildContext context, String route, String title, String subtitle) {
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).pushNamed(route),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Amplitude Autocapture Testbed')),
      body: ListView(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: AppState.of(context).message,
            builder: (context, message, _) => Padding(
              padding: const EdgeInsets.all(10.0),
              child: Text(message.isEmpty ? 'Initializing…' : message,
                  style: Theme.of(context).textTheme.bodyLarge),
            ),
          ),
          const Divider(),
          _link(context, '/interactions', 'Interactions lab',
              'Element Clicked / Element Changed (web)'),
          _link(context, '/forms', 'Forms lab',
              'Form Started / Form Submitted (web)'),
          _link(
              context, '/downloads', 'Downloads lab', 'File Downloaded (web)'),
          _link(context, '/navigation', 'Navigation lab',
              'Screen Viewed: push / pop / replace / dialogs'),
          _link(context, '/manual', 'Manual API',
              'identify, track, revenue, flush, opt-out'),
        ],
      ),
    );
  }
}
