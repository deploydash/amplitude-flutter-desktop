import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amplitude_flutter_example/my_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('amplitude_flutter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('Android probe preserves startup order and awaits native build',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final initCompleter = Completer<void>();
      final buildCompleter = Completer<void>();
      final calls = <MethodCall>[];

      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'init') {
          await initCompleter.future;
        } else if (call.method == 'awaitBuild') {
          await buildCompleter.future;
        }
        return null;
      });

      await tester.pumpWidget(const MyApp('test-api-key'));
      await tester.pump();

      // The app has already attempted identity, the immediate event, and the
      // initial route, but Android keeps them off the channel until registration.
      expect(calls.map((call) => call.method), ['init']);

      initCompleter.complete();
      await tester.pump();

      expect(calls.map((call) => call.method), [
        'init',
        'setUserId',
        'track',
        'track',
        'awaitBuild',
      ]);
      expect(find.textContaining('Waiting for initialization'), findsWidgets);

      buildCompleter.complete();
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.method), [
        'init',
        'setUserId',
        'track',
        'track',
        'awaitBuild',
        'track',
        'flush',
      ]);

      final trackedEvents = calls
          .where((call) => call.method == 'track')
          .map((call) => (call.arguments as Map<Object?, Object?>)['event']
              as Map<Object?, Object?>)
          .toList();

      expect(trackedEvents[0]['event_type'], 'init-race-immediate');
      expect(trackedEvents[1]['event_type'], '[Amplitude] Screen Viewed');
      expect(
        (trackedEvents[1]['event_properties']
            as Map<Object?, Object?>)['[Amplitude] Screen Name'],
        startsWith('/ | candidate-'),
      );
      expect(trackedEvents[2]['event_type'], 'init-race-after-built');
      expect(find.textContaining('LOCAL CHECK COMPLETE'), findsOneWidget);
      expect(
        find.textContaining('Initial / route submitted before isBuilt'),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, skip: kIsWeb);
}
