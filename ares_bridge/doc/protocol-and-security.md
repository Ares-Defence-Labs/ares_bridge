# Protocol and security

This page documents the implemented version 1 native transport contract. It is
useful for backend maintainers, security review, and interoperability work. App
code should use the typed Dart API instead of constructing frames.

## Topology

- Android behaves as an Android Open Accessory endpoint.
- macOS behaves as USB host for Android and as the usbmuxd client for iOS.
- iOS exposes a foreground-only loopback listener reached by the paired Mac's
  physical USB tunnel.
- Windows and Linux do not yet implement frame transport.

## Session lifecycle

1. Each endpoint begins listening/discovery.
2. The physical transport opens.
3. Peers exchange identity and protocol-version handshake data.
4. Receiver readiness is announced.
5. Heartbeats keep the session active.
6. A file manifest begins a transfer.
7. Ordered chunks carry payload bytes.
8. The receiver validates the terminal byte count and SHA-256 digest.
9. The receiver atomically exposes the final file and acknowledges it.
10. Only then does the sender emit outgoing completion.

Missing current heartbeats move the peer out of the active state.

## Frame format

Frames use this logical layout:

```text
ARES magic | version | message type | JSON header length | payload length
JSON header bytes
optional binary payload bytes
```

Protocol constants:

| Item | Value |
| --- | --- |
| Magic | `ARES` (`0x41524553`) |
| Protocol version | `1` |
| Maximum JSON header | 1 MiB |
| Maximum individual payload | 16 MiB |

Message types:

| Name | Numeric type | Purpose |
| --- | ---: | --- |
| `hello` | 1 | Identity/version handshake |
| `ready` | 2 | Receiver readiness |
| `heartbeat` | 3 | Session liveness |
| `fileBegin` | 16 | File manifest and transfer start |
| `fileChunk` | 17 | Ordered payload bytes |
| `fileEnd` | 18 | Terminal size/digest declaration |
| `fileAcknowledgement` | 19 | Verified receiver completion |
| `fileError` | 20 | Transfer-specific rejection/failure |

Unknown versions, malformed lengths, invalid state transitions, and unexpected
messages are protocol violations and should close or fail the affected session.

## Filesystem safety

Implemented receivers apply these protections:

- `destinationPath` is treated as relative to `incomingDirectory`.
- Traversal that escapes the configured root is rejected.
- Incoming bytes go to a hidden `.part` file.
- The expected byte count is checked.
- SHA-256 is verified.
- The overwrite policy is applied at finalization.
- The verified file is atomically exposed before completion is emitted.

Applications should still treat received files as untrusted content. A correct
hash proves transport integrity against the announced digest; it does not prove
that the sender or file is benign.

## Physical-path constraints

Android transfer uses the physical AOA USB connection. The iOS listener binds
only to loopback, checks the accepted loopback peer, and is reached through the
paired physical usbmuxd device tunnel. The macOS client filters out
network-attached devices.

These controls restrict the implemented path but do not provide application-
level peer authentication or payload encryption.

## Trust model

Protocol version 1 has important boundaries:

- Peer IDs and names are application-level handshake claims, not cryptographic
  identities.
- SHA-256 detects corruption or mismatch; it is not a signature.
- Payload confidentiality depends on physical USB access and platform pairing/
  trust, not end-to-end application encryption.
- Metadata is supplied by the peer and must be validated before use.
- File content requires normal malware/content validation appropriate to the
  product.

For higher-assurance deployments, add an authenticated handshake and signed or
AEAD-protected frames in a future protocol version. Version negotiation should
fail closed when peers do not share a supported secure mode.

## Backend invariants

Any future Windows, Linux, or third-party backend should preserve these rules:

- honest capability reporting;
- no `active` state before handshake and live heartbeat;
- unique transfer IDs scoped so concurrent work cannot collide;
- strict length and frame-bound validation before allocation;
- bounded payload/header sizes;
- safe relative destination resolution;
- partial-file cleanup on failure/cancellation;
- completion only after verification, finalization, and acknowledgement;
- terminal failure events with stable machine-readable codes.
