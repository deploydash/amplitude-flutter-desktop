# amplitude_flutter_example

Demonstrates how to use the amplitude flutter plugin.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://flutter.io/docs/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://flutter.io/docs/cookbook)

For help getting started with Flutter, view our
[online documentation](https://flutter.io/docs), which offers tutorials,
samples, guidance on mobile development, and a full API reference.


## Run the example
Assuming you have Flutter setup on your machine.

Use a test Amplitude project and pass its API key with `--dart-define`.

The first card in the example is an initialization race probe. On every cold
launch it displays a unique run ID, submits one event before `isBuilt`, captures
the initial `/` route, submits another event after `isBuilt`, and flushes. Search
for the run ID in Amplitude and verify all three listed events arrive once.

No source edits or timing delays are required:

For an A/B comparison, also pass
`--dart-define=TEST_VARIANT=baseline` or
`--dart-define=TEST_VARIANT=candidate`; the value is included in every run ID.

1. Launch the app with a test-project API key.
2. Wait for `LOCAL CHECK COMPLETE` on the first card.
3. Copy its run ID and search for that user ID in Amplitude's event stream.
4. Confirm the three startup markers printed on the card are present.

Repeat with fresh cold launches if you want to exercise the startup race more
than once; every launch generates a new run ID.

### Android & iOS
Open the emulator you want to test on (Android, iOS)
```shell
flutter run -d <device-id> \
  --dart-define=AMPLITUDE_API_KEY=<test-project-key>
```

### Browser
```shell
flutter run -d chrome \
  --dart-define=AMPLITUDE_API_KEY=<test-project-key>
```
In some cases (e.g. Chrome with forced sign-in), above command may not work well.
Use the below command to start the server, then follow the printed link in console.
```shell
flutter run -d web-server --web-port=5000 \
  --web-enable-expression-evaluation \
  --dart-define=AMPLITUDE_API_KEY=<test-project-key>
```
