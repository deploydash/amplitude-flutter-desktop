import 'package:flutter/material.dart';

/// Form-interaction autocapture playground (web only).
///
/// With `formInteractions` enabled, the Browser SDK emits
/// `[Amplitude] Form Started` on the first change inside a DOM `<form>`.
/// Flutter web renders an [AutofillGroup] with autofill-hinted text fields as a
/// real `<form>` with `<input>` children (when semantics are enabled), which is
/// what makes capture possible under CanvasKit.
///
/// Note: `[Amplitude] Form Submitted` listens for the DOM `submit` event, which
/// a Flutter button tap does not dispatch — so on Flutter web expect
/// `Form Started` but not `Form Submitted`.
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
