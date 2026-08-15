import CryptoKit
import Darwin
import Foundation
import UIKit

protocol IosSessionByteTransport: AnyObject {
  func send(_ data: Data) throws
  func receive(maxLength: Int, timeout: TimeInterval) throws -> Data?
  func close()
}

final class IosLoopbackSocketByteTransport: IosSessionByteTransport {
  private let stateLock = NSLock()
  private var descriptor: Int32

  init(descriptor: Int32) throws {
    guard descriptor >= 0 else {
      throw IosUsbError.transport("The iPhone USB tunnel socket is invalid.")
    }
    self.descriptor = descriptor
    var enabled: Int32 = 1
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &enabled,
      socklen_t(MemoryLayout<Int32>.size)
    )
  }

  func send(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let descriptor = try activeDescriptor()
      let sent = data.withUnsafeBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return Darwin.send(
          descriptor,
          base.advanced(by: offset),
          data.count - offset,
          0
        )
      }
      if sent > 0 { offset += sent; continue }
      if sent < 0 && errno == EINTR { continue }
      throw posixError("The iPhone could not send data through the USB tunnel")
    }
  }

  func receive(maxLength: Int, timeout: TimeInterval) throws -> Data? {
    let descriptor = try activeDescriptor()
    var pollDescriptor = pollfd(
      fd: descriptor,
      events: Int16(POLLIN),
      revents: 0
    )
    let timeoutMs = Int32(max(1, min(Double(Int32.max), timeout * 1_000)))
    let ready = Darwin.poll(&pollDescriptor, 1, timeoutMs)
    if ready == 0 { return nil }
    if ready < 0 {
      if errno == EINTR { return nil }
      throw posixError("The iPhone USB tunnel poll failed")
    }
    if pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
      throw IosUsbError.transport("The Mac closed the USB tunnel.")
    }

    var bytes = [UInt8](repeating: 0, count: maxLength)
    let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
    if count > 0 { return Data(bytes.prefix(count)) }
    if count < 0 && (errno == EINTR || errno == EAGAIN) { return nil }
    if count == 0 { throw IosUsbError.transport("The Mac closed the USB tunnel.") }
    throw posixError("The iPhone could not receive USB data")
  }

  func close() {
    let descriptor = stateLock.withLock { () -> Int32 in
      let current = self.descriptor
      self.descriptor = -1
      return current
    }
    guard descriptor >= 0 else { return }
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
  }

  private func activeDescriptor() throws -> Int32 {
    try stateLock.withLock {
      guard descriptor >= 0 else {
        throw IosUsbError.transport("The iPhone USB tunnel is closed.")
      }
      return descriptor
    }
  }

  private func posixError(_ operation: String) -> IosUsbError {
    .transport("\(operation): \(String(cString: strerror(errno))).")
  }
}

struct IosUsbConfiguration {
  let localPeerId: String
  let localPeerName: String
  let incomingDirectory: String
  let overwritePolicy: String
  let chunkSizeBytes: Int
  let heartbeatIntervalMs: Int
  let peerTimeoutMs: Int

  init(arguments: [String: Any]) throws {
    let requestedRole = arguments["role"] as? String ?? "automatic"
    guard requestedRole != "usbHost" else {
      throw IosUsbError.invalidConfiguration("iOS must use the USB accessory role.")
    }
    let heartbeat = (arguments["heartbeatIntervalMs"] as? NSNumber)?.intValue ?? 2_000
    let timeout = (arguments["peerTimeoutMs"] as? NSNumber)?.intValue ?? 8_000
    let chunkSize = (arguments["chunkSizeBytes"] as? NSNumber)?.intValue ?? 65_536
    guard heartbeat > 0, timeout > heartbeat, chunkSize > 0,
          chunkSize <= UsbWireProtocol.maxPayloadBytes else {
      throw IosUsbError.invalidConfiguration(
        "Invalid heartbeat, peer timeout, or chunk size.")
    }

    let defaultInbox = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first!.appendingPathComponent("AresBridge/incoming", isDirectory: true).path
    localPeerId = Self.nonEmpty(arguments["localPeerId"] as? String)
      ?? "ios-\(UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)"
    localPeerName = Self.nonEmpty(arguments["localPeerName"] as? String)
      ?? UIDevice.current.name
    incomingDirectory = Self.nonEmpty(arguments["incomingDirectory"] as? String)
      ?? defaultInbox
    overwritePolicy = arguments["overwritePolicy"] as? String ?? "rename"
    chunkSizeBytes = chunkSize
    heartbeatIntervalMs = heartbeat
    peerTimeoutMs = timeout
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
  }
}

enum IosUsbError: LocalizedError {
  case invalidConfiguration(String)
  case notConnected
  case invalidTransfer(String)
  case transport(String)
  case protocolViolation(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message),
         .invalidTransfer(let message),
         .transport(let message),
         .protocolViolation(let message):
      return message
    case .notConnected:
      return "No active Mac USB peer."
    }
  }
}

enum UsbWireProtocol {
  static let magic: UInt32 = 0x4152_4553
  static let version: UInt8 = 1
  static let maxHeaderBytes = 1_048_576
  static let maxPayloadBytes = 16 * 1_048_576

  static let hello: UInt8 = 1
  static let ready: UInt8 = 2
  static let heartbeat: UInt8 = 3
  static let fileBegin: UInt8 = 16
  static let fileChunk: UInt8 = 17
  static let fileEnd: UInt8 = 18
  static let fileAcknowledgement: UInt8 = 19
  static let fileError: UInt8 = 20
  static let fileChunkAcknowledgement: UInt8 = 21
}

extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

final class IosUsbLoopbackServer {
  typealias EventHandler = ([String: Any?]) -> Void

  private static let port: UInt16 = 38_473

  private let eventHandler: EventHandler
  private let queue = DispatchQueue(label: "usb.bridge.ios.listener")
  private var configuration: IosUsbConfiguration?
  private var listenerDescriptor: Int32 = -1
  private var listenerSource: DispatchSourceRead?
  private var session: IosUsbSession?
  private var listeningRequested = false
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(eventHandler: @escaping EventHandler) {
    self.eventHandler = eventHandler
    lifecycleObservers = [
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in self?.queue.async { self?.suspendForBackground() } },
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in self?.queue.async { self?.resumeFromForeground() } },
    ]
  }

  deinit {
    lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    setIdleTimerDisabled(false)
  }

  func initialize(arguments: [String: Any]) throws {
    let parsed = try IosUsbConfiguration(arguments: arguments)
    try FileManager.default.createDirectory(
      atPath: parsed.incomingDirectory,
      withIntermediateDirectories: true
    )
    queue.sync { configuration = parsed }
    NSLog(
      "[AresBridge][iOS] initialized peer=%@ incoming=%@",
      parsed.localPeerName,
      parsed.incomingDirectory
    )
  }

  func startListening() throws {
    try queue.sync {
      guard configuration != nil else {
        throw IosUsbError.invalidConfiguration("Call initialize before startListening.")
      }
      listeningRequested = true
      guard listenerDescriptor < 0 else { return }
      try openListener()
      setIdleTimerDisabled(true)
      NSLog("[AresBridge][iOS] listening on cable tunnel port %d", Self.port)
      emitConnection(
        "listening",
        message: "Connect this iPhone to a trusted Mac with a USB cable."
      )
    }
  }

  func stop() {
    queue.sync {
      listeningRequested = false
      closeListenerAndSession()
      setIdleTimerDisabled(false)
      emitConnection("stopped")
    }
  }

  func sendFile(_ request: [String: Any]) throws -> String {
    try queue.sync {
      guard let session, session.isActive else { throw IosUsbError.notConnected }
      return try session.sendFile(request)
    }
  }

  func sendFiles(_ requests: [[String: Any]]) throws -> [String] {
    try queue.sync {
      guard let session, session.isActive else { throw IosUsbError.notConnected }
      return try requests.map(session.sendFile)
    }
  }

  func cancelTransfer(_ transferId: String) {
    queue.sync { session?.cancelTransfer(transferId) }
  }

  private func openListener() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw posixError("create the USB listener") }
    do {
      var enabled: Int32 = 1
      _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_REUSEADDR,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
      )
      _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
      )
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = in_port_t(Self.port).bigEndian
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(
            descriptor,
            $0,
            socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
      guard bound == 0 else { throw posixError("bind the cable-only listener") }
      guard Darwin.listen(descriptor, 1) == 0 else {
        throw posixError("start the cable-only listener")
      }
      _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
      listenerDescriptor = descriptor
      let source = DispatchSource.makeReadSource(
        fileDescriptor: descriptor,
        queue: queue
      )
      source.setEventHandler { [weak self] in self?.acceptConnection() }
      listenerSource = source
      source.resume()
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func acceptConnection() {
    guard listenerDescriptor >= 0, session == nil, let configuration else { return }
    var peer = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let accepted = withUnsafeMutablePointer(to: &peer) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.accept(listenerDescriptor, $0, &length)
      }
    }
    guard accepted >= 0 else { return }
    NSLog("[AresBridge][iOS] accepted usbmuxd tunnel")
    // Binding to loopback already excludes Wi-Fi and cellular. Check the peer
    // as a second cable-only guard before accepting the usbmuxd tunnel.
    guard peer.sin_family == sa_family_t(AF_INET),
          peer.sin_addr.s_addr == inet_addr("127.0.0.1") else {
      Darwin.close(accepted)
      return
    }
    do {
      let session = try IosUsbSession(
        socket: accepted,
        configuration: configuration,
        eventHandler: eventHandler,
        disconnectedHandler: { [weak self] in
          self?.queue.async {
            guard let self else { return }
            self.session = nil
            self.emitConnection("disconnected")
          }
        }
      )
      self.session = session
      emitConnection("connecting")
      session.start()
    } catch {
      Darwin.close(accepted)
      emitConnection("failed", message: friendly(error))
    }
  }

  private func suspendForBackground() {
    guard listeningRequested else { return }
    closeListenerAndSession()
    setIdleTimerDisabled(false)
    emitConnection(
      "disconnected",
      message: "Keep USB Mode open in the foreground during cable transfer."
    )
  }

  private func resumeFromForeground() {
    guard listeningRequested, listenerDescriptor < 0 else { return }
    do {
      try openListener()
      setIdleTimerDisabled(true)
      emitConnection("listening")
    } catch {
      emitConnection("failed", message: friendly(error))
    }
  }

  private func closeListenerAndSession() {
    listenerSource?.cancel()
    listenerSource = nil
    if listenerDescriptor >= 0 {
      Darwin.close(listenerDescriptor)
      listenerDescriptor = -1
    }
    session?.close()
    session = nil
  }

  /// A cable transfer must not be interrupted by the phone's normal auto-lock
  /// timer. iOS suspends the app and closes the usbmuxd tunnel when the screen
  /// locks, so keep the display awake only while foreground USB Mode is
  /// actively listening and restore the system default on exit/background.
  private func setIdleTimerDisabled(_ disabled: Bool) {
    DispatchQueue.main.async {
      UIApplication.shared.isIdleTimerDisabled = disabled
    }
  }

  private func emitConnection(_ state: String, message: String? = nil) {
    var event: [String: Any?] = [
      "type": "connection",
      "state": state,
      "localRole": "usbAccessory",
      "timestampMs": Int64(Date().timeIntervalSince1970 * 1_000),
    ]
    if let message { event["message"] = message }
    eventHandler(event)
  }

  private func posixError(_ operation: String) -> IosUsbError {
    .transport("Unable to \(operation): \(String(cString: strerror(errno))).")
  }

  private func friendly(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
