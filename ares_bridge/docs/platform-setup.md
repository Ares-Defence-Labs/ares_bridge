# Platform setup

## Support matrix

| Platform | Role | Supported now | Important constraint |
| --- | --- | --- | --- |
| Android | Accessory | Yes | User must grant accessory permission |
| macOS | Host | Yes | USB entitlement when sandboxed; iOS path needs pairing/trust |
| iOS | Accessory | Yes | App must remain in the foreground |
| Windows | Host | No transport | Calls fail honestly instead of simulating success |
| Linux | Host | No transport | Calls fail honestly instead of simulating success |
| Web | — | No transport | Capability detection only |

Call `getCapabilities()` at runtime. A registered plugin is not the same as an
implemented transport.

## Android

The plugin declares `android.hardware.usb.accessory` as an optional feature. It
uses `UsbManager`, dynamically registers attach/detach and permission receivers,
and participates as the Android Open Accessory endpoint.

Use `AresBridgeRole.automatic` or `usbAccessory`. `usbHost` is rejected with
`unsupported_role`.

The first connection can show the Android USB accessory permission prompt. The
application must be in a state where the user can grant it. For automatic app
launch on accessory attachment, the host application—not the plugin library—
must add an `USB_ACCESSORY_ATTACHED` activity intent filter and matching
accessory metadata appropriate to the product identity used by its host.

Default incoming directory:

```text
<application files>/ares_bridge/incoming
```

An explicit `incomingDirectory` must be a filesystem path writable by the
application. The current Android backend does not resolve Storage Access
Framework document-tree URIs.

## macOS

The macOS backend is a composite host transport:

- Android devices use Android Open Accessory negotiation over `IOUSBHost` and
  bulk endpoints after accessory re-enumeration.
- Paired iOS devices are discovered through the system usbmuxd daemon and
  tunneled to the iOS foreground loopback listener.

Use `AresBridgeRole.automatic` or `usbHost`. `usbAccessory` is rejected as an
invalid configuration.

When App Sandbox is enabled, add the USB device entitlement to both debug and
release entitlements:

```xml
<key>com.apple.security.device.usb</key>
<true/>
```

The plugin links Apple system frameworks `CryptoKit`, `IOKit`, and `IOUSBHost`
and requires macOS 10.15.4 or later.

Android debugging can retain exclusive ownership of a connected device. If AOA
negotiation cannot open the device, stop ADB for that device, unlock it, keep
its USB screen visible, and reconnect the cable.

For iPhone transfer, connect by USB, accept the trust/pairing prompts on both
devices, open the iOS application, and keep it in the foreground.

Default incoming directory:

```text
~/Library/Application Support/usb-bridge/incoming
```

## iOS

iOS does not expose a general USB accessory API to third-party apps. This
backend opens a TCP listener on `127.0.0.1:38473`; the trusted macOS host reaches
that listener only through the physical device's usbmuxd tunnel.

Security and lifecycle constraints:

- The listener binds to loopback only.
- The accepted peer is checked as loopback.
- The macOS discovery path filters for USB-attached devices rather than network
  devices.
- Listening and active transfer require the iOS app to remain foregrounded.
- Entering the background closes the listener/session; returning to foreground
  resumes when listening was previously requested.

Use `AresBridgeRole.automatic` or `usbAccessory`. `usbHost` is invalid. The
plugin requires iOS 13.0 or later.

Default incoming directory:

```text
<Documents>/AresBridge/incoming
```

## Windows

The method and event channels are registered, but AOA/WinUSB transport is not
linked in version 0.0.1. `getCapabilities()` reports unsupported.
`startListening()` returns `transport_unavailable`; send commands return
`not_connected`.

Do not present active transfer controls on Windows until capabilities indicate
support.

## Linux

The method and event channels are registered, but AOA/libusb transport is not
linked in version 0.0.1. Behavior mirrors Windows: capability reporting works,
listener startup reports `transport_unavailable`, and sends report
`not_connected`.

## Web

Browsers do not offer a portable background Android Open Accessory transport.
The web backend exists so applications can initialize normally, query
capabilities, and explain the limitation. `startListening()` and send methods
complete with `UnsupportedError`.

## App-level permissions and storage

Ares Bridge can only read and write locations available to the native app
process. The application remains responsible for:

- selecting or copying external files into an accessible location;
- requesting any platform permissions required by its own file picker or
  storage workflow;
- copying picker results into a native-readable path when a content URI is not
  directly supported by the backend;
- choosing a received-file location appropriate for backup and data-protection
  requirements;
- excluding sensitive received data from backups if product policy requires it.
