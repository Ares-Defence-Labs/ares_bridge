import Foundation
import Darwin
import IOKit
import IOUSBHost

final class UsbHostTransport {
  typealias EventHandler = ([String: Any?]) -> Void

  private static let androidVendorId = 0x18D1
  private static let accessoryProductIds: Set<Int> = [0x2D00, 0x2D01]
  private static let pollInterval: TimeInterval = 1

  private let eventHandler: EventHandler
  private let queue = DispatchQueue(label: "usb.bridge.macos.discovery")
  private var configuration: UsbHostConfiguration?
  private var timer: DispatchSourceTimer?
  private var session: UsbHostSession?
  private var switchAttempts: [UInt64: Date] = [:]
  private var lastDiscoveryFailure: String?
  private var adbReleaseStartedAt: Date?
  private var lastAdbStopCommandAt: Date?
  private var listening = false

  init(eventHandler: @escaping EventHandler) {
    self.eventHandler = eventHandler
  }

  var isConnected: Bool {
    queue.sync { session?.isActive == true }
  }

  func initialize(arguments: [String: Any]) throws {
    let parsed = try UsbHostConfiguration(arguments: arguments)
    try FileManager.default.createDirectory(
      atPath: parsed.incomingDirectory,
      withIntermediateDirectories: true
    )
    queue.sync {
      configuration = parsed
    }
  }

  func startListening() throws {
    try queue.sync {
      guard configuration != nil else {
        throw UsbHostError.invalidConfiguration(
          "Call initialize before startListening.")
      }
      guard !listening else { return }
      listening = true
      emitConnection("listening")
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: Self.pollInterval)
      timer.setEventHandler { [weak self] in self?.pollUsbBus() }
      self.timer = timer
      timer.resume()
    }
  }

  func stop() {
    queue.sync {
      listening = false
      timer?.cancel()
      timer = nil
      session?.close()
      session = nil
      switchAttempts.removeAll()
      lastDiscoveryFailure = nil
      adbReleaseStartedAt = nil
      lastAdbStopCommandAt = nil
      emitConnection("stopped")
    }
  }

  func sendFile(_ request: [String: Any]) throws -> String {
    try queue.sync {
      guard let session, session.isActive else { throw UsbHostError.notConnected }
      return try session.sendFile(request)
    }
  }

  func sendFiles(_ requests: [[String: Any]]) throws -> [String] {
    try queue.sync {
      guard let session, session.isActive else { throw UsbHostError.notConnected }
      return try requests.map(session.sendFile)
    }
  }

  func cancelTransfer(_ transferId: String) {
    queue.sync { session?.cancelTransfer(transferId) }
  }

  private func pollUsbBus() {
    guard listening else { return }
    // A newly opened accessory session is not active until Android has opened
    // its accessory descriptor and replied with READY. Keep it alive while that
    // handshake is in progress; UsbHostSession owns the bounded handshake and
    // heartbeat timeouts and calls disconnectedHandler when it really fails.
    if session != nil { return }

    if connectAccessoryInterface() { return }
    requestAccessoryModeIfPossible()
  }

  private func connectAccessoryInterface() -> Bool {
    guard let configuration else { return false }
    let matching = IOServiceMatching(kIOUSBHostInterfaceClassName) as CFDictionary

    for service in services(matching: matching) {
      defer { IOObjectRelease(service) }
      guard intProperty("idVendor", service: service) == Self.androidVendorId,
            Self.accessoryProductIds.contains(
              intProperty("idProduct", service: service)),
            intProperty("bInterfaceNumber", service: service) == 0,
            intProperty("bInterfaceClass", service: service) == 0xFF,
            intProperty("bInterfaceSubClass", service: service) == 0xFF,
            intProperty("bInterfaceProtocol", service: service) == 0 else { continue }
      do {
        let interface = try IOUSBHostInterface(
          __ioService: service,
          options: [],
          queue: nil,
          interestHandler: nil
        )
        let endpoints = try bulkPipes(from: interface)
        let session = UsbHostSession(
          interface: interface,
          inputPipe: endpoints.input,
          outputPipe: endpoints.output,
          configuration: configuration,
          eventHandler: eventHandler,
          disconnectedHandler: { [weak self] in
            self?.queue.async {
              guard let self, self.listening else { return }
              self.session = nil
              self.emitConnection("disconnected")
            }
          }
        )
        self.session = session
        lastDiscoveryFailure = nil
        emitConnection("connecting")
        session.start()
        return true
      } catch {
        emitConnection("failed", message: friendly(error))
      }
    }
    return false
  }

  private func requestAccessoryModeIfPossible() {
    let matching = IOServiceMatching(kIOUSBHostDeviceClassName) as CFDictionary
    let now = Date()
    switchAttempts = switchAttempts.filter { now.timeIntervalSince($0.value) < 30 }

    for service in services(matching: matching) {
      defer { IOObjectRelease(service) }
      let vendor = intProperty("idVendor", service: service)
      let product = intProperty("idProduct", service: service)
      if vendor == Self.androidVendorId,
         Self.accessoryProductIds.contains(product) {
        continue
      }

      // AOA negotiation is a vendor control request and must only be sent to
      // Android devices. Probing every USB peripheral can spend a full timeout
      // on each hub, camera, audio device, and storage interface before the
      // phone is reached.
      guard looksLikeAndroidDevice(service) else { continue }

      let exclusiveOwner = stringProperty(
        "UsbExclusiveOwner",
        service: service
      )
      if exclusiveOwner?.localizedCaseInsensitiveContains("adb") == true {
        releaseDeviceFromAdb(now: now)
        return
      }
      adbReleaseStartedAt = nil
      lastAdbStopCommandAt = nil

      var registryId: UInt64 = 0
      guard IORegistryEntryGetRegistryEntryID(service, &registryId) == KERN_SUCCESS,
            switchAttempts[registryId] == nil else { continue }

      do {
        let controlObject: IOUSBHostObject
        do {
          controlObject = try IOUSBHostDevice(
            __ioService: service,
            options: [],
            queue: nil,
            interestHandler: nil
          )
        } catch {
          // A sandboxed app with the USB entitlement may claim an interface,
          // but macOS can reject ownership of the entire device. Android Open
          // Accessory requests use endpoint zero, which IOUSBHost exposes on
          // either object, so fall back to an unclaimed child interface.
          controlObject = try openControlInterface(for: service)
        }
        defer { controlObject.destroy() }
        let protocolVersion = try accessoryProtocolVersion(controlObject)
        guard protocolVersion > 0 else {
          reportDiscoveryFailure(
            "Android device found, but it did not respond to Android Open " +
              "Accessory negotiation. Unlock the device, keep its USB screen " +
              "open, and reconnect the cable."
          )
          return
        }
        switchAttempts[registryId] = now
        try enterAccessoryMode(controlObject)
        lastDiscoveryFailure = nil
        emitConnection(
          "connecting",
          message: "Compatible Android device found. Waiting for accessory mode."
        )
        return
      } catch {
        reportDiscoveryFailure(
          "Android device found, but macOS could not open its USB interface: " +
            "\(friendly(error))"
        )
        return
      }
    }
  }

  private func openControlInterface(for deviceService: io_service_t) throws
    -> IOUSBHostInterface {
    let vendor = intProperty("idVendor", service: deviceService)
    let product = intProperty("idProduct", service: deviceService)
    let location = intProperty("locationID", service: deviceService)
    let matching = IOServiceMatching(kIOUSBHostInterfaceClassName) as CFDictionary

    for service in services(matching: matching) {
      defer { IOObjectRelease(service) }
      guard intProperty("idVendor", service: service) == vendor,
            intProperty("idProduct", service: service) == product,
            intProperty("locationID", service: service) == location else { continue }
      do {
        return try IOUSBHostInterface(
          __ioService: service,
          options: [],
          queue: nil,
          interestHandler: nil
        )
      } catch {
        continue
      }
    }
    throw UsbHostError.transport(
      "macOS did not expose an available Android USB interface."
    )
  }

  private func accessoryProtocolVersion(_ device: IOUSBHostObject) throws -> UInt16 {
    let data = NSMutableData(length: 2)!
    var transferred = 0
    let request = IOUSBDeviceRequest(
      bmRequestType: 0xC0,
      bRequest: 51,
      wValue: 0,
      wIndex: 0,
      wLength: 2
    )
    try device.__send(
      request,
      data: data,
      bytesTransferred: &transferred,
      completionTimeout: 1
    )
    guard transferred == 2 else { return 0 }
    let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
    return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
  }

  private func enterAccessoryMode(_ device: IOUSBHostObject) throws {
    let strings = [
      "Open USB Tools",
      "USB File Transfer",
      "Bidirectional USB file transfer",
      "1.0",
      "https://developer.android.com/accessories",
      configuration?.localPeerId ?? UUID().uuidString,
    ]
    for (index, value) in strings.enumerated() {
      var bytes = Array(value.utf8.prefix(255))
      bytes.append(0)
      let data = NSMutableData(bytes: &bytes, length: bytes.count)
      var transferred = 0
      let request = IOUSBDeviceRequest(
        bmRequestType: 0x40,
        bRequest: 52,
        wValue: 0,
        wIndex: UInt16(index),
        wLength: UInt16(bytes.count)
      )
      try device.__send(
        request,
        data: data,
        bytesTransferred: &transferred,
        completionTimeout: 1
      )
      guard transferred == bytes.count else {
        throw UsbHostError.transport("Unable to send the AOA identity strings.")
      }
    }

    let startRequest = IOUSBDeviceRequest(
      bmRequestType: 0x40,
      bRequest: 53,
      wValue: 0,
      wIndex: 0,
      wLength: 0
    )
    var transferred = 0
    try device.__send(
      startRequest,
      data: nil,
      bytesTransferred: &transferred,
      completionTimeout: 1
    )
  }

  /// Asks the already-running local ADB server to shut itself down using the
  /// documented ADB framing protocol. This avoids spawning `adb` or a shell,
  /// both of which are unreliable from a sandboxed desktop application.
  private func releaseDeviceFromAdb(now: Date) {
    if adbReleaseStartedAt == nil {
      adbReleaseStartedAt = now
      lastDiscoveryFailure = nil
      emitConnection(
        "connecting",
        message: "Android device found. Releasing debugging for USB transfer."
      )
    }

    if lastAdbStopCommandAt == nil ||
       now.timeIntervalSince(lastAdbStopCommandAt!) >= 2 {
      lastAdbStopCommandAt = now
      _ = sendAdbHostKill()
    }

    guard let startedAt = adbReleaseStartedAt,
          now.timeIntervalSince(startedAt) >= 8 else { return }
    reportDiscoveryFailure(
      "Android Debug Bridge is still using this device. Close any active " +
        "Android Studio debugging session, then press Retry."
    )
  }

  private func sendAdbHostKill() -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var timeout = timeval(tv_sec: 0, tv_usec: 350_000)
    withUnsafePointer(to: &timeout) { pointer in
      _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_SNDTIMEO,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
      _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(5037).bigEndian
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
      return false
    }

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        )
      }
    }
    guard connected == 0 else { return false }

    let command = "host:kill"
    let packet = String(format: "%04X", command.utf8.count) + command
    let bytes = Array(packet.utf8)
    let sent = bytes.withUnsafeBytes { buffer in
      Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
    }
    return sent == bytes.count
  }

  private func bulkPipes(
    from interface: IOUSBHostInterface
  ) throws -> (input: IOUSBHostPipe, output: IOUSBHostPipe) {
    var input: IOUSBHostPipe?
    var output: IOUSBHostPipe?
    for endpointNumber in 1...15 {
      for address in [endpointNumber, endpointNumber | 0x80] {
        guard let pipe = try? interface.copyPipe(withAddress: address) else { continue }
        let descriptor = pipe.descriptors.pointee.descriptor
        guard IOUSBGetEndpointType(withUnsafePointer(to: descriptor) { $0 })
                == UInt8(kIOUSBEndpointTypeBulk.rawValue) else { continue }
        if address & 0x80 == 0x80, input == nil { input = pipe }
        if address & 0x80 == 0, output == nil { output = pipe }
      }
    }
    guard let input, let output else {
      interface.destroy()
      throw UsbHostError.transport(
        "The Android accessory interface has no bidirectional bulk endpoints.")
    }
    return (input, output)
  }

  private func services(matching: CFDictionary) -> [io_service_t] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator)
            == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [io_service_t] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == IO_OBJECT_NULL { break }
      result.append(service)
    }
    return result
  }

  private func intProperty(_ key: String, service: io_service_t) -> Int {
    let searchOptions = IOOptionBits(
      kIORegistryIterateRecursively | kIORegistryIterateParents)
    guard let value = IORegistryEntrySearchCFProperty(
      service,
      kIOServicePlane,
      key as CFString,
      kCFAllocatorDefault,
      searchOptions
    ) as? NSNumber else { return 0 }
    return value.intValue
  }

  private func stringProperty(
    _ key: String,
    service: io_service_t
  ) -> String? {
    let searchOptions = IOOptionBits(
      kIORegistryIterateRecursively | kIORegistryIterateParents)
    return IORegistryEntrySearchCFProperty(
      service,
      kIOServicePlane,
      key as CFString,
      kCFAllocatorDefault,
      searchOptions
    ) as? String
  }

  private func looksLikeAndroidDevice(_ service: io_service_t) -> Bool {
    let description = [
      stringProperty("USB Product Name", service: service),
      stringProperty("kUSBProductString", service: service),
      stringProperty("USB Vendor Name", service: service),
    ]
      .compactMap { $0 }
      .joined(separator: " ")
      .lowercased()
    return description.contains("android") || description.contains("google")
  }

  private func reportDiscoveryFailure(_ message: String) {
    guard lastDiscoveryFailure != message else { return }
    lastDiscoveryFailure = message
    emitConnection("failed", message: message)
  }

  private func emitConnection(_ state: String, message: String? = nil) {
    var event: [String: Any?] = [
      "type": "connection",
      "state": state,
      "localRole": "usbHost",
      "timestampMs": Int64(Date().timeIntervalSince1970 * 1_000),
    ]
    if let message { event["message"] = message }
    eventHandler(event)
  }

  private func friendly(_ error: Error) -> String {
    let description = (error as? LocalizedError)?.errorDescription
      ?? error.localizedDescription
    let nativeError = error as NSError
    return "\(description) [\(nativeError.domain) \(nativeError.code)]"
  }
}
