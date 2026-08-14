# Ares Bridge

Cross-platform USB peer discovery and verified, bidirectional file transfer for
Flutter applications.

The Flutter package lives in [`ares_bridge/`](ares_bridge/). Start with the
[package documentation](ares_bridge/README.md), then use the
[documentation index](ares_bridge/docs/README.md) for setup, API reference,
event semantics, protocol details, and troubleshooting.

## Platform status

| Platform | USB role | Status |
| --- | --- | --- |
| Android | Accessory | Implemented with Android Open Accessory |
| macOS | Host | Implemented for Android (AOA) and paired iOS devices (usbmuxd) |
| iOS | Accessory | Foreground listener reached by the macOS host |
| Windows | Host | API registered; transport not yet linked |
| Linux | Host | API registered; transport not yet linked |
| Web | — | Capability reporting only; transfer unsupported |

## Quick start

```yaml
dependencies:
  ares_bridge:
    path: ../ares_bridge/ares_bridge
```

```dart
final bridge = AresBridge();
final capabilities = await bridge.getCapabilities();

if (capabilities.isSupported) {
  await bridge.initialize();
  await bridge.startListening();
}
```

See [Getting started](ares_bridge/docs/getting-started.md) for a complete,
production-ready lifecycle example.
