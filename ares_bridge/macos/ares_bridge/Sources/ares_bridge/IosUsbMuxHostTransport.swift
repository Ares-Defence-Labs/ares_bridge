import Foundation

final class IosUsbMuxHostTransport {
  typealias EventHandler = ([String: Any?]) -> Void

  private static let pollInterval: TimeInterval = 1

  private let eventHandler: EventHandler
  private let queue = DispatchQueue(label: "usb.bridge.macos.ios-discovery")
  private let client = UsbMuxClient()
  private var configuration: UsbHostConfiguration?
  private var timer: DispatchSourceTimer?
  private var session: UsbHostSession?
  private var listening = false
  private var lastSeenSerial: String?
  private var lastDiagnosticAt: Date?

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
    queue.sync { configuration = parsed }
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
      timer.setEventHandler { [weak self] in self?.pollUsbMux() }
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
      lastSeenSerial = nil
      lastDiagnosticAt = nil
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

  private func pollUsbMux() {
    guard listening, session == nil, let configuration else { return }
    do {
      guard let device = try client.usbDevices().first else {
        lastSeenSerial = nil
        return
      }
      if lastSeenSerial != device.serialNumber {
        lastSeenSerial = device.serialNumber
        emitConnection(
          "connecting",
          message: "iPhone connected by USB. Waiting for AresScan+ USB Mode."
        )
      }
      let descriptor = try client.connect(device)
      let session = try UsbHostSession(
        usbMuxSocket: descriptor,
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
      lastDiagnosticAt = nil
      emitConnection("connecting")
      session.start()
    } catch UsbMuxError.connectionRejected {
      // Connection refused simply means the paired phone has not opened its
      // foreground listener yet. Keep polling without turning the UI red.
    } catch {
      let now = Date()
      if lastDiagnosticAt == nil || now.timeIntervalSince(lastDiagnosticAt!) >= 10 {
        lastDiagnosticAt = now
        NSLog("[ares_bridge] iPhone USB discovery: %@", friendly(error))
      }
    }
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
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
