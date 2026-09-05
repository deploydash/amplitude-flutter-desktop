# Amplitude Flutter SDK (for Linux & Windows)

This is a fork of the official Amplitude Flutter SDK, maintained by Deploy Dash at [deploydash/amplitude-flutter-desktop](https://github.com/deploydash/amplitude-flutter-desktop). It adds Linux/Windows desktop support on top of upstream; mobile/web behavior follows the official SDK.

## Installation and Quick Start

This fork is not published to pub.dev, so consume it as a git dependency pinned at a full commit SHA —
never a branch:

```yaml
dependencies:
  amplitude_flutter:
    git:
      url: https://github.com/deploydash/amplitude-flutter-desktop.git
      ref: <full-commit-sha>
```

The public `Amplitude` API is unchanged from upstream, so the [Developer Center](https://developers.amplitude.com/docs/flutter-setup)
is the full API reference — what follows is the shortest path to working
tracking, with the desktop caveats inline.

### 1. Initialize

```dart
import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/constants.dart';

final amplitude = Amplitude(
  Configuration(
    apiKey: 'YOUR_API_KEY',
    // EU-residency projects only:
    // serverZone: ServerZone.eu,
  ),
);
await amplitude.isBuilt;
```

One instance per Amplitude project. A second instance with a different
`instanceName` gets isolated storage and identity.

### 2. Track events

```dart
import 'package:amplitude_flutter/events/base_event.dart';

await amplitude.track(
  BaseEvent(
    'Workspace opened',
    eventProperties: {'plan': 'pro'},
  ),
);
```

Events are written to the on-disk queue first and uploaded in batches, so
a single event never triggers a request on its own — and nothing is lost
if the app quits before the next upload.

### 3. Identify users across login and logout

```dart
import 'package:amplitude_flutter/events/identify.dart';

// After login:
await amplitude.setUserId('user-123');
await amplitude.identify(Identify()..set('plan', 'pro'));

// On logout or account switch:
await amplitude.reset();
```

`reset()` clears the user id and rotates the device id; already-queued
events keep the previous identity and still upload.

### 4. Gate everything on consent

The SDK never prompts the user — that decision is yours. When your consent
flow declines, call `await amplitude.setOptOut(true)`; while opted out,
tracks are dropped and flush does nothing. Call `setOptOut(false)` when
consent is granted.

Opt-out is owned by the current configuration, not restored across launches:
supply your consent-derived `optOut` on every `init`, and use `setOptOut`
only to change the current run. Queued events are retained while opted out
and drain if you opt back in during the same run.

### Desktop notes (Linux / Windows)

- **Flush on close** (required): without it, events sit in the queue until
  the next launch. They are durable, not lost — but wire the hook in Host
  responsibilities below anyway.
- **Autocapture is sessions-only**: screen-view and element-interaction
  options have no desktop surface to observe; session handling follows your
  `sessions` setting.
- Groups (`setGroup`, `groupIdentify`) and `revenue()` work as documented
  in the Developer Center.

## Compatibility

Floors come from `pubspec.yaml`: Dart `>=3.3.0 <4.0.0`, Flutter `>=3.19.0`.
Android, iOS, macOS, and web keep their upstream backends; Linux and
Windows are served by the pure-Dart backend (no extra native toolchain).

| Area            | Requirement                                    |
|-----------------|------------------------------------------------|
| Dart            | `>=3.3.0 <4.0.0`                               |
| Flutter         | `>=3.19.0`                                     |
| Web, iOS, Android, MacOS | Supported via the [upstream package](https://pub.dev/packages/amplitude_flutter) | 
| Linux / Windows |  via `lib/desktop/` |

## Desktop support (Linux / Windows)

Linux and Windows are served by a pure-Dart backend under `lib/desktop/`
(`DesktopAmplitudePlugin`, registered via `dartPluginClass`); macOS keeps
using the shared Darwin backend. The public `Amplitude` API is unchanged —
the same 14 channel methods work on desktop with no caller changes — but
desktop hosts own two lifecycle jobs (foreground signals, flush on close);
see Host responsibilities below.

Unless noted below, behavior matches the Swift/Kotlin SDKs: upload
batching and tuning, the 400/413/429 retry dispatch with silent offline
trips and 30-day discard, session handling on the shared 5-minute gap,
`$identify` batching, and `reset()` identity rotation are parity ports, not
new features. Only these are actually desktop-specific:

- **Storage:** queue + identity live behind the injectable `DesktopStorage`
  seam, defaulting to `shared_preferences` namespaced per
  `storage-<apiKey>-<instanceName>`. Hosts needing real files (Store-aware
  paths, sandboxed dirs) inject their own implementation.
- **`reset()` rotates identity, not network state:** clears the user id and
  rotates the device id, while deliberately keeping transport health
  (offline/backoff/429 pause).
- **Lifecycle:** re-`init` disposes the replaced backend and hot restart
  retires the prior plugin's backends, so flush timers never double-upload.
  The backend shares one HTTP client, closed on dispose.
- **Callbacks:** terminal outcomes (sent/dropped) fire the config-level
  `DesktopBackend.onTerminalEvent(event, code, message)`. Per-event
  callbacks are not supported in v1 (`BaseEvent` has no callback field and
  callbacks cannot cross a `MethodChannel`).
- **Policy:** the SDK exposes mechanism only (`optOut`, `trackingOptions`,
  `flush()`). Consent, redaction, and storage location are host-app
  decisions. Mobile-only options (`migrateLegacyData`, location/ad-id
  toggles) and web-only options are accepted and ignored.

### Host responsibilities

The pure-Dart backend cannot see OS lifecycle notifications and does not
own your windows, so two jobs stay in the host app. (macOS gets both free
from AmplitudeSwift's `MacOSLifecycleMonitor`; Linux/Windows have no native
SDK to provide them.)

- **Flush on close.** Call `flush()` when the app is asked to exit. The
  framework hook is
  [`AppLifecycleListener.onExitRequested`](https://api.flutter.dev/flutter/widgets/AppLifecycleListener/onExitRequested.html):
  await the flush, then answer `exit`:

  ```dart
  import 'dart:ui'; // AppExitResponse lives here; widgets.dart does not re-export it.

  // `amplitude` is your shared Amplitude instance. Keep the listener in
  // your root widget's state and dispose it there.
  AppLifecycleListener(
    onExitRequested: () async {
      await amplitude.flush();
      return AppExitResponse.exit;
    },
  );
  ```

  If you use `window_manager`'s `setPreventClose`, verify which hook fires
  in your app first — intercepting the close at the window level can starve
  the framework request ([reported upstream](https://github.com/leanflutter/window_manager/issues/466));
  flush in `WindowListener.onWindowClose` instead if so. Either way, treat
  this as best-effort: kills and task-manager terminates deliver no
  notification, so the on-disk queue — not the close hook — is the delivery
  guarantee.
- **Foreground signals.** These apply when you embed `DesktopBackend`
  directly; through the channel API the backend stays at its foreground
  default, so sessions extend across focus loss. Direct embedders map host
  observations onto the backend (timestamps are millis since epoch):

  | Your app | Tell the backend |
  | --- | --- |
  | Window gains focus while visible | `setForeground(true)` |
  | Focus lost but window stays visible (`onInactive`) | nothing — still foreground, do not end the session |
  | Minimized or hidden (`onHide`) | `onExitForeground(nowMs)` (stamps time, flushes when `flushEventsOnClose` is on) |
  | Restored or shown again | `onEnterForeground(nowMs)` (starts a new session past the gap) |

  Desktop `inactive` means "visible but unfocused" (alt-tab), not
  backgrounded — ending the session there is the classic desktop bug. See
  [`AppLifecycleListener`](https://api.flutter.dev/flutter/widgets/AppLifecycleListener-class.html)
  and [`AppLifecycleState`](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html).

## Need Help?

For anything in this fork — especially the Linux/Windows backend — please
[file an issue](https://github.com/deploydash/amplitude-flutter-desktop/issues).
For upstream mobile/web behavior, the official
[Amplitude Help](https://help.amplitude.com/hc/en-us/requests/new) still
applies.
