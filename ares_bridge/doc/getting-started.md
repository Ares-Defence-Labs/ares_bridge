# Getting started

This guide shows a production-safe lifecycle: detect support, subscribe before
starting, wait for an active peer, send files, observe terminal results, and
release resources.

## 1. Add the package

For a local checkout:

```yaml
dependencies:
  ares_bridge:
    path: ../ares_bridge
```

Then resolve dependencies:

```console
flutter pub get
```

Import the public library only:

```dart
import 'package:ares_bridge/ares_bridge.dart';
```

## 2. Create a bridge and subscribe

Event streams are broadcast streams. Subscribe before calling
`startListening()` to capture the initial `listening`, `connecting`, or
`failed` event.

```dart
import 'dart:async';

import 'package:ares_bridge/ares_bridge.dart';
import 'package:flutter/services.dart';

class TransferController {
  final AresBridge bridge = AresBridge();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  bool _active = false;

  Future<void> start() async {
    final capabilities = await bridge.getCapabilities();
    if (!capabilities.isSupported) {
      throw UnsupportedError(
        capabilities.reason ?? '${capabilities.platform} is unsupported',
      );
    }

    _subscriptions.add(
      bridge.connectionEvents.listen((event) {
        _active = event.isActive;
        // Update connection UI from event.state, peerName, and message.
      }),
    );
    _subscriptions.add(
      bridge.transferProgress.listen((event) {
        // Index UI state by event.transferId; batches can run concurrently.
      }),
    );
    _subscriptions.add(
      bridge.completedTransfers.listen((event) {
        // Incoming and outgoing terminal success.
      }),
    );
    _subscriptions.add(
      bridge.failedTransfers.listen((event) {
        // Terminal failure: show event.message and use event.code for logic.
      }),
    );

    await bridge.initialize(
      const AresBridgeConfiguration(
        role: AresBridgeRole.automatic,
        localPeerName: 'Warehouse Mac',
        overwritePolicy: AresOverwritePolicy.rename,
      ),
    );
    await bridge.startListening();
  }

  Future<String> send(String absolutePath) async {
    if (!_active) {
      throw StateError('Wait for AresConnectionState.active before sending.');
    }
    return bridge.sendFile(AresFileTransferRequest(sourcePath: absolutePath));
  }

  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await bridge.dispose();
  }
}
```

Catch immediate native command failures separately from asynchronous transfer
failures:

```dart
try {
  await controller.start();
} on PlatformException catch (error) {
  // Machine-readable command failure: error.code.
  // Diagnostic text: error.message.
}
```

## 3. Understand connection readiness

`startListening()` completes when native listening has been requested. It does
not wait for a peer. Only `AresConnectionState.active` means that the handshake
has completed and current heartbeats confirm a live peer.

Typical successful progression:

```text
listening → connecting → peerReady → active
```

The exact order can vary slightly as each endpoint reports local and remote
readiness. Treat states as snapshots, not as a guaranteed exhaustive sequence.

## 4. Send one file

`sourcePath` must be an absolute path accessible to the native application.
`destinationPath`, when set, is relative to the receiver's configured incoming
directory.

```dart
final id = await bridge.sendFile(
  AresFileTransferRequest(
    sourcePath: '/Users/me/Exports/invoice.pdf',
    destinationPath: 'invoices/2026/invoice.pdf',
    metadata: const {
      'origin': 'export-screen',
      'documentKind': 'invoice',
    },
  ),
);
```

The returned ID means the request was accepted for processing. Observe a
terminal event with the same ID:

```dart
final result = await bridge.events.firstWhere(
  (event) =>
      (event is AresTransferCompleted && event.transferId == id) ||
      (event is AresTransferFailed && event.transferId == id),
);
```

Create the event future or maintain a central event store before calling
`sendFile()` if completion might be very fast.

## 5. Send a batch

```dart
final ids = await bridge.sendFiles([
  for (final path in droppedPaths)
    AresFileTransferRequest(
      sourcePath: path,
      metadata: const {'origin': 'drag-drop'},
    ),
]);
```

IDs correspond to requests by index. Track each independently; the public API
does not define a single all-or-nothing batch transaction.

## 6. Receive files

Use `receivedFiles` when only incoming success matters:

```dart
bridge.receivedFiles.listen((event) {
  final localPathOrUri = event.localPath;
  // Safe to refresh UI: verification and finalization have completed.
});
```

The default incoming directory is platform-specific:

- Android: application files under `ares_bridge/incoming`.
- macOS: Application Support under `usb-bridge/incoming`.
- iOS: Documents under `AresBridge/incoming`.

Override it with `AresBridgeConfiguration.incomingDirectory` where appropriate.

## 7. Cancel, stop, and dispose

```dart
await bridge.cancelTransfer(id);
await bridge.stopListening(); // May start again later.
await bridge.dispose();       // Final cleanup; do not reuse this instance.
```

Cancel subscriptions before `dispose()`. In a Flutter `State`, initiate cleanup
from `dispose()` but remember that the framework method itself cannot be
`async`; a controller or application service can own awaited shutdown.

## Configuration recommendations

- Keep `role` as `automatic` unless topology must be enforced.
- Provide a stable `localPeerId` if peer identity matters across reinstalls or
  hardware name changes.
- Set `localPeerName` to a user-recognizable device name.
- Keep the default 64 KiB chunk size unless profiling justifies a change.
- Keep `peerTimeout` comfortably larger than `heartbeatInterval`.
- Prefer `rename` when preserving existing received files is more important
  than deterministic destination names.
