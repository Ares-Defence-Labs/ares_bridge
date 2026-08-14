# Events and errors

Ares Bridge has two failure surfaces:

1. A method future can fail immediately because a command is invalid or cannot
   be accepted.
2. Accepted transfer work can later end in `AresTransferFailed`.

Handle both.

## Connection states

| State | Meaning | Recommended UI |
| --- | --- | --- |
| `stopped` | Listener/session is closed | Show Start or Connect |
| `listening` | Local receiver is waiting | Show Waiting for device |
| `peerReady` | Remote receiver announced readiness | Keep controls pending |
| `connecting` | Physical transport/handshake is progressing | Show Connecting |
| `active` | Handshake complete and heartbeats current | Enable send controls |
| `disconnected` | Known peer is no longer active | Disable sends; allow reconnect |
| `failed` | Connection setup or session failed | Show `message`; allow retry where sensible |

Never infer `active` from cable presence. Only the typed active event is the
send-ready signal.

Events are snapshots. Reconnection can produce repeated states, and platform
timing can vary. UI state reducers should accept idempotent updates.

## Transfer stages

| Stage | Meaning |
| --- | --- |
| `queued` | Native layer accepted the request |
| `negotiating` | Sender and receiver are deciding manifest/destination |
| `transferring` | Payload bytes are moving |
| `verifying` | Receiver is checking byte count and SHA-256 |

Treat `fraction` as presentation data, not a transaction boundary. The
receiver can still reject or fail while verifying at 100% payload progress.

## Terminal event correlation

Maintain transfer state by ID:

```dart
bridge.events.listen((event) {
  switch (event) {
    case AresTransferProgress(:final transferId):
      transfers[transferId] = event;
    case AresTransferCompleted(:final transferId):
      transfers[transferId] = event; // Terminal success.
    case AresTransferFailed(:final transferId):
      transfers[transferId] = event; // Terminal failure.
    case AresConnectionEvent():
      connection = event;
  }
});
```

For outgoing files, completion is emitted only after the peer acknowledges its
verified destination. For incoming files, `localPath` is usable only after the
completion event.

## Immediate command errors

Native platforms report method failures as Flutter `PlatformException` values.
Codes currently used by one or more native backends include:

| Code | Meaning |
| --- | --- |
| `invalid_argument` | Method arguments did not match the channel contract |
| `invalid_configuration` | Heartbeat, timeout, chunk size, role, or another setting is invalid |
| `unsupported_role` | Requested USB role cannot be used on this platform |
| `not_initialized` | `startListening()` was called before `initialize()` |
| `not_connected` | No active, handshake-complete peer is available |
| `transfer_rejected` | Native code could not accept the file request |
| `transport_unavailable` | Platform API is present but no transport is linked |
| `usb_transport_error` | Native USB/socket/protocol operation failed |

Web uses `UnsupportedError` for unsupported transport operations. A missing or
incorrect plugin registration can surface as `MissingPluginException`.

Example:

```dart
try {
  await bridge.startListening();
} on PlatformException catch (error) {
  switch (error.code) {
    case 'not_initialized':
      // Correct the application lifecycle.
    case 'transport_unavailable':
      // Disable this platform's USB UI.
    default:
      // Log error.code and error.message.
  }
}
```

## Asynchronous transfer failures

Stable transfer failure codes currently emitted by native sessions include:

| Code | Meaning |
| --- | --- |
| `verification_failed` | Byte count or SHA-256 did not match |
| `send_failed` | Sender could not read or stream the file |
| `cancelled` | Sender cancelled the transfer before completion |
| `peer_error` | Peer reported a failure without a more specific code |

Peer-provided codes can also be forwarded. Consumers should preserve unknown
codes in logs and present the event message rather than crashing or discarding
the failure.

`recoverable` is the explicit retry hint. Avoid automatically retrying a
non-recoverable failure or a request that would violate destination policy.

## Stream errors

Malformed or unknown native event maps are decoded as `FormatException` stream
errors. Always provide `onError` on the aggregate stream in diagnostic builds:

```dart
bridge.events.listen(
  handleEvent,
  onError: (Object error, StackTrace stackTrace) {
    // Record backend contract violations.
  },
);
```

## Logging guidance

Log transfer IDs, event codes, stages, platform, and timestamps. Avoid logging
full local paths, metadata, or peer names when they can contain personal or
sensitive information. Do not parse human-readable messages for application
logic.
