// ignore_for_file: depend_on_referenced_packages
import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/autocapture/autocapture.dart';
import 'package:amplitude_flutter/autocapture/element_interactions.dart';
import 'package:amplitude_flutter/autocapture/page_views.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/constants.dart';
import 'package:amplitude_flutter/observers/amplitude_navigator_observer.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/downloads_screen.dart';
import 'screens/forms_screen.dart';
import 'screens/home_screen.dart';
import 'screens/interactions_screen.dart';
import 'screens/manual_api_screen.dart';
import 'screens/navigation_lab_screen.dart';

class MyApp extends StatefulWidget {
  const MyApp(this.apiKey);

  final String apiKey;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final ValueNotifier<String> _message = ValueNotifier('');

  late Amplitude analytics;
  late final AmplitudeNavigatorObserver _navigatorObserver;

  initAnalytics() async {
    await analytics.isBuilt;

    setMessage('Amplitude initialized');
  }

  @override
  void initState() {
    super.initState();
    analytics = Amplitude(Configuration(
        apiKey: widget.apiKey,
        logLevel: LogLevel.debug,
        flushIntervalMillis: 1000,
        // Autocapture testbed: every option enabled. Note that with both
        // `pageViews` and `screenViews` on, a URL-changing navigation on web is
        // deliberately reported twice (`[Amplitude] Page Viewed` from the
        // Browser SDK and `[Amplitude] Screen Viewed` from the navigator
        // observer) so both capture paths can be verified.
        autocapture: const AutocaptureOptions(
          sessions: true,
          appLifecycles: true,
          deepLinks: true,
          screenViews: true,
          formInteractions: true,
          fileDownloads: true,
          pageUrlEnrichment: true,
          pageViews: PageViewsOptions(),
          elementInteractions: ElementInteractionsOptions(
            // The Browser SDK's default allowlist plus role selectors:
            // Flutter's semantics tree renders buttons/checkboxes/switches as
            // role="..." elements (not <button>/<input> tags), so without the
            // extra selectors their taps would not be click-tracked on web.
            // Note these controls can only produce Element Clicked — they are
            // not real <input>s, so no native change event (Element Changed)
            // ever fires for them.
            cssSelectorAllowlist: [
              'a',
              'button',
              'input',
              'select',
              'textarea',
              'label',
              '[role="button"]',
              '[role="checkbox"]',
              '[role="switch"]',
            ],
          ),
        )));
    _navigatorObserver = AmplitudeNavigatorObserver(analytics);
    initAnalytics();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void setMessage(String message) {
    _message.value = message;
  }

  @override
  Widget build(BuildContext context) {
    return AppState(
      analytics: analytics,
      setMessage: setMessage,
      message: _message,
      child: MaterialApp(
        theme: ThemeData(
            inputDecorationTheme: InputDecorationTheme(
                contentPadding: const EdgeInsets.all(8), filled: true)),
        navigatorObservers: [_navigatorObserver],
        routes: {
          '/': (context) => const HomeScreen(),
          '/manual': (context) => const ManualApiScreen(),
          '/interactions': (context) => const InteractionsScreen(),
          '/forms': (context) => const FormsScreen(),
          '/downloads': (context) => const DownloadsScreen(),
          '/navigation': (context) => const NavigationLabScreen(),
          '/navigation/details-a': (context) =>
              const NavigationDetailsScreen(label: 'A'),
          '/navigation/details-b': (context) =>
              const NavigationDetailsScreen(label: 'B'),
        },
      ),
    );
  }
}
