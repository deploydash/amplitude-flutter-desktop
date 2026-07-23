import 'package:flutter/material.dart';

import '../app_state.dart';
import '../device_id_form.dart';
import '../event_form.dart';
import '../group_form.dart';
import '../group_identify_form.dart';
import '../identify_form.dart';
import '../reset.dart';
import '../revenue_form.dart';
import '../session_id.dart';
import '../user_id_form.dart';

/// The pre-existing manual SDK API playground (device ID, identify, track,
/// revenue, flush, opt-out…), unchanged, now grouped on its own screen.
class ManualApiScreen extends StatelessWidget {
  const ManualApiScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const Widget divider = Divider();
    final appState = AppState.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Manual API')),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: ListView(
          children: <Widget>[
            DeviceIdForm(),
            divider,
            UserIdForm(),
            divider,
            ResetForm(),
            divider,
            SessionIdForm(),
            divider,
            EventForm(),
            divider,
            IdentifyForm(),
            divider,
            GroupForm(),
            divider,
            GroupIdentifyForm(),
            divider,
            RevenueForm(),
            divider,
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    child: const Text('Opt Out'),
                    onPressed: () {
                      appState.analytics.setOptOut(true);
                      appState.setMessage('Opted out — tracking disabled.');
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    child: const Text('Opt In'),
                    onPressed: () {
                      appState.analytics.setOptOut(false);
                      appState.setMessage('Opted in — tracking enabled.');
                    },
                  ),
                ),
              ],
            ),
            divider,
            ElevatedButton(
              child: const Text('Flush Events'),
              onPressed: () {
                appState.analytics.flush();
                appState.setMessage('Events flushed.');
              },
            ),
            ValueListenableBuilder<String>(
              valueListenable: appState.message,
              builder: (context, message, _) =>
                  Text(message, style: Theme.of(context).textTheme.bodyLarge),
            ),
          ],
        ),
      ),
    );
  }
}
