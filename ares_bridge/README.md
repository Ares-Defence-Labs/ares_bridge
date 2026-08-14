# Ares Bridge

USB peer discovery and checksum-verified, bidirectional file transfer for
Flutter.

Ares Bridge gives Flutter applications one typed Dart API across desktop host
and mobile accessory roles. It handles peer readiness, handshakes, heartbeats,
streamed file transfer, safe destination paths, collision policy, SHA-256
verification, and terminal acknowledgements behind platform-neutral streams.

> **Implementation status:** Android, macOS, and the macOS↔iOS physical USB
> path are implemented. Windows and Linux register the API but do not yet link
> a native transport. Web supports capability detection only.

## Documentation

| Guide | Use it for |
| --- | --- |
| [Getting started](docs/getting-started.md) | Installation and a complete lifecycle example |
| [API reference](docs/api-reference.md) | Every public type, method, field, and enum |
| [Platform setup](docs/platform-setup.md) | Android, macOS, iOS, Windows, Linux, and web notes |
| [Events and errors](docs/events-and-errors.md) | State transitions, terminal events, and error handling |
| [Platform channel contract](docs/platform-channel-contract.md) | Native backend method and event schemas |
| [Protocol and security](docs/protocol-and-security.md) | Wire frames, verification, filesystem safety, and trust boundary |
| [Troubleshooting](docs/troubleshooting.md) | Symptoms, causes, and practical checks |

Run `dart doc` in this directory for browsable HTML generated directly from
the source-level API comments.

## Platform support

| Platform | Natural role | Discovery / transport | Current support |
| --- | --- | --- | --- |
| Android | USB accessory | `UsbManager` + Android Open Accessory | Full bidirectional transfer |
| macOS | USB host | `IOUSBHost` (Android), usbmuxd (paired iOS) | Full bidirectional transfer |
| iOS | USB accessory | Foreground loopback listener tunneled by usbmuxd | Full while app is foreground |
| Windows | USB host | API registered; WinUSB/AOA not linked | Capability and explicit errors |
| Linux | USB host | API registered; libusb/AOA not linked | Capability and explicit errors |
| Web | — | No portable background AOA transport | Capability reporting only |

Always call `getCapabilities()` before showing transfer controls.

## Quick start

```dart
import 'dart:async';

import 'package:ares_bridge/ares_bridge.dart';
import 'package:flutter/services.dart';

final bridge = AresBridge();
final subscriptions = <StreamSubscription<Object?>>[];

Future<void> startBridge() async {
  final capabilities = await bridge.getCapabilities();
  if (!capabilities.isSupported) {
    throw UnsupportedError(capabilities.reason ?? 'USB transfer unavailable');
  }

  subscriptions.add(
    bridge.connectionEvents.listen((event) {
      print('Connection: ${event.state.name}');
    }),
  );
  subscriptions.add(
    bridge.transferProgress.listen((event) {
      print('${event.fileName}: ${(event.fraction * 100).toStringAsFixed(1)}%');
    }),
  );
  subscriptions.add(
    bridge.receivedFiles.listen((event) {
      print('Verified file: ${event.localPath}');
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
      ),
    );
    await bridge.startListening();
  } on PlatformException catch (error) {
    print('${error.code}: ${error.message}');
    rethrow;
  }
}
```

Send only after the connection reaches `AresConnectionState.active`:

```dart
final transferId = await bridge.sendFile(
  AresFileTransferRequest(
    sourcePath: '/absolute/path/report.pdf',
    destinationPath: 'reports/report.pdf',
    metadata: const {'origin': 'drag-drop'},
  ),
);
```

`sendFile` and `sendFiles` return when native code accepts the work—not when
the receiver has persisted it. Match `transferId` against `completedTransfers`
or `failedTransfers` for the terminal result.

## Core guarantees

- A cable attachment alone is never reported as an active connection.
- Incoming paths are constrained to the configured destination directory.
- File bytes are first written to a hidden partial file.
- Completion follows flush, close, byte-count validation, and SHA-256
  verification.
- The sender completes only after the receiver acknowledges verified storage.
- All typed event streams are broadcast streams.

## Requirements

- Dart `^3.12.2`
- Flutter `>=3.3.0`
- iOS 13.0 or later
- macOS 10.15.4 or later

See [Platform setup](docs/platform-setup.md) before integrating a native build.

## License

See [LICENSE](LICENSE).
