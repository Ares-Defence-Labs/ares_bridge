# ares_bridge

Cross-platform USB peer discovery and bidirectional file transfer for Flutter.

The Dart API is shared by Windows, macOS, and Android. Native transport
backends are implemented behind `AresBridgePlatform`, so applications do not
need platform branches for connection, progress, completion, or failure
handling.

## API status

Every Flutter platform now registers the same method/event-channel API. Query
`getCapabilities()` before presenting USB controls:

| Platform | Role | Current transport |
| --- | --- | --- |
| Android | USB accessory | Implemented with `UsbManager`/`UsbAccessory` |
| macOS | USB host | Implemented with Android Open Accessory and `IOUSBHost` |
| Windows | USB host | API registered; AOA/WinUSB transport not linked yet |
| Linux | USB host | API registered; AOA/libusb transport not linked yet |
| iOS | — | Explicitly unsupported by the OS API |
| Web | — | Explicitly unsupported as a portable background transport |

Unsupported desktop host methods return `transport_unavailable` or
`not_connected` rather than reporting false transfer success. Android and
macOS perform real framed transfers once an Android Open Accessory session is
established.

## Usage

```dart
final bridge = AresBridge();

final capabilities = await bridge.getCapabilities();
if (!capabilities.isSupported) {
  print(capabilities.reason);
  return;
}

await bridge.initialize(
  const AresBridgeConfiguration(
    role: AresBridgeRole.automatic,
    localPeerName: 'Warehouse Mac',
    incomingDirectory: null,
  ),
);

bridge.connectionEvents.listen((event) {
  switch (event.state) {
    case AresConnectionState.peerReady:
      // The remote receiver announced that it is listening.
    case AresConnectionState.active:
      // Handshake complete and heartbeat current.
    default:
      break;
  }
});

bridge.transferProgress.listen((event) {
  print('${event.fileName}: ${event.fraction * 100}%');
  print('ETA: ${event.estimatedTimeRemaining}');
});

bridge.receivedFiles.listen((event) {
  // Fired only after a received file has been closed and verified.
  print('Received ${event.fileName} at ${event.localPath}');
});

await bridge.startListening();
```

Queue paths from a desktop drag-and-drop target:

```dart
final transferIds = await bridge.sendFiles([
  for (final path in droppedPaths)
    AresFileTransferRequest(
      sourcePath: path,
      metadata: const {'origin': 'drag-drop'},
    ),
]);
```

`sendFile` and `sendFiles` return after the native layer accepts the work, not
after the bytes arrive. Observe `completedTransfers`, `receivedFiles`, and
`failedTransfers` for terminal results.

## Connection semantics

The bridge distinguishes these states:

- `listening`: the local receiver is accepting a peer.
- `peerReady`: the remote receiver announced that it is listening.
- `active`: handshake completed and peer heartbeats are current.
- `disconnected`: a previously known peer is no longer active.
- `failed`: the connection failed; `message` may contain diagnostics.

A cable attachment alone is not considered an active connection.

## Event channel contract

Native backends publish maps on `ares_bridge/events`. Every map has `type` and
UTC `timestampMs`. Supported types are:

- `connection`
- `transferProgress`
- `transferCompleted`
- `transferFailed`

Commands are received on `ares_bridge/methods`:

- `initialize`
- `startListening`
- `stopListening`
- `sendFile`
- `sendFiles`
- `cancelTransfer`
- `dispose`

Transfer completion must only be emitted after the destination is flushed and
closed. If a checksum is negotiated, it must also be verified first.

## Android transport

The Android backend:

- detects accessory attachment and detachment;
- requests USB accessory permission;
- announces peer readiness and maintains heartbeats;
- streams files in configured chunks in either direction;
- writes incoming data to a hidden `.part` file;
- prevents destination traversal outside `incomingDirectory`;
- verifies the final byte count and SHA-256 checksum;
- atomically exposes the destination and then emits `receivedFiles`;
- acknowledges receipt before the sender emits completion.

The on-wire protocol version is `1`. Frames use the `ARES` magic, version and
message type bytes, a JSON header length, payload length, JSON header, and
optional binary payload.

## macOS transport

The macOS backend:

- polls the I/O Registry for a compatible Android device;
- negotiates Android Open Accessory mode with product-neutral identity strings;
- discovers the accessory interface's bulk input and output pipes;
- streams the same versioned frames used by Android in both directions;
- handles heartbeats, disconnects, cancellation, safe paths, collision policy,
  byte-count validation, and SHA-256 verification;
- uses only Apple system frameworks (`IOKit`, `IOUSBHost`, and `CryptoKit`).

The host application must include the `com.apple.security.device.usb`
entitlement when App Sandbox is enabled.
