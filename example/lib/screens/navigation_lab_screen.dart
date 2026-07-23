import 'package:flutter/material.dart';

/// Screen-view autocapture playground: exercises every navigation shape the
/// `AmplitudeNavigatorObserver` handles.
///
/// Expected `[Amplitude] Screen Viewed` behavior:
/// - push / pushReplacementNamed → event for the new route
/// - pop → event for the revealed route
/// - popUntil → one event per popped PageRoute (intermediates included)
/// - dialogs / bottom sheets (non-PageRoutes) → no events at all
/// - unnamed routes → skipped, with a debug-mode log explaining why
class NavigationLabScreen extends StatelessWidget {
  const NavigationLabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Navigation')),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: ListView(
          children: [
            ElevatedButton(
              child: const Text('Push Details A'),
              onPressed: () =>
                  Navigator.of(context).pushNamed('/navigation/details-a'),
            ),
            ElevatedButton(
              child: const Text('Show dialog (must NOT track)'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Dialog'),
                  content: const Text(
                      'Dialogs are not PageRoutes; opening and dismissing '
                      'this must not emit Screen Viewed events.'),
                  actions: [
                    TextButton(
                      child: const Text('Close'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
            ElevatedButton(
              child: const Text('Show bottom sheet (must NOT track)'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (context) => const SizedBox(
                    height: 160,
                    child: Center(child: Text('Bottom sheet — not tracked'))),
              ),
            ),
            ElevatedButton(
              child: const Text('Push unnamed route (skipped + debug log)'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (context) => Scaffold(
                  appBar: AppBar(title: const Text('Unnamed route')),
                  body: const Padding(
                    padding: EdgeInsets.all(10.0),
                    child: Text(
                        'This route has no name, so no Screen Viewed event is '
                        'emitted for it (see the debug log). Popping back does '
                        'emit one for the revealed /navigation screen.'),
                  ),
                ),
              )),
            ),
          ],
        ),
      ),
    );
  }
}

/// Target screen for push/replace/pop tests. Details A links onward to
/// Details B so multi-level pops can be exercised.
class NavigationDetailsScreen extends StatelessWidget {
  const NavigationDetailsScreen({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Details $label')),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: ListView(
          children: [
            if (label == 'A') ...[
              ElevatedButton(
                child: const Text('Push Details B'),
                onPressed: () =>
                    Navigator.of(context).pushNamed('/navigation/details-b'),
              ),
              ElevatedButton(
                child: const Text('Replace with Details B (didReplace)'),
                onPressed: () => Navigator.of(context)
                    .pushReplacementNamed('/navigation/details-b'),
              ),
            ],
            ElevatedButton(
              child: const Text('Pop back'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              child: const Text('popUntil Home (multi-pop)'),
              onPressed: () => Navigator.of(context)
                  .popUntil((route) => route.settings.name == '/'),
            ),
          ],
        ),
      ),
    );
  }
}
