# Ares Bridge

Cross-platform USB peer discovery and checksum-verified, bidirectional file
transfer for Flutter applications.

Ares Bridge provides one typed Dart API for listener lifecycle, peer readiness,
transfer progress, verified completion, received files, and failures. Native
transports sit behind the same API, so application code does not need platform
branches.

## Platform status

| Platform | Role | Current transport |
| --- | --- | --- |
| Android | USB accessory | Android Open Accessory via `UsbManager` |
| macOS | USB host | AOA for Android; usbmuxd for paired iOS devices |
| iOS | USB accessory | Foreground loopback listener through physical usbmuxd |
| Windows | USB host | API registered; WinUSB/AOA transport not linked yet |
| Linux | USB host | API registered; libusb/AOA transport not linked yet |
| Web | — | Capability reporting; portable USB transfer unsupported |

All six Flutter platforms register the plugin API. Call `getCapabilities()` at
runtime before displaying transfer controls because transport availability
differs by platform.

## Getting started

### 1. Install

Add the latest published package:

```console
flutter pub add ares_bridge
```

Or add it manually to `pubspec.yaml`:

```yaml
dependencies:
  ares_bridge: ^0.0.1
```

Then import the public API:

```dart
import 'package:ares_bridge/ares_bridge.dart';
```

### 2. Create the bridge and subscribe to events

Subscribe before starting the listener so the application receives early
connection events.

```dart
import 'dart:async';

import 'package:ares_bridge/ares_bridge.dart';
import 'package:flutter/services.dart';

final bridge = AresBridge();
final subscriptions = <StreamSubscription<Object?>>[];

Future<void> startBridge() async {
  final capabilities = await bridge.getCapabilities();
  if (!capabilities.isSupported) {
    throw UnsupportedError(
      capabilities.reason ??
          'Ares Bridge is unavailable on ${capabilities.platform}.',
    );
  }

  subscriptions.add(
    bridge.connectionEvents.listen((event) {
      print('Connection: ${event.state.name}');
      if (event.peerName case final peerName?) {
        print('Peer: $peerName');
      }
    }),
  );

  subscriptions.add(
    bridge.transferProgress.listen((event) {
      final percent = (event.fraction * 100).toStringAsFixed(1);
      print('${event.fileName}: $percent%');
    }),
  );

  subscriptions.add(
    bridge.receivedFiles.listen((event) {
      print('Received and verified: ${event.localPath}');
    }),
  );

  subscriptions.add(
    bridge.failedTransfers.listen((event) {
      print('${event.code}: ${event.message}');
    }),
  );

  try {
    await bridge.initialize(
      const AresBridgeConfiguration(
        role: AresBridgeRole.automatic,
        localPeerName: 'Warehouse device',
        overwritePolicy: AresOverwritePolicy.rename,
      ),
    );
    await bridge.startListening();
  } on PlatformException catch (error) {
    print('${error.code}: ${error.message}');
    rethrow;
  }
}
```

`startListening()` requests listener startup; it does not wait for a peer.
Enable sending only after a connection event reaches
`AresConnectionState.active`.

### 3. Send a file

`sourcePath` must be an absolute path readable by the native application.
`destinationPath`, when supplied, is relative to the receiver's configured
incoming directory.

```dart
final transferId = await bridge.sendFile(
  AresFileTransferRequest(
    sourcePath: '/absolute/path/report.pdf',
    destinationPath: 'reports/report.pdf',
    metadata: const {'origin': 'drag-drop'},
  ),
);
```

The returned ID means the native backend accepted the request. It is not a
delivery receipt. Match `transferId` against `completedTransfers` or
`failedTransfers` for the terminal result.

### 4. Send multiple files

```dart
final transferIds = await bridge.sendFiles([
  for (final path in droppedPaths)
    AresFileTransferRequest(
      sourcePath: path,
      metadata: const {'origin': 'drag-drop'},
    ),
]);
```

Returned IDs correspond to requests by index. Track each transfer separately.

### 5. Stop and dispose

Cancel stream subscriptions before disposing the bridge:

```dart
Future<void> stopBridge() async {
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  subscriptions.clear();
  await bridge.dispose();
}
```

Use `stopListening()` instead when you intend to restart the same bridge later.

## Connection states

| State | Meaning |
| --- | --- |
| `stopped` | Listener and session are closed |
| `listening` | Local receiver is waiting for a peer |
| `connecting` | Physical transport or handshake is progressing |
| `peerReady` | Remote receiver announced readiness |
| `active` | Handshake complete and heartbeats current |
| `disconnected` | A known peer is no longer active |
| `failed` | Connection setup or the active session failed |

A cable attachment alone is not an active connection.

## Transfer guarantees

- Incoming destinations are constrained to the configured directory.
- Incoming bytes are written to a hidden partial file.
- Byte count and SHA-256 are verified before finalization.
- Completion is emitted after the destination is flushed and closed.
- Outgoing completion waits for the receiver's verified acknowledgement.
- Event streams are broadcast streams.

## Platform setup

Native preparation is required for production integration:

- Android may request USB accessory permission.
- A sandboxed macOS application needs the USB device entitlement.
- iOS transfer requires a trusted physical connection to macOS and the iOS app
  must remain in the foreground.
- Windows and Linux currently return explicit transport-unavailable errors.
- Web reports unsupported transfer capability rather than failing plugin
  registration.

Read the complete
[platform setup guide](https://github.com/Ares-Defence-Labs/ares_bridge/blob/main/ares_bridge/doc/platform-setup.md)
before shipping.

## Documentation

- [Complete getting-started guide](https://github.com/Ares-Defence-Labs/ares_bridge/blob/main/ares_bridge/doc/getting-started.md)
- [Dart API reference](https://github.com/Ares-Defence-Labs/ares_bridge/blob/main/ares_bridge/doc/api-reference.md)
- [Events and errors](https://github.com/Ares-Defence-Labs/ares_bridge/blob/main/ares_bridge/doc/events-and-errors.md)
- [Platform-channel contract](https://github.com/Ares-Defence-Labs/ares_bridge/blob/main/ares_bridge/doc/platform-channel-contract.md)
- [Protocol and security](https://github.com/Ares-Defence-Labs/ares_bridge/blob/main/ares_bridge/doc/protocol-and-security.md)
- [Troubleshooting](https://github.com/Ares-Defence-Labs/ares_bridge/blob/main/ares_bridge/doc/troubleshooting.md)

## Requirements

- Dart `^3.12.2`
- Flutter `>=3.3.0`
- iOS 13.0 or later
- macOS 10.15.4 or later

## License

See [LICENSE](LICENSE).
