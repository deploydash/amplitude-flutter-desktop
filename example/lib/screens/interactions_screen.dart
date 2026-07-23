import 'package:flutter/material.dart';

/// Element-interaction (click) autocapture playground.
///
/// No manual track calls are made on this screen. On web, with
/// `elementInteractions` enabled and semantics on (see `main.dart`), tapping
/// these controls emits `[Amplitude] Element Clicked` and editing inputs emits
/// `[Amplitude] Element Changed`. On iOS/Android element interactions are not
/// exposed by this SDK, so this screen only produces its own
/// `[Amplitude] Screen Viewed` event.
class InteractionsScreen extends StatefulWidget {
  const InteractionsScreen({super.key});

  @override
  State<InteractionsScreen> createState() => _InteractionsScreenState();
}

class _InteractionsScreenState extends State<InteractionsScreen> {
  bool _checkbox = false;
  bool _toggle = false;
  String _lastAction = 'none';

  void _record(String action) {
    setState(() => _lastAction = action);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Interactions')),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: ListView(
          children: [
            Text('Buttons', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            ElevatedButton(
              child: const Text('Elevated Button'),
              onPressed: () => _record('elevated button'),
            ),
            OutlinedButton(
              child: const Text('Outlined Button'),
              onPressed: () => _record('outlined button'),
            ),
            TextButton(
              child: const Text('Text Button'),
              onPressed: () => _record('text button'),
            ),
            IconButton(
              icon: const Icon(Icons.favorite),
              tooltip: 'Icon Button',
              onPressed: () => _record('icon button'),
            ),
            const Divider(),
            Text('Inputs', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            const TextField(
              decoration: InputDecoration(
                  labelText: 'Free text — emits Element Changed on web'),
            ),
            CheckboxListTile(
              title: const Text('Checkbox'),
              value: _checkbox,
              onChanged: (value) {
                setState(() => _checkbox = value ?? false);
                _record('checkbox -> $value');
              },
            ),
            SwitchListTile(
              title: const Text('Switch'),
              value: _toggle,
              onChanged: (value) {
                setState(() => _toggle = value);
                _record('switch -> $value');
              },
            ),
            const Divider(),
            Text('Last local action: $_lastAction',
                style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}
