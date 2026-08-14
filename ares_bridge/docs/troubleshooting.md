# Troubleshooting

## `getCapabilities()` says unsupported

This is expected on Windows, Linux, and web in version 0.0.1. Their plugin APIs
are registered, but transfer transports are not implemented. Use `reason` in
the UI and disable USB controls.

If Android, macOS, or iOS reports unsupported, confirm that the expected native
plugin was built and registered rather than running a stale binary.

## `MissingPluginException`

The Dart package is present but native registration is absent in the running
app.

1. Stop the application completely; hot reload cannot add a native plugin.
2. Run `flutter clean` if registration artifacts are stale.
3. Run `flutter pub get`.
4. Rebuild and reinstall the app.
5. Verify the target platform is declared under `flutter.plugin.platforms` in
   `pubspec.yaml`.

## `not_initialized`

Call and await `initialize()` before `startListening()`. Do not let two UI
actions race startup. A single application service should own bridge lifecycle.

## `not_connected`

`startListening()` does not wait for a peer. Subscribe to `connectionEvents`
and send only after `event.state == AresConnectionState.active`.

If a cable is attached but the state never becomes active:

- keep both apps open;
- unlock the mobile device;
- accept Android USB permission or Apple trust prompts;
- use a data-capable USB cable and direct port;
- disconnect and reconnect after starting listeners;
- inspect the latest connection event `message` and native logs.

## Android does not appear as an accessory

- Ensure the Android app is initialized and listening.
- Grant the accessory permission prompt.
- Keep the device unlocked during AOA re-enumeration.
- Reconnect the cable after the macOS listener starts.
- If automatic launch is required, add the host app's accessory attach intent
  filter and matching accessory XML; the library manifest alone does not choose
  an application for every accessory identity.

## macOS cannot open an Android USB interface

- Add `com.apple.security.device.usb` to both debug and release entitlements
  when App Sandbox is on.
- Close Android Studio device tools that may hold the interface.
- Stop ADB for that device, then reconnect.
- Unlock Android and keep its USB screen open during negotiation.
- Try a direct Mac port instead of a hub.

The native diagnostic distinguishes a device that does not answer AOA
negotiation from an interface that macOS cannot claim.

## macOS sees iPhone but never becomes active

- Pair the iPhone with the Mac and accept Trust prompts.
- Connect with a physical data cable; network device discovery is filtered.
- Open the iOS app and call `startListening()`.
- Keep the iOS app in the foreground.
- Confirm no other local process owns port `38473` inside the iOS app context.
- Reopen the app after cable or trust-state changes.

Connection refusal while the iOS foreground listener is not ready is retried by
the macOS backend and is not immediately treated as a fatal red state.

## Transfer reaches 100% and then fails

Payload progress can reach 100% before verification. Check the terminal failure
code:

- `verification_failed` indicates byte-count or SHA-256 mismatch.
- `send_failed` indicates sender-side file reading or streaming failure.
- `peer_error` or another forwarded code indicates receiver rejection.

Do not mark the UI complete based on progress alone.

## Destination already exists

Choose the behavior during initialization:

```dart
const AresBridgeConfiguration(
  overwritePolicy: AresOverwritePolicy.rename,
)
```

- `reject` fails the transfer.
- `replace` replaces only after the incoming file verifies.
- `rename` preserves the original and chooses a unique final name.

## Incoming path is rejected

`destinationPath` must be relative to the configured incoming directory. Do not
send absolute paths or `..` traversal. Use `/`-separated logical relative paths
and let the native receiver resolve them safely.

## Source file is rejected

Confirm that `sourcePath`:

- is non-empty and absolute;
- exists at send time;
- identifies a regular readable file;
- is accessible to the native sandbox/process;
- does not disappear or change unexpectedly during transfer.

## Events are missing from UI

- Subscribe before `startListening()` and before issuing fast transfers.
- Keep subscription objects alive.
- Do not cancel them during widget rebuilds.
- Track concurrent work by `transferId`, not only by file name.
- Add an `onError` callback to detect malformed platform event maps.

## Diagnostic information to collect

For a useful bug report, collect:

- package version and Git commit;
- Flutter/Dart version;
- host and mobile OS versions;
- `AresBridgeCapabilities` values;
- ordered connection states with timestamps;
- transfer ID, direction, stage, terminal code, and message;
- whether the problem reproduces with a direct port and known data cable;
- sanitized native logs from both endpoints.

Remove sensitive paths, peer names, metadata, and file content before sharing.
