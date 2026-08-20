import 'dart:async';

// ignore_for_file: depend_on_referenced_packages
import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/autocapture/autocapture.dart';
import 'package:amplitude_flutter/autocapture/element_interactions.dart';
import 'package:amplitude_flutter/autocapture/page_views.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/constants.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:amplitude_flutter/observers/amplitude_navigator_observer.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'device_id_form.dart';
import 'event_form.dart';
import 'group_form.dart';
import 'group_identify_form.dart';
import 'identify_form.dart';
import 'reset.dart';
import 'revenue_form.dart';
import 'session_id.dart';
import 'user_id_form.dart';

class MyApp extends StatefulWidget {
  const MyApp(this.apiKey);

  final String apiKey;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _message = '';
  String _probeVerdict =
      'RUNNING — immediate event submitted; waiting for initialization';
  String _isBuiltStatus = 'Waiting for initialization';
  String _earlyTrackStatus = 'Not submitted';
  String _initialRouteStatus = 'Waiting for first frame';
  String _afterBuiltStatus = 'Waiting for isBuilt';
  String _flushStatus = 'Waiting for isBuilt';

  late Amplitude analytics;
  late final Future<void> _startupIdentityFuture;
  late final Future<void> _immediateTrackFuture;
  late final AmplitudeNavigatorObserver _navigatorObserver;
  late final String _platformLabel;
  late final String _runId;
  final Completer<void> _initialRouteSubmitted = Completer<void>();
  final Stopwatch _initializationStopwatch = Stopwatch();
  bool _isBuiltCompleted = false;

  Future<void> _finishInitializationProbe() async {
    final built = await analytics.isBuilt;
    _isBuiltCompleted = true;
    _initializationStopwatch.stop();
    _updateProbe(() {
      _isBuiltStatus = 'Completed: $built '
          'after ${_initializationStopwatch.elapsedMilliseconds} ms';
    });

    if (!built) {
      _updateProbe(() {
        _probeVerdict = 'FAIL — isBuilt returned false';
        _afterBuiltStatus = 'Not submitted: initialization failed';
        _flushStatus = 'Not attempted';
      });
      setMessage('Amplitude initialization failed — run ID: $_runId');
      return;
    }

    try {
      await _startupIdentityFuture;
      await _immediateTrackFuture;
      await analytics.track(BaseEvent(
        'init-race-after-built',
        insertId: '$_runId-after-built',
        eventProperties: _probeProperties('after-isBuilt'),
      ));
      _updateProbe(() {
        _afterBuiltStatus = 'Completed';
      });

      // The initial route is emitted by Navigator after the first frame. Wait
      // for that callback instead of guessing with a delay, so the local check
      // cannot finish before every startup marker has at least been submitted.
      await _initialRouteSubmitted.future;
      await analytics.flush();
      _updateProbe(() {
        _flushStatus = 'Completed';
        _probeVerdict = 'LOCAL CHECK COMPLETE — explicit calls completed, '
            'initial route submitted, and flush requested. Verify the three '
            'events in Amplitude.';
      });
      setMessage('Startup probe submitted — verify run ID: $_runId');
    } catch (error) {
      _updateProbe(() {
        _probeVerdict = 'FAIL — $error';
        _afterBuiltStatus = 'Failed: $error';
        _flushStatus = 'Not completed';
      });
      setMessage('Startup probe failed — run ID: $_runId');
    }
  }

  @override
  void initState() {
    super.initState();
    _platformLabel = kIsWeb ? 'web' : defaultTargetPlatform.name;
    const variant =
        String.fromEnvironment('TEST_VARIANT', defaultValue: 'candidate');
    _runId =
        '$variant-$_platformLabel-${DateTime.now().millisecondsSinceEpoch}';
    _initializationStopwatch.start();

    analytics = Amplitude(Configuration(
        apiKey: widget.apiKey,
        userId: _runId,
        flushQueueSize: 1,
        flushIntervalMillis: 1000,
        fetchRemoteConfig: false,
        logLevel: LogLevel.debug,
        // Screen views are captured by the AmplitudeNavigatorObserver on every
        // platform. On web we disable pageViews so a navigation is reported once
        // (as `[Amplitude] Screen Viewed`) instead of also as
        // `[Amplitude] Page Viewed`.
        //
        // The web autocapture options below are all opt-in. The DOM-based ones
        // (elementInteractions, formInteractions) require the semantics tree,
        // which main() enables on web. ElementInteractionsOptions() ships
        // Flutter-aware selectors so clicks on Flutter widgets are captured.
        autocapture: const AutocaptureOptions(
          screenViews: true,
          pageViews: PageViewsDisabled(),
          appLifecycles: true,
          deepLinks: true,
          elementInteractions: ElementInteractionsOptions(),
          formInteractions: true,
          pageUrlEnrichment: true,
        )));

    // Assign the run ID explicitly before the immediate event as well as in
    // Configuration. This keeps Android, iOS, and web runs easy to find even
    // when the event itself races initialization.
    _startupIdentityFuture = analytics.setUserId(_runId);
    _earlyTrackStatus = 'Submitted before isBuilt';
    _immediateTrackFuture = analytics.track(BaseEvent(
      'init-race-immediate',
      insertId: '$_runId-immediate',
      eventProperties: _probeProperties('before-isBuilt'),
    ));
    unawaited(
      _immediateTrackFuture.then<void>(
        (_) {
          _updateProbe(() {
            _earlyTrackStatus = 'Completed';
          });
        },
        onError: (Object error, StackTrace stackTrace) {
          _updateProbe(() {
            _earlyTrackStatus = 'Failed: $error';
          });
        },
      ),
    );

    _navigatorObserver = AmplitudeNavigatorObserver(
      analytics,
      nameExtractor: (settings) {
        final name = settings.name;
        if (name == '/' && !_initialRouteSubmitted.isCompleted) {
          final timing = _isBuiltCompleted ? 'after isBuilt' : 'before isBuilt';
          _initialRouteSubmitted.complete();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _updateProbe(() {
              _initialRouteStatus = 'Initial / route submitted $timing';
            });
          });
        }
        return name == null ? null : '$name | $_runId';
      },
    );
    unawaited(_finishInitializationProbe());
  }

  Map<String, dynamic> _probeProperties(String phase) => {
        'run_id': _runId,
        'phase': phase,
        'platform': _platformLabel,
      };

  void _updateProbe(VoidCallback update) {
    if (!mounted) return;
    setState(update);
  }

  Future<void> _flushEvents() async {
    await analytics.flush();
    setMessage('Events flushed — run ID: $_runId');
  }

  Future<void> _copyRunId() async {
    await Clipboard.setData(ClipboardData(text: _runId));
    setMessage('Run ID copied: $_runId');
  }

  void setMessage(String message) {
    setState(() {
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    const Widget divider = Divider();

    return AppState(
      analytics: analytics,
      setMessage: setMessage,
      child: MaterialApp(
        theme: ThemeData(
            inputDecorationTheme: InputDecorationTheme(
                contentPadding: const EdgeInsets.all(8), filled: true)),
        navigatorObservers: [_navigatorObserver],
        routes: {
          '/details': (context) => const DetailsScreen(),
        },
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Amplitude Flutter'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(10.0),
            child: ListView(
              children: <Widget>[
                _InitializationProbeCard(
                  runId: _runId,
                  platform: _platformLabel,
                  verdict: _probeVerdict,
                  isBuiltStatus: _isBuiltStatus,
                  earlyTrackStatus: _earlyTrackStatus,
                  initialRouteStatus: _initialRouteStatus,
                  afterBuiltStatus: _afterBuiltStatus,
                  flushStatus: _flushStatus,
                  onCopyRunId: _copyRunId,
                  onFlush: _flushEvents,
                ),
                divider,
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
                // FlushThresholdForm(),
                // divider,
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        child: const Text('Opt Out'),
                        onPressed: () {
                          analytics.setOptOut(true);
                          setMessage('Opted out — tracking disabled.');
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        child: const Text('Opt In'),
                        onPressed: () {
                          analytics.setOptOut(false);
                          setMessage('Opted in — tracking enabled.');
                        },
                      ),
                    ),
                  ],
                ),
                divider,
                ElevatedButton(
                  child: const Text('Flush Events'),
                  onPressed: _flushEvents,
                ),
                Builder(
                  builder: (context) => ElevatedButton(
                    child: const Text('Open Details Screen'),
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/details'),
                  ),
                ),
                Text(_message, style: Theme.of(context).textTheme.bodyLarge)
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InitializationProbeCard extends StatelessWidget {
  const _InitializationProbeCard({
    required this.runId,
    required this.platform,
    required this.verdict,
    required this.isBuiltStatus,
    required this.earlyTrackStatus,
    required this.initialRouteStatus,
    required this.afterBuiltStatus,
    required this.flushStatus,
    required this.onCopyRunId,
    required this.onFlush,
  });

  final String runId;
  final String platform;
  final String verdict;
  final String isBuiltStatus;
  final String earlyTrackStatus;
  final String initialRouteStatus;
  final String afterBuiltStatus;
  final String flushStatus;
  final VoidCallback onCopyRunId;
  final VoidCallback onFlush;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Initialization race probe',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Cold-launch the app, then find this run ID in Amplitude. The '
              'three expected events are listed below.',
            ),
            const SizedBox(height: 12),
            SelectableText('Run ID: $runId'),
            Text('Platform: $platform'),
            const SizedBox(height: 12),
            Text(
              verdict,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _ProbeStatus(label: 'isBuilt', value: isBuiltStatus),
            _ProbeStatus(
                label: 'Immediate track future', value: earlyTrackStatus),
            _ProbeStatus(
                label: 'Initial route observer', value: initialRouteStatus),
            _ProbeStatus(
                label: 'After-isBuilt track future', value: afterBuiltStatus),
            _ProbeStatus(label: 'Flush future', value: flushStatus),
            const SizedBox(height: 12),
            const Text('Expected startup markers in Amplitude:'),
            const SelectableText('• init-race-immediate'),
            SelectableText('• [Amplitude] Screen Viewed: / | $runId'),
            const SelectableText('• init-race-after-built'),
            const SizedBox(height: 12),
            const Text(
              'The initial-route observer deliberately does not block navigation '
              'on analytics. The Amplitude event stream is the delivery check.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onCopyRunId,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy run ID'),
                ),
                OutlinedButton.icon(
                  onPressed: onFlush,
                  icon: const Icon(Icons.sync),
                  label: const Text('Flush again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProbeStatus extends StatelessWidget {
  const _ProbeStatus({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('$label: $value'),
    );
  }
}

/// A simple second screen to demonstrate screen view autocapture. Navigating to
/// the `/details` route emits an `[Amplitude] Screen Viewed` event through the
/// [AmplitudeNavigatorObserver].
class DetailsScreen extends StatelessWidget {
  const DetailsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Details')),
      body: const Center(child: Text('Details screen')),
    );
  }
}
