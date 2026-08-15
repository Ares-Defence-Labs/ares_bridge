import CryptoKit
import Foundation
import IOUSBHost

final class UsbHostSession {
  typealias EventHandler = ([String: Any?]) -> Void

  private struct Frame {
    let type: UInt8
    let header: [String: Any]
    let payload: Data
  }

  private struct OutgoingTransfer {
    let fileName: String
    let sourcePath: String
    let totalBytes: Int64
    let startedAtMs: Int64
  }

  private final class IncomingTransfer {
    let id: String
    let fileName: String
    let totalBytes: Int64
    let temporaryURL: URL
    let destinationURL: URL
    let destinationPath: String
    let startedAtMs = UsbHostSession.nowMs()
    private let handle: FileHandle
    private var hasher = SHA256()
    private(set) var transferredBytes: Int64 = 0

    init(
      id: String,
      fileName: String,
      totalBytes: Int64,
      temporaryURL: URL,
      destinationURL: URL,
      destinationPath: String
    ) throws {
      self.id = id
      self.fileName = fileName
      self.totalBytes = totalBytes
      self.temporaryURL = temporaryURL
      self.destinationURL = destinationURL
      self.destinationPath = destinationPath
      FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
      handle = try FileHandle(forWritingTo: temporaryURL)
    }

    func append(_ data: Data) throws {
      try handle.write(contentsOf: data)
      hasher.update(data: data)
      transferredBytes += Int64(data.count)
    }

    func finish() throws -> String {
      // SHA-256 is calculated as bytes arrive. Closing flushes the file before
      // the atomic rename; forcing a durable fsync here only stalls completion.
      try handle.close()
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func abort() {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporaryURL)
    }
  }

  private let byteTransport: UsbSessionByteTransport
  private let configuration: UsbHostConfiguration
  private let eventHandler: EventHandler
  private let disconnectedHandler: () -> Void
  private let shouldReportFailure: () -> Bool
  private let readQueue = DispatchQueue(label: "usb.bridge.macos.read")
  private let transferQueue = DispatchQueue(
    label: "usb.bridge.macos.transfers",
    attributes: .concurrent
  )
  private let writeLock = NSLock()
  private let stateLock = NSLock()
  private let chunkAckCondition = NSCondition()
  private var heartbeatTimer: DispatchSourceTimer?
  private var running = true
  private var active = false
  private var disconnectReported = false
  private let startedAtMs = nowMs()
  private let sessionId = UUID().uuidString
  private var lastPeerHeartbeatMs = nowMs()
  private var heartbeatWriteInFlight = false
  private var incoming: [String: IncomingTransfer] = [:]
  private var outgoing: [String: OutgoingTransfer] = [:]
  private var cancelled: Set<String> = []
  private var peerSupportsChunkAcknowledgements = false
  private var acknowledgedOffsets: [String: Int64] = [:]
  // Bulk USB transfers are packet/transaction based. A peer write can contain
  // more bytes than the protocol field currently being decoded, so the host
  // must submit a sufficiently large request and retain the surplus.
  private var inputBuffer = Data()
  private var inputBufferOffset = 0
  private static let maximumFrameBytes =
    18 + UsbWireProtocol.maxHeaderBytes + UsbWireProtocol.maxPayloadBytes
  private static let chunkAcknowledgementWindow = 4

  init(
    interface: IOUSBHostInterface,
    inputPipe: IOUSBHostPipe,
    outputPipe: IOUSBHostPipe,
    configuration: UsbHostConfiguration,
    eventHandler: @escaping EventHandler,
    disconnectedHandler: @escaping () -> Void,
    shouldReportFailure: @escaping () -> Bool = { true }
  ) {
    byteTransport = AndroidUsbPipeByteTransport(
      interface: interface,
      inputPipe: inputPipe,
      outputPipe: outputPipe
    )
    self.configuration = configuration
    self.eventHandler = eventHandler
    self.disconnectedHandler = disconnectedHandler
    self.shouldReportFailure = shouldReportFailure
  }

  init(
    usbMuxSocket descriptor: Int32,
    configuration: UsbHostConfiguration,
    eventHandler: @escaping EventHandler,
    disconnectedHandler: @escaping () -> Void,
    shouldReportFailure: @escaping () -> Bool = { true }
  ) throws {
    byteTransport = try UsbMuxSocketByteTransport(descriptor: descriptor)
    self.configuration = configuration
    self.eventHandler = eventHandler
    self.disconnectedHandler = disconnectedHandler
    self.shouldReportFailure = shouldReportFailure
  }

  var isActive: Bool {
    stateLock.withLock { running && active }
  }

  func start() {
    // Drain Android's IN endpoint before sending the handshake. Both peers can
    // send HELLO at the same time; starting reads after both writes creates a
    // bulk-pipe deadlock when each side is waiting for the other to drain.
    readQueue.async { [weak self] in self?.readLoop() }
    let timer = DispatchSource.makeTimerSource(queue: transferQueue)
    timer.schedule(
      deadline: .now() + .milliseconds(configuration.heartbeatIntervalMs),
      repeating: .milliseconds(configuration.heartbeatIntervalMs)
    )
    timer.setEventHandler { [weak self] in self?.heartbeat() }
    heartbeatTimer = timer
    timer.resume()

    do {
      try writeFrame(type: UsbWireProtocol.hello, header: [
        "peerId": configuration.localPeerId,
        "peerName": configuration.localPeerName,
        "sessionId": sessionId,
        "protocolCapabilities": ["chunkAcknowledgements"],
      ])
      try writeFrame(type: UsbWireProtocol.ready, header: [:])
    } catch {
      failAndDisconnect(error)
    }
  }

  func sendFile(_ request: [String: Any]) throws -> String {
    guard isActive else { throw UsbHostError.notConnected }
    guard let sourcePath = request["sourcePath"] as? String,
          !sourcePath.isEmpty else {
      throw UsbHostError.invalidTransfer("sourcePath is required.")
    }
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw UsbHostError.invalidTransfer("Source file does not exist: \(sourcePath)")
    }
    let fileName = sourceURL.lastPathComponent
    let totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let id = UUID().uuidString
    let transfer = OutgoingTransfer(
      fileName: fileName,
      sourcePath: sourceURL.path,
      totalBytes: totalBytes,
      startedAtMs: Self.nowMs()
    )
    stateLock.withLock { outgoing[id] = transfer }

    let destination = (request["destinationPath"] as? String) ?? fileName
    let rawMetadata = request["metadata"] as? [String: Any] ?? [:]
    let metadata = rawMetadata.compactMapValues { $0 as? String }
    transferQueue.async { [weak self] in
      self?.sendFileBytes(
        id: id,
        transfer: transfer,
        destinationPath: destination,
        metadata: metadata
      )
    }
    return id
  }

  func cancelTransfer(_ transferId: String) {
    stateLock.withLock {
      cancelled.insert(transferId)
      incoming.removeValue(forKey: transferId)?.abort()
      outgoing.removeValue(forKey: transferId)
    }
    clearChunkAcknowledgement(transferId)
  }

  func close() {
    let shouldClose = stateLock.withLock { () -> Bool in
      guard running else { return false }
      running = false
      active = false
      return true
    }
    guard shouldClose else { return }
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
    byteTransport.close()
    chunkAckCondition.lock()
    acknowledgedOffsets.removeAll()
    chunkAckCondition.broadcast()
    chunkAckCondition.unlock()
    stateLock.withLock {
      incoming.values.forEach { $0.abort() }
      incoming.removeAll()
      outgoing.removeAll()
    }
  }

  private func readLoop() {
    do {
      while isRunning {
        let frame = try readFrame()
        try handle(frame)
      }
    } catch {
      if isRunning { failAndDisconnect(error) }
    }
  }

  private func handle(_ frame: Frame) throws {
    // File data and acknowledgements are just as strong a liveness signal as a
    // heartbeat. This prevents active transfers from hitting peerTimeout.
    stateLock.withLock { lastPeerHeartbeatMs = Self.nowMs() }
    switch frame.type {
    case UsbWireProtocol.hello:
      // Android can send its startup HELLO and another HELLO in response to the
      // host handshake. A duplicate HELLO after READY must not downgrade the
      // product UI from active back to connecting.
      let capabilities = frame.header["protocolCapabilities"] as? [String] ?? []
      let connectionState = stateLock.withLock { () -> String in
        peerSupportsChunkAcknowledgements = capabilities.contains(
          "chunkAcknowledgements")
        return active ? "active" : "peerReady"
      }
      emitConnection(
        connectionState,
        peerId: frame.header["peerId"] as? String,
        peerName: frame.header["peerName"] as? String
      )
    case UsbWireProtocol.ready:
      let becameActive = stateLock.withLock { () -> Bool in
        let wasActive = active
        active = true
        lastPeerHeartbeatMs = Self.nowMs()
        return !wasActive
      }
      if becameActive { emitConnection("active") }
    case UsbWireProtocol.heartbeat:
      // The Android accessory descriptor can outlive a restarted host app. In
      // that case its one-time READY may have been consumed by the old host,
      // but a valid framed heartbeat proves the replacement session is live.
      let becameActive = stateLock.withLock { () -> Bool in
        let wasActive = active
        active = true
        lastPeerHeartbeatMs = Self.nowMs()
        return !wasActive
      }
      if becameActive { emitConnection("active") }
    case UsbWireProtocol.fileBegin:
      try handleFileBegin(frame.header)
    case UsbWireProtocol.fileChunk:
      try handleFileChunk(frame.header, payload: frame.payload)
    case UsbWireProtocol.fileEnd:
      try handleFileEnd(frame.header)
    case UsbWireProtocol.fileAcknowledgement:
      handleFileAcknowledgement(frame.header)
    case UsbWireProtocol.fileChunkAcknowledgement:
      handleFileChunkAcknowledgement(frame.header)
    case UsbWireProtocol.fileError:
      handleFileError(frame.header)
    default:
      throw UsbHostError.protocolViolation(
        "Unknown USB frame type \(frame.type).")
    }
  }

  private func handleFileBegin(_ header: [String: Any]) throws {
    let id = try requiredString(header, "transferId")
    let fileName = try requiredString(header, "fileName")
    let totalBytes = try requiredInt64(header, "totalBytes")
    guard totalBytes >= 0 else {
      throw UsbHostError.protocolViolation("Invalid file length.")
    }
    let relativePath = (header["destinationPath"] as? String) ?? fileName
    let root = URL(fileURLWithPath: configuration.incomingDirectory, isDirectory: true)
      .standardizedFileURL
    let requested = root.appendingPathComponent(relativePath).standardizedFileURL
    guard requested.path == root.path || requested.path.hasPrefix(root.path + "/") else {
      throw UsbHostError.protocolViolation(
        "Destination escapes the incoming directory.")
    }
    let destination = try collisionSafeDestination(requested)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(id).part"
    )
    let transfer = try IncomingTransfer(
      id: id,
      fileName: fileName,
      totalBytes: totalBytes,
      temporaryURL: temporary,
      destinationURL: destination,
      destinationPath: relativePath
    )
    stateLock.withLock { incoming[id] = transfer }
    emitProgress(
      id: id,
      direction: "incoming",
      fileName: fileName,
      transferred: 0,
      total: totalBytes,
      stage: "negotiating",
      startedAtMs: transfer.startedAtMs
    )
  }

  private func handleFileChunk(_ header: [String: Any], payload: Data) throws {
    let id = try requiredString(header, "transferId")
    if stateLock.withLock({ cancelled.contains(id) }) { return }
    guard let transfer = stateLock.withLock({ incoming[id] }) else {
      throw UsbHostError.protocolViolation("Chunk received for unknown transfer \(id).")
    }
    let offset = try requiredInt64(header, "offset")
    guard offset == transfer.transferredBytes else {
      throw UsbHostError.protocolViolation("Unexpected chunk offset for transfer \(id).")
    }
    try transfer.append(payload)
    guard transfer.transferredBytes <= transfer.totalBytes else {
      throw UsbHostError.protocolViolation("Transfer exceeded its declared file length.")
    }
    emitProgress(
      id: id,
      direction: "incoming",
      fileName: transfer.fileName,
      transferred: transfer.transferredBytes,
      total: transfer.totalBytes,
      stage: "transferring",
      startedAtMs: transfer.startedAtMs
    )
    let acknowledgementWindowBytes = Int64(
      configuration.chunkSizeBytes * Self.chunkAcknowledgementWindow)
    if stateLock.withLock({ peerSupportsChunkAcknowledgements }),
       transfer.transferredBytes == transfer.totalBytes ||
         transfer.transferredBytes % acknowledgementWindowBytes == 0 {
      try writeFrame(type: UsbWireProtocol.fileChunkAcknowledgement, header: [
        "transferId": id,
        "nextOffset": transfer.transferredBytes,
      ])
    }
  }

  private func handleFileEnd(_ header: [String: Any]) throws {
    let id = try requiredString(header, "transferId")
    if stateLock.withLock({ cancelled.remove(id) != nil }) { return }
    let expectedHash = try requiredString(header, "sha256")
    guard let transfer = stateLock.withLock({ incoming.removeValue(forKey: id) }) else {
      throw UsbHostError.protocolViolation("End received for unknown transfer \(id).")
    }
    emitProgress(
      id: id,
      direction: "incoming",
      fileName: transfer.fileName,
      transferred: transfer.transferredBytes,
      total: transfer.totalBytes,
      stage: "verifying",
      startedAtMs: transfer.startedAtMs
    )
    do {
      let actualHash = try transfer.finish()
      guard transfer.transferredBytes == transfer.totalBytes else {
        throw UsbHostError.protocolViolation(
          "Received file length does not match its manifest.")
      }
      guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
        throw UsbHostError.protocolViolation(
          "SHA-256 mismatch for \(transfer.fileName).")
      }
      let manager = FileManager.default
      if manager.fileExists(atPath: transfer.destinationURL.path),
         configuration.overwritePolicy == "replace" {
        try manager.removeItem(at: transfer.destinationURL)
      }
      try manager.moveItem(at: transfer.temporaryURL, to: transfer.destinationURL)
      emit([
        "type": "transferCompleted",
        "transferId": id,
        "direction": "incoming",
        "fileName": transfer.fileName,
        "bytesTransferred": transfer.transferredBytes,
        "localPath": transfer.destinationURL.path,
        "destinationPath": transfer.destinationPath,
        "sha256": actualHash,
        "timestampMs": Self.nowMs(),
      ])
      try writeFrame(type: UsbWireProtocol.fileAcknowledgement, header: [
        "transferId": id,
        "localPath": transfer.destinationURL.path,
        "sha256": actualHash,
      ])
    } catch {
      transfer.abort()
      emitFailure(
        id: id,
        direction: "incoming",
        fileName: transfer.fileName,
        code: "verification_failed",
        message: friendly(error),
        recoverable: true
      )
      try writeFrame(type: UsbWireProtocol.fileError, header: [
        "transferId": id,
        "code": "verification_failed",
        "message": friendly(error),
      ])
    }
  }

  private func handleFileAcknowledgement(_ header: [String: Any]) {
    guard let id = header["transferId"] as? String,
          let transfer = stateLock.withLock({ outgoing.removeValue(forKey: id) }) else {
      return
    }
    clearChunkAcknowledgement(id)
    var event: [String: Any?] = [
      "type": "transferCompleted",
      "transferId": id,
      "direction": "outgoing",
      "fileName": transfer.fileName,
      "bytesTransferred": transfer.totalBytes,
      "localPath": transfer.sourcePath,
      "timestampMs": Self.nowMs(),
    ]
    if let path = header["localPath"] as? String { event["remotePath"] = path }
    if let hash = header["sha256"] as? String { event["sha256"] = hash }
    emit(event)
  }

  private func handleFileChunkAcknowledgement(_ header: [String: Any]) {
    guard let id = header["transferId"] as? String,
          let nextOffset = (header["nextOffset"] as? NSNumber)?.int64Value else {
      return
    }
    chunkAckCondition.lock()
    acknowledgedOffsets[id] = max(acknowledgedOffsets[id] ?? 0, nextOffset)
    chunkAckCondition.broadcast()
    chunkAckCondition.unlock()
  }

  private func handleFileError(_ header: [String: Any]) {
    guard let id = header["transferId"] as? String else { return }
    clearChunkAcknowledgement(id)
    let outgoingTransfer = stateLock.withLock { () -> OutgoingTransfer? in
      let transfer = outgoing.removeValue(forKey: id)
      incoming.removeValue(forKey: id)?.abort()
      return transfer
    }
    emitFailure(
      id: id,
      direction: outgoingTransfer == nil ? "incoming" : "outgoing",
      fileName: outgoingTransfer?.fileName,
      code: header["code"] as? String ?? "peer_error",
      message: header["message"] as? String ?? "The peer rejected the transfer.",
      recoverable: true
    )
  }

  private func sendFileBytes(
    id: String,
    transfer: OutgoingTransfer,
    destinationPath: String,
    metadata: [String: String]
  ) {
    do {
      try writeFrame(type: UsbWireProtocol.fileBegin, header: [
        "transferId": id,
        "fileName": transfer.fileName,
        "destinationPath": destinationPath,
        "totalBytes": transfer.totalBytes,
        "metadata": metadata,
      ])
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: transfer.sourcePath))
      defer { try? handle.close() }
      var hasher = SHA256()
      var transferred: Int64 = 0
      while isRunning {
        if stateLock.withLock({ cancelled.remove(id) != nil }) {
          try writeFrame(type: UsbWireProtocol.fileError, header: [
            "transferId": id,
            "code": "cancelled",
            "message": "Transfer cancelled by sender.",
          ])
          return
        }
        let chunk = try handle.read(upToCount: configuration.chunkSizeBytes) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
        try writeFrame(type: UsbWireProtocol.fileChunk, header: [
          "transferId": id,
          "offset": transferred,
        ], payload: chunk)
        transferred += Int64(chunk.count)
        let acknowledgementWindowBytes = Int64(
          configuration.chunkSizeBytes * Self.chunkAcknowledgementWindow)
        if stateLock.withLock({ peerSupportsChunkAcknowledgements }),
           transferred == transfer.totalBytes ||
             transferred % acknowledgementWindowBytes == 0 {
          try waitForChunkAcknowledgement(id: id, nextOffset: transferred)
        }
        emitProgress(
          id: id,
          direction: "outgoing",
          fileName: transfer.fileName,
          transferred: transferred,
          total: transfer.totalBytes,
          stage: "transferring",
          startedAtMs: transfer.startedAtMs
        )
      }
      let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      try writeFrame(type: UsbWireProtocol.fileEnd, header: [
        "transferId": id,
        "sha256": hash,
      ])
      emitProgress(
        id: id,
        direction: "outgoing",
        fileName: transfer.fileName,
        transferred: transferred,
        total: transfer.totalBytes,
        stage: "verifying",
        startedAtMs: transfer.startedAtMs
      )
    } catch {
      clearChunkAcknowledgement(id)
      _ = stateLock.withLock { outgoing.removeValue(forKey: id) }
      emitFailure(
        id: id,
        direction: "outgoing",
        fileName: transfer.fileName,
        code: "send_failed",
        message: friendly(error),
        recoverable: true
      )
    }
  }

  private func waitForChunkAcknowledgement(id: String, nextOffset: Int64) throws {
    let deadline = Date().addingTimeInterval(
      TimeInterval(configuration.peerTimeoutMs) / 1_000)
    chunkAckCondition.lock()
    defer { chunkAckCondition.unlock() }
    while (acknowledgedOffsets[id] ?? 0) < nextOffset, isRunning {
      guard chunkAckCondition.wait(until: deadline) else {
        throw UsbHostError.transport(
          "The iPhone did not acknowledge the file chunk in time.")
      }
    }
    guard isRunning else { throw UsbHostError.transport("USB session closed.") }
  }

  private func clearChunkAcknowledgement(_ id: String) {
    chunkAckCondition.lock()
    acknowledgedOffsets.removeValue(forKey: id)
    chunkAckCondition.broadcast()
    chunkAckCondition.unlock()
  }

  private func heartbeat() {
    guard isRunning else { return }
    let now = Self.nowMs()
    let heartbeatState = stateLock.withLock { () -> (UsbHostError?, Bool) in
      if active {
        if now - lastPeerHeartbeatMs > Int64(configuration.peerTimeoutMs) {
          return (.transport("The USB peer stopped responding."), false)
        }
        guard !heartbeatWriteInFlight else { return (nil, false) }
        heartbeatWriteInFlight = true
        return (nil, true)
      }
      let error = now - startedAtMs > Int64(configuration.peerTimeoutMs)
        ? UsbHostError.transport("The mobile USB handshake timed out.")
        : nil
      return (error, false)
    }
    if let timeout = heartbeatState.0 {
      failAndDisconnect(timeout)
      return
    }
    guard heartbeatState.1 else { return }
    defer { stateLock.withLock { heartbeatWriteInFlight = false } }
    do {
      // Heartbeats are best-effort and must never queue ahead of file data or
      // its final acknowledgement.
      try writeFrame(
        type: UsbWireProtocol.heartbeat,
        header: [:],
        waitForWriteLock: false
      )
    } catch {
      failAndDisconnect(error)
    }
  }

  private func writeFrame(
    type: UInt8,
    header: [String: Any],
    payload: Data = Data(),
    waitForWriteLock: Bool = true
  ) throws {
    let headerData = try JSONSerialization.data(withJSONObject: header)
    guard headerData.count <= UsbWireProtocol.maxHeaderBytes,
          payload.count <= UsbWireProtocol.maxPayloadBytes else {
      throw UsbHostError.protocolViolation("USB frame is too large.")
    }
    var frame = Data()
    frame.appendBigEndian(UsbWireProtocol.magic)
    frame.append(UsbWireProtocol.version)
    frame.append(type)
    frame.appendBigEndian(UInt32(headerData.count))
    frame.appendBigEndian(UInt64(payload.count))
    frame.append(headerData)
    frame.append(payload)

    if isDiagnosticFrame(type) {
      NSLog("[ares_bridge] USB TX frame type=%d bytes=%d", type, frame.count)
    }

    if waitForWriteLock {
      writeLock.lock()
    } else if !writeLock.try() {
      return
    }
    defer { writeLock.unlock() }
    try send(frame)
  }

  private func send(_ data: Data) throws {
    try byteTransport.send(data)
  }

  private func readFrame() throws -> Frame {
    let prefix = try readExactly(18)
    let magic = prefix.uint32(at: 0)
    guard magic == UsbWireProtocol.magic else {
      throw UsbHostError.protocolViolation("Invalid USB frame magic.")
    }
    guard prefix[4] == UsbWireProtocol.version else {
      throw UsbHostError.protocolViolation(
        "Unsupported USB protocol version \(prefix[4]).")
    }
    let headerLength = Int(prefix.uint32(at: 6))
    let payloadLength64 = prefix.uint64(at: 10)
    guard headerLength >= 0,
          headerLength <= UsbWireProtocol.maxHeaderBytes,
          payloadLength64 <= UInt64(UsbWireProtocol.maxPayloadBytes) else {
      throw UsbHostError.protocolViolation("Invalid USB frame length.")
    }
    let headerData = try readExactly(headerLength)
    let object = try JSONSerialization.jsonObject(with: headerData)
    guard let header = object as? [String: Any] else {
      throw UsbHostError.protocolViolation("USB frame header is not an object.")
    }
    let payload = try readExactly(Int(payloadLength64))
    let type = prefix[5]
    if isDiagnosticFrame(type) {
      NSLog(
        "[ares_bridge] USB RX frame type=%d bytes=%d",
        type,
        18 + headerLength + payload.count
      )
    }
    return Frame(type: type, header: header, payload: payload)
  }

  private func readExactly(_ count: Int) throws -> Data {
    if count == 0 { return Data() }
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count, isRunning {
      let available = inputBuffer.count - inputBufferOffset
      if available > 0 {
        let consumed = min(count - result.count, available)
        let start = inputBufferOffset
        result.append(inputBuffer.subdata(in: start..<(start + consumed)))
        inputBufferOffset += consumed
        if inputBufferOffset == inputBuffer.count {
          inputBuffer = Data()
          inputBufferOffset = 0
        }
        continue
      }

      // The transport may return more than the current protocol field. Retain
      // that surplus so the next read continues at the exact frame boundary.
      guard let received = try byteTransport.receive(
        maxLength: Self.maximumFrameBytes,
        timeout: 1
      ) else { continue }
      inputBuffer = received
      inputBufferOffset = 0
    }
    guard result.count == count else { throw UsbHostError.transport("USB session closed.") }
    return result
  }

  private func collisionSafeDestination(_ requested: URL) throws -> URL {
    let manager = FileManager.default
    guard manager.fileExists(atPath: requested.path) else { return requested }
    switch configuration.overwritePolicy {
    case "replace": return requested
    case "reject":
      throw UsbHostError.invalidTransfer(
        "Destination already exists: \(requested.lastPathComponent)")
    default:
      let folder = requested.deletingLastPathComponent()
      let ext = requested.pathExtension
      let base = requested.deletingPathExtension().lastPathComponent
      var index = 1
      while true {
        let suffix = "\(base) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
        let candidate = folder.appendingPathComponent(suffix)
        if !manager.fileExists(atPath: candidate.path) { return candidate }
        index += 1
      }
    }
  }

  private func requiredString(_ header: [String: Any], _ key: String) throws -> String {
    guard let value = header[key] as? String, !value.isEmpty else {
      throw UsbHostError.protocolViolation("Missing frame field \(key).")
    }
    return value
  }

  private func requiredInt64(_ header: [String: Any], _ key: String) throws -> Int64 {
    guard let value = header[key] as? NSNumber else {
      throw UsbHostError.protocolViolation("Missing numeric frame field \(key).")
    }
    return value.int64Value
  }

  private func emitProgress(
    id: String,
    direction: String,
    fileName: String,
    transferred: Int64,
    total: Int64,
    stage: String,
    startedAtMs: Int64
  ) {
    let elapsed = max(1, Self.nowMs() - startedAtMs)
    let bytesPerSecond = transferred > 0
      ? Double(transferred) * 1_000 / Double(elapsed)
      : 0
    let remainingMs = bytesPerSecond > 0
      ? Int64(Double(max(0, total - transferred)) / bytesPerSecond * 1_000)
      : 0
    emit([
      "type": "transferProgress",
      "transferId": id,
      "direction": direction,
      "stage": stage,
      "fileName": fileName,
      "bytesTransferred": transferred,
      "totalBytes": total,
      "bytesPerSecond": bytesPerSecond,
      "estimatedTimeRemainingMs": remainingMs,
      "timestampMs": Self.nowMs(),
    ])
  }

  private func emitFailure(
    id: String,
    direction: String,
    fileName: String?,
    code: String,
    message: String,
    recoverable: Bool
  ) {
    var event: [String: Any?] = [
      "type": "transferFailed",
      "transferId": id,
      "direction": direction,
      "code": code,
      "message": message,
      "recoverable": recoverable,
      "timestampMs": Self.nowMs(),
    ]
    if let fileName { event["fileName"] = fileName }
    emit(event)
  }

  private func emitConnection(
    _ state: String,
    peerId: String? = nil,
    peerName: String? = nil,
    message: String? = nil
  ) {
    var event: [String: Any?] = [
      "type": "connection",
      "state": state,
      "localRole": "usbHost",
      "timestampMs": Self.nowMs(),
    ]
    if let peerId { event["peerId"] = peerId }
    if let peerName { event["peerName"] = peerName }
    if let message { event["message"] = message }
    emit(event)
  }

  private func failAndDisconnect(_ error: Error) {
    let shouldHandle = stateLock.withLock { () -> Bool in
      // Closing an inactive transport is intentional when the composite host
      // elects Android or iOS. A pending IOUSBHost request may still unwind
      // with an error afterwards; do not report that expected cancellation as
      // a live USB failure.
      guard running, !disconnectReported else { return false }
      disconnectReported = true
      return true
    }
    guard shouldHandle else { return }
    if shouldReportFailure() {
      let message = friendly(error)
      NSLog("[ares_bridge] USB session failed: %@", message)
      emitConnection("failed", message: message)
    }
    close()
    disconnectedHandler()
  }

  private func emit(_ event: [String: Any?]) {
    eventHandler(event)
  }

  private var isRunning: Bool { stateLock.withLock { running } }

  private func friendly(_ error: Error) -> String {
    let description = (error as? LocalizedError)?.errorDescription
      ?? error.localizedDescription
    let nativeError = error as NSError
    return "\(description) [\(nativeError.domain) \(nativeError.code)]"
  }

  private func isDiagnosticFrame(_ type: UInt8) -> Bool {
    switch type {
    case UsbWireProtocol.hello,
         UsbWireProtocol.ready,
         UsbWireProtocol.fileBegin,
         UsbWireProtocol.fileEnd,
         UsbWireProtocol.fileAcknowledgement,
         UsbWireProtocol.fileError:
      return true
    default:
      return false
    }
  }

  fileprivate static func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }
}

extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

private extension Data {
  mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    var encoded = value.bigEndian
    Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
  }

  func uint32(at offset: Int) -> UInt32 {
    self[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  func uint64(at offset: Int) -> UInt64 {
    self[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }
}
