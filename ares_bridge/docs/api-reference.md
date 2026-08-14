# Dart API reference

Import:

```dart
import 'package:ares_bridge/ares_bridge.dart';
```

This page is a compact semantic reference. `dart doc` produces the linked,
symbol-by-symbol HTML reference from source comments.

## `AresBridge`

The application-facing facade. A bridge owns a native transport session and
exposes broadcast event streams.

| Member | Result | Semantics |
| --- | --- | --- |
| `events` | `Stream<AresBridgeEvent>` | Every typed bridge event |
| `connectionEvents` | `Stream<AresConnectionEvent>` | Listener and peer state only |
| `transferProgress` | `Stream<AresTransferProgress>` | Incoming and outgoing progress snapshots |
| `completedTransfers` | `Stream<AresTransferCompleted>` | All terminal successes |
| `receivedFiles` | `Stream<AresTransferCompleted>` | Incoming terminal successes only |
| `failedTransfers` | `Stream<AresTransferFailed>` | All terminal transfer failures |
| `getCapabilities()` | `Future<AresBridgeCapabilities>` | Reads actual backend support; safe before initialization |
| `initialize([configuration])` | `Future<void>` | Applies configuration before listening |
| `startListening()` | `Future<void>` | Requests listening; connection completes through events |
| `stopListening()` | `Future<void>` | Closes the session but permits later restart |
| `sendFile(request)` | `Future<String>` | Accepts one request and returns its transfer ID |
| `sendFiles(requests)` | `Future<List<String>>` | Accepts multiple requests; IDs preserve input order |
| `cancelTransfer(id)` | `Future<void>` | Cancels queued or active work |
| `dispose()` | `Future<void>` | Releases the native session permanently for this instance |

### Asynchronous contract

The send futures resolve on native acceptance. They are not delivery receipts.
Delivery succeeds only when an `AresTransferCompleted` with the same ID arrives.
A command can fail immediately with `PlatformException`; accepted work can fail
later with `AresTransferFailed`.

## `AresBridgeConfiguration`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `role` | `AresBridgeRole` | `automatic` | Native backend selects its natural role |
| `localPeerId` | `String?` | generated/loaded natively | Stable identity announced during handshake |
| `localPeerName` | `String?` | platform device name | Human-readable peer label |
| `incomingDirectory` | `String?` | platform-specific | Native filesystem directory for current backends |
| `overwritePolicy` | `AresOverwritePolicy` | `rename` | Collision behavior for incoming files |
| `chunkSizeBytes` | `int` | `65536` | Must be positive; protocol maximum is 16 MiB |
| `heartbeatInterval` | `Duration` | 2 seconds | Must be positive in native implementations |
| `peerTimeout` | `Duration` | 8 seconds | Must be greater than heartbeat interval |

`toMap()` is public for platform implementors. It includes protocol version 1
and expresses durations in milliseconds.

## `AresBridgeCapabilities`

| Field | Meaning |
| --- | --- |
| `platform` | Lowercase backend name |
| `isSupported` | A usable transport is currently implemented |
| `supportsUsbHost` | Backend can own and initiate USB |
| `supportsUsbAccessory` | Backend can participate as accessory |
| `supportsBidirectionalTransfer` | Active peers can both send and receive |
| `reason` | User-readable explanation when unsupported |

Use the feature booleans rather than inferring support from `Platform`.

## `AresFileTransferRequest`

| Field | Required | Meaning |
| --- | --- | --- |
| `sourcePath` | yes | Absolute, native-readable sender path |
| `destinationPath` | no | Relative path below the receiver's incoming directory |
| `metadata` | no | Immutable application-defined string map sent in the manifest |

Construction rejects an empty `sourcePath` and an empty non-null
`destinationPath`. Native acceptance can still fail if the source does not
exist, is not a regular file, is unreadable, or the destination is unsafe.

## Roles and policies

### `AresBridgeRole`

- `automatic` — backend selects the natural role.
- `usbHost` — desktop-style endpoint that owns the USB connection.
- `usbAccessory` — mobile-style endpoint attached to a host.

Unsupported explicit roles produce a configuration error.

### `AresOverwritePolicy`

- `reject` — fail if the final destination exists.
- `replace` — replace the destination after the new file verifies.
- `rename` — preserve the existing file and select a unique final name.

## Connection events

`AresConnectionEvent` fields:

| Field | Meaning |
| --- | --- |
| `state` | Current `AresConnectionState` |
| `localRole` | Role selected by the backend |
| `peerId` | Stable remote identity when handshake data is known |
| `peerName` | Human-readable remote name when known |
| `message` | Optional diagnostic, especially for failures |
| `timestamp` | UTC native event creation time |
| `isActive` | Convenience getter for `state == active` |

Connection states are `stopped`, `listening`, `peerReady`, `connecting`,
`active`, `disconnected`, and `failed`. See
[Events and errors](events-and-errors.md) for transitions and UI guidance.

## Progress events

`AresTransferProgress` fields:

| Field | Meaning |
| --- | --- |
| `transferId` | Correlation ID for this transfer |
| `direction` | `incoming` or `outgoing` relative to this endpoint |
| `stage` | `queued`, `negotiating`, `transferring`, or `verifying` |
| `fileName` | Display name of the file |
| `bytesTransferred` | Payload bytes processed so far |
| `totalBytes` | Expected payload size |
| `bytesPerSecond` | Optional recent throughput estimate |
| `estimatedTimeRemaining` | Optional ETA |
| `fraction` | Clamped 0–1 progress; zero for non-positive total size |
| `timestamp` | UTC native event creation time |

Progress is a snapshot and may be throttled; do not assume one event per chunk.

## Completion events

`AresTransferCompleted` is a terminal success:

| Field | Meaning |
| --- | --- |
| `transferId` | Correlation ID |
| `direction` | Incoming or outgoing |
| `fileName` | Display name |
| `bytesTransferred` | Verified byte count |
| `localPath` | Final local path or URI when applicable |
| `remotePath` | Receiver path acknowledged to the sender when available |
| `destinationPath` | Relative path originally requested for incoming work |
| `sha256` | Lowercase hexadecimal digest when supplied |
| `timestamp` | UTC native event creation time |

For incoming work, completion follows destination flush/close and verification.
For outgoing work, it follows the receiver acknowledgement.

## Failure events

`AresTransferFailed` is a terminal failure:

| Field | Meaning |
| --- | --- |
| `transferId` | Correlation ID |
| `direction` | Incoming or outgoing |
| `code` | Machine-readable failure category |
| `message` | Human-readable diagnostic |
| `fileName` | File name when known |
| `recoverable` | Whether an unchanged retry may succeed |
| `timestamp` | UTC native event creation time |

Do not parse `message`; branch on `code` and `recoverable`.

## Platform interface

`AresBridgePlatform` is the extension point for tests or another transport.
Backends must:

- emit maps compatible with `AresBridgeEvent.fromPlatformEvent`;
- preserve transfer-ID ordering for batches;
- expose honest capabilities;
- provide broadcast events;
- never emit completion before final storage and verification;
- reject destination traversal outside the incoming root.

`MethodChannelAresBridge` is the default backend and uses
`ares_bridge/methods` and `ares_bridge/events`. `AresBridgeWeb` implements
capability reporting and explicit unsupported behavior. See the complete
[platform channel contract](platform-channel-contract.md) when implementing a
native backend.
