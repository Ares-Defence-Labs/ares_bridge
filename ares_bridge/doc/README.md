# Ares Bridge documentation

This documentation describes the public Dart API in `package:ares_bridge`, its
native platform behavior, and protocol guarantees.

## Start here

1. [Getting started](getting-started.md) — install, initialize, listen, send,
   receive, and clean up.
2. [Platform setup](platform-setup.md) — add the required native configuration
   and understand support boundaries.
3. [API reference](api-reference.md) — look up every public Dart symbol.
4. [Events and errors](events-and-errors.md) — build reliable UI and retry
   behavior.
5. [Platform channel contract](platform-channel-contract.md) — implement or
   review the native method and event maps.
6. [Protocol and security](protocol-and-security.md) — understand transport,
   verification, and trust assumptions.
7. [Troubleshooting](troubleshooting.md) — diagnose connection and transfer
   failures.

## Lifecycle at a glance

```text
getCapabilities
      │
      ▼
  initialize ──────► startListening ──────► active
                                              │
                                   sendFile / receive
                                              │
                              completed or failed event
                                              │
                         stopListening or dispose
```

Subscribe to event streams before `startListening()` so the application does
not miss early listener or connection transitions.

## Generated API documentation

The Dart source contains reference comments for public libraries, classes,
members, enum values, validation, and asynchronous semantics. Generate the
HTML reference locally with:

```console
cd ares_bridge
dart doc
open doc/api/index.html
```

Generated output belongs in `doc/api/` and does not need to be committed.
