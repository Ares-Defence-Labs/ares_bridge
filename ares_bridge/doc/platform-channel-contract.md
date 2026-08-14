# Platform channel contract

This is the native backend contract used by `MethodChannelAresBridge`. Flutter
applications should prefer the typed public Dart API. Use this page when
maintaining Android/Apple/desktop implementations or adding another platform.

## Channels

| Channel | Flutter type | Direction |
| --- | --- | --- |
| `ares_bridge/methods` | `MethodChannel` | Dart commands to native code |
| `ares_bridge/events` | `EventChannel` | Native event maps to Dart |

All field names are case-sensitive. Enum values use their Dart `.name` strings.
Unknown methods must return Flutter's not-implemented result. Native command
failures must use a stable error code and diagnostic message.

## Methods

### `getCapabilities`

Arguments: none.

Successful result:

```json
{
  "platform": "android",
  "isSupported": true,
  "supportsUsbHost": false,
  "supportsUsbAccessory": true,
  "supportsBidirectionalTransfer": true,
  "reason": null
}
```

Every key except nullable `reason` is required. `platform` must be non-empty.

### `initialize`

Arguments:

```json
{
  "protocolVersion": 1,
  "role": "automatic",
  "localPeerId": null,
  "localPeerName": "Warehouse Mac",
  "incomingDirectory": null,
  "overwritePolicy": "rename",
  "chunkSizeBytes": 65536,
  "heartbeatIntervalMs": 2000,
  "peerTimeoutMs": 8000
}
```

Successful result: null.

Roles are `automatic`, `usbHost`, and `usbAccessory`. Policies are `reject`,
`replace`, and `rename`. A backend must validate its supported role and require
positive timing/chunk values; peer timeout must exceed heartbeat interval.

### `startListening`

Arguments: none. Successful result: null after the listener request is
accepted. Peer readiness is asynchronous and must be reported through events.

### `stopListening`

Arguments: none. Successful result: null after the local session is closed. A
`connection` event with state `stopped` should be emitted.

### `sendFile`

Arguments:

```json
{
  "sourcePath": "/absolute/sender/path/report.pdf",
  "destinationPath": "reports/report.pdf",
  "metadata": {
    "origin": "drag-drop"
  }
}
```

Successful result: a non-empty transfer ID string.

Acceptance requires an active peer. `destinationPath` is nullable, but if
provided it is relative to the receiver root. `metadata` is a string-to-string
map. The method result acknowledges queue acceptance, not delivery.

### `sendFiles`

Arguments: a list of `sendFile` request maps.

Successful result: a list of non-empty transfer ID strings with exactly the
same length and ordering as the request list. The Dart facade short-circuits an
empty list without invoking native code.

The public API does not promise atomic batch acceptance or completion. Backend
implementations should clearly fail malformed requests rather than returning a
partial or misaligned ID list.

### `cancelTransfer`

Arguments:

```json
{
  "transferId": "non-empty-id"
}
```

Successful result: null. Cancellation is idempotent for unknown/already-ended
work where the backend can safely provide that behavior.

### `dispose`

Arguments: none. Successful result: null after listeners, sessions, timers,
descriptors, temporary work, and other backend resources are released.

## Event envelope

Every event is a map containing:

```json
{
  "type": "connection",
  "timestampMs": 1786719600000
}
```

`type` is a non-empty string. `timestampMs` is an integer Unix timestamp in
milliseconds and is decoded as UTC.

## `connection` event

```json
{
  "type": "connection",
  "timestampMs": 1786719600000,
  "state": "active",
  "localRole": "usbHost",
  "peerId": "android-google-pixel",
  "peerName": "Pixel",
  "message": null
}
```

Required fields: `type`, `timestampMs`, `state`, `localRole`.

Optional fields: `peerId`, `peerName`, `message`.

States: `stopped`, `listening`, `peerReady`, `connecting`, `active`,
`disconnected`, `failed`.

## `transferProgress` event

```json
{
  "type": "transferProgress",
  "timestampMs": 1786719600000,
  "transferId": "d4ee7c...",
  "direction": "outgoing",
  "stage": "transferring",
  "fileName": "report.pdf",
  "bytesTransferred": 1048576,
  "totalBytes": 4194304,
  "bytesPerSecond": 2097152.0,
  "estimatedTimeRemainingMs": 1500
}
```

Required fields: `type`, `timestampMs`, `transferId`, `direction`, `stage`,
`fileName`, `bytesTransferred`, `totalBytes`.

Optional fields: `bytesPerSecond`, `estimatedTimeRemainingMs`.

Directions: `incoming`, `outgoing`. Stages: `queued`, `negotiating`,
`transferring`, `verifying`.

## `transferCompleted` event

```json
{
  "type": "transferCompleted",
  "timestampMs": 1786719600000,
  "transferId": "d4ee7c...",
  "direction": "incoming",
  "fileName": "report.pdf",
  "bytesTransferred": 4194304,
  "localPath": "/receiver/inbox/report.pdf",
  "remotePath": null,
  "destinationPath": "reports/report.pdf",
  "sha256": "0123456789abcdef..."
}
```

Required fields: `type`, `timestampMs`, `transferId`, `direction`, `fileName`,
`bytesTransferred`.

Optional fields: `localPath`, `remotePath`, `destinationPath`, `sha256`.

This event is a strict terminal success. A receiver must flush and close the
file, validate size/digest, apply collision policy, and expose its final
destination first. A sender must wait for the receiver acknowledgement.

## `transferFailed` event

```json
{
  "type": "transferFailed",
  "timestampMs": 1786719600000,
  "transferId": "d4ee7c...",
  "direction": "outgoing",
  "code": "verification_failed",
  "message": "The peer rejected the SHA-256 digest.",
  "fileName": "report.pdf",
  "recoverable": false
}
```

Required fields: `type`, `timestampMs`, `transferId`, `direction`, `code`,
`message`.

Optional fields: `fileName`, `recoverable` (defaults to false in Dart).

Codes must be stable enough for application logic. Messages are diagnostics
and may change. Backends must tolerate peer codes they do not recognize and
forward them safely.

## Decoder strictness

The Dart decoder throws `FormatException` when:

- an event is not a map;
- a required field is absent, empty, or has the wrong type;
- an enum name is unknown;
- the event `type` is unknown.

Optional string fields may be empty because their decoder accepts any string;
native implementations should omit semantically absent values instead.

## Compatibility rules

- Add optional fields for backward-compatible evolution.
- Do not change the type or meaning of existing fields within protocol version
  1.
- Gate new required fields or enum values behind an explicit compatibility
  strategy; older Dart decoders reject unknown event enum names.
- Keep method acceptance distinct from asynchronous delivery completion.
- Keep event timestamps in UTC Unix milliseconds.
