import 'package:flutter/material.dart';

/// Form-interaction autocapture playground (web only).
///
/// **Known limitation (verified live):** the Browser SDK's `formInteractions`
/// plugin only attaches listeners to DOM `<form>` elements, and Flutter web
/// (CanvasKit + semantics) renders text fields as bare `<input>`s with no
/// `<form>` wrapper — even inside an [AutofillGroup]. So
/// `[Amplitude] Form Started` / `[Amplitude] Form Submitted` do NOT fire on
/// Flutter web today.
///
/// The fields still exercise `[Amplitude] Element Changed` (the `<input>`s are
/// real DOM elements), which is why this screen is kept: it documents the gap
/// and proves the inputs are otherwise visible to autocapture. If a future
/// engine wraps autofill groups in a real `<form>`, this screen starts
/// producing form events with no changes.
class FormsScreen extends StatefulWidget {
  const FormsScreen({super.key});

  @override
  State<FormsScreen> createState() => _FormsScreenState();
}

class _FormsScreenState extends State<FormsScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  String _status = '';

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forms')),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: ListView(
          children: [
            Text('Sign-up form',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            AutofillGroup(
              child: Column(
                children: [
                  TextField(
                    controller: _name,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _email,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              child: const Text('Submit'),
              onPressed: () {
                setState(() => _status =
                    'Submitted locally: ${_name.text} <${_email.text}>');
                _name.clear();
                _email.clear();
              },
            ),
            const SizedBox(height: 10),
            Text(_status, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}
