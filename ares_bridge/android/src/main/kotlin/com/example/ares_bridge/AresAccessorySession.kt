package com.example.ares_bridge

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal class AresAccessorySession(
    usbManager: UsbManager,
    accessory: UsbAccessory,
    private val configuration: AresAndroidConfiguration,
    private val eventListener: (Map<String, Any?>) -> Unit,
    private val disconnectedListener: () -> Unit,
) {
    private val descriptor: ParcelFileDescriptor =
        usbManager.openAccessory(accessory) ?: throw IOException("Unable to open USB accessory.")
    // USB accessory descriptors require block reads but do not implement
    // FileInputStream.available(). BufferedInputStream normally calls
    // available() while refilling a partially consumed buffer, which raises
    // EINVAL once a payload grows beyond that buffer. The wrapper preserves
    // block reads while explicitly advertising no immediately available bytes;
    // DataInputStream.readFully() then continues with normal blocking reads.
    private val input = DataInputStream(
        BufferedInputStream(
            object : FilterInputStream(FileInputStream(descriptor.fileDescriptor)) {
                override fun available(): Int = 0
            },
        ),
    )
    private val output = DataOutputStream(
        BufferedOutputStream(FileOutputStream(descriptor.fileDescriptor)),
    )
    private val executor = Executors.newCachedThreadPool()
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val running = AtomicBoolean(true)
    private val heartbeatWriteInFlight = AtomicBoolean(false)
    private val handshakeWriteInFlight = AtomicBoolean(false)
    private val writeLock = Any()
    private val handshakeStateLock = Any()
    private val cancelledTransfers = ConcurrentHashMap.newKeySet<String>()
    private val incomingTransfers = ConcurrentHashMap<String, IncomingTransfer>()
    private val outgoingTransfers = ConcurrentHashMap<String, OutgoingTransfer>()
    private var heartbeatTask: ScheduledFuture<*>? = null
    private var lastHostSessionMarker: String? = null
    @Volatile private var lastPeerHeartbeat = System.currentTimeMillis()
    @Volatile var isActive: Boolean = false
        private set
    val isRunning: Boolean
        get() = running.get()

    fun start() {
        executor.execute(::readLoop)
        // USB stream writes may wait for the host's bulk IN request. Never run
        // the initial handshake on Flutter's platform thread, where it would
        // block route navigation and make the Android UI appear frozen.
        writeHandshakeAsync()
        heartbeatTask = scheduler.scheduleAtFixedRate(
            ::heartbeat,
            configuration.heartbeatIntervalMs,
            configuration.heartbeatIntervalMs,
            TimeUnit.MILLISECONDS,
        )
    }

    fun sendFile(request: Map<*, *>): String {
        val sourcePath = request["sourcePath"] as? String
            ?: throw IllegalArgumentException("sourcePath is required.")
        val source = File(sourcePath)
        require(source.isFile) { "Source file does not exist: $sourcePath" }
        val transferId = UUID.randomUUID().toString()
        val destinationPath = request["destinationPath"] as? String ?: source.name
        val metadata = request["metadata"] as? Map<*, *> ?: emptyMap<Any?, Any?>()
        outgoingTransfers[transferId] = OutgoingTransfer(
            fileName = source.name,
            sourcePath = source.absolutePath,
            totalBytes = source.length(),
            startedAtMs = System.currentTimeMillis(),
        )
        executor.execute {
            try {
                sendFileBytes(transferId, source, destinationPath, metadata)
            } catch (error: Exception) {
                outgoingTransfers.remove(transferId)
                Log.e(LOG_TAG, "USB outgoing transfer failed: ${source.name}", error)
                emitFailure(
                    transferId,
                    "outgoing",
                    source.name,
                    "send_failed",
                    error.message ?: "Unable to send file.",
                    recoverable = true,
                )
            }
        }
        return transferId
    }

    fun cancelTransfer(transferId: String) {
        cancelledTransfers.add(transferId)
        incomingTransfers.remove(transferId)?.abort()
        outgoingTransfers.remove(transferId)
    }

    private fun sendFileBytes(
        transferId: String,
        source: File,
        destinationPath: String,
        metadata: Map<*, *>,
    ) {
        val startedAtMs = outgoingTransfers[transferId]?.startedAtMs
            ?: System.currentTimeMillis()
        val metadataJson = JSONObject()
        metadata.forEach { (key, value) ->
            if (key is String && value is String) metadataJson.put(key, value)
        }
        writeFrame(
            TYPE_FILE_BEGIN,
            JSONObject()
                .put("transferId", transferId)
                .put("fileName", source.name)
                .put("destinationPath", destinationPath)
                .put("totalBytes", source.length())
                .put("metadata", metadataJson),
        )
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(configuration.chunkSizeBytes)
        var transferred = 0L
        FileInputStream(source).use { stream ->
            while (running.get()) {
                if (cancelledTransfers.remove(transferId)) {
                    writeFrame(
                        TYPE_FILE_ERROR,
                        JSONObject()
                            .put("transferId", transferId)
                            .put("code", "cancelled")
                            .put("message", "Transfer cancelled by sender."),
                    )
                    return
                }
                val count = stream.read(buffer)
                if (count < 0) break
                val payload = if (count == buffer.size) buffer else buffer.copyOf(count)
                digest.update(payload)
                writeFrame(
                    TYPE_FILE_CHUNK,
                    JSONObject()
                        .put("transferId", transferId)
                        .put("offset", transferred),
                    payload,
                )
                transferred += count
                emitProgress(
                    transferId,
                    "outgoing",
                    source.name,
                    transferred,
                    source.length(),
                    "transferring",
                    startedAtMs,
                )
            }
        }
        writeFrame(
            TYPE_FILE_END,
            JSONObject()
                .put("transferId", transferId)
                .put("sha256", digest.digest().toHex()),
        )
        emitProgress(
            transferId,
            "outgoing",
            source.name,
            transferred,
            source.length(),
            "verifying",
            startedAtMs,
        )
    }

    private fun readLoop() {
        try {
            while (running.get()) {
                val frame = readFrame()
                // Any valid protocol frame proves that the peer is alive. A
                // large transfer must not time out merely because heartbeats
                // are queued behind file data.
                lastPeerHeartbeat = System.currentTimeMillis()
                when (frame.type) {
                    TYPE_HELLO -> handleHello(frame.header)
                    TYPE_READY -> handleReady()
                    TYPE_HEARTBEAT -> lastPeerHeartbeat = System.currentTimeMillis()
                    TYPE_FILE_BEGIN -> handleFileBegin(frame.header)
                    TYPE_FILE_CHUNK -> handleFileChunk(frame.header, frame.payload)
                    TYPE_FILE_END -> handleFileEnd(frame.header)
                    TYPE_FILE_ACK -> handleFileAck(frame.header)
                    TYPE_FILE_ERROR -> handleFileError(frame.header)
                    else -> throw IOException("Unknown Ares frame type ${frame.type}.")
                }
            }
        } catch (error: EOFException) {
            Log.w(LOG_TAG, "USB peer closed the accessory stream", error)
            disconnect()
        } catch (error: Exception) {
            if (running.get()) {
                Log.e(LOG_TAG, "USB accessory read loop failed", error)
                emitConnection("failed", error.message)
                disconnect()
            }
        }
    }

    private fun handleHello(header: JSONObject) {
        eventListener(
            mapOf(
                "type" to "connection",
                "state" to "peerReady",
                "localRole" to "usbAccessory",
                "peerId" to header.optString("peerId").takeIf { it.isNotEmpty() },
                "peerName" to header.optString("peerName").takeIf { it.isNotEmpty() },
                "timestampMs" to System.currentTimeMillis(),
            ),
        )

        // Android can keep the accessory descriptor open while the host app is
        // restarted. Each host session includes a new sessionId, so reply once
        // per session rather than flooding the data pipe for duplicate HELLOs.
        // Never write the reply from the read loop. The host can still be
        // sending READY and needs this loop to continue draining that frame.
        val sessionMarker = header.optString("sessionId")
            .takeIf { it.isNotEmpty() }
            ?: header.optString("peerId").takeIf { it.isNotEmpty() }
            ?: "legacy-host"
        val shouldReply = synchronized(handshakeStateLock) {
            if (lastHostSessionMarker == sessionMarker) {
                false
            } else {
                lastHostSessionMarker = sessionMarker
                true
            }
        }
        if (shouldReply) writeHandshakeAsync()
    }

    private fun writeHandshakeAsync() {
        if (!handshakeWriteInFlight.compareAndSet(false, true)) return
        executor.execute {
            try {
                writeHandshake()
            } catch (error: Exception) {
                if (running.get()) {
                    emitConnection("failed", error.message)
                    disconnect()
                }
            } finally {
                handshakeWriteInFlight.set(false)
            }
        }
    }

    private fun writeHandshake() {
        writeFrame(
            TYPE_HELLO,
            JSONObject()
                .put("peerId", configuration.localPeerId)
                .put("peerName", configuration.localPeerName),
        )
        writeFrame(TYPE_READY, JSONObject())
    }

    private fun handleReady() {
        isActive = true
        lastPeerHeartbeat = System.currentTimeMillis()
        emitConnection("active")
    }

    private fun handleFileBegin(header: JSONObject) {
        val transferId = header.requiredString("transferId")
        val fileName = header.requiredString("fileName")
        val totalBytes = header.getLong("totalBytes")
        val destinationPath = header.optString("destinationPath", fileName)
        val incomingRoot = File(configuration.incomingDirectory)
        if (configuration.incomingDirectory.startsWith("content://")) {
            throw IOException("Storage Access Framework URIs are not yet supported natively.")
        }
        incomingRoot.mkdirs()
        val destination = safeDestination(incomingRoot, destinationPath)
        val finalDestination = resolveCollision(destination)
        val temporary = File(finalDestination.parentFile, ".${finalDestination.name}.$transferId.part")
        temporary.parentFile?.mkdirs()
        incomingTransfers[transferId] = IncomingTransfer(
            transferId = transferId,
            fileName = fileName,
            totalBytes = totalBytes,
            temporary = temporary,
            destination = finalDestination,
            destinationPath = destinationPath,
        )
        emitProgress(
            transferId,
            "incoming",
            fileName,
            0,
            totalBytes,
            "negotiating",
            incomingTransfers[transferId]?.startedAtMs,
        )
    }

    private fun handleFileChunk(header: JSONObject, payload: ByteArray) {
        val transferId = header.requiredString("transferId")
        val transfer = incomingTransfers[transferId]
            ?: throw IOException("Chunk received for unknown transfer $transferId.")
        val offset = header.getLong("offset")
        if (offset != transfer.bytesTransferred) {
            throw IOException("Unexpected chunk offset for transfer $transferId.")
        }
        transfer.write(payload)
        emitProgress(
            transferId,
            "incoming",
            transfer.fileName,
            transfer.bytesTransferred,
            transfer.totalBytes,
            "transferring",
            transfer.startedAtMs,
        )
    }

    private fun handleFileEnd(header: JSONObject) {
        val transferId = header.requiredString("transferId")
        val expectedHash = header.requiredString("sha256")
        val transfer = incomingTransfers.remove(transferId)
            ?: throw IOException("End received for unknown transfer $transferId.")
        emitProgress(
            transferId,
            "incoming",
            transfer.fileName,
            transfer.bytesTransferred,
            transfer.totalBytes,
            "verifying",
            transfer.startedAtMs,
        )
        try {
            val actualHash = transfer.finish()
            if (!actualHash.equals(expectedHash, ignoreCase = true)) {
                transfer.abort()
                throw IOException("SHA-256 mismatch for ${transfer.fileName}.")
            }
            if (transfer.bytesTransferred != transfer.totalBytes) {
                transfer.abort()
                throw IOException("Received file length does not match its manifest.")
            }
            if (!transfer.temporary.renameTo(transfer.destination)) {
                transfer.temporary.copyTo(transfer.destination, overwrite = true)
                transfer.temporary.delete()
            }
            eventListener(
                mapOf(
                    "type" to "transferCompleted",
                    "transferId" to transferId,
                    "direction" to "incoming",
                    "fileName" to transfer.fileName,
                    "bytesTransferred" to transfer.bytesTransferred,
                    "localPath" to transfer.destination.absolutePath,
                    "remotePath" to null,
                    "destinationPath" to transfer.destinationPath,
                    "sha256" to actualHash,
                    "timestampMs" to System.currentTimeMillis(),
                ),
            )
            writeFrame(
                TYPE_FILE_ACK,
                JSONObject()
                    .put("transferId", transferId)
                    .put("localPath", transfer.destination.absolutePath)
                    .put("sha256", actualHash),
            )
        } catch (error: Exception) {
            emitFailure(
                transferId,
                "incoming",
                transfer.fileName,
                "verification_failed",
                error.message ?: "File verification failed.",
                recoverable = true,
            )
            writeFrame(
                TYPE_FILE_ERROR,
                JSONObject()
                    .put("transferId", transferId)
                    .put("code", "verification_failed")
                    .put("message", error.message),
            )
        }
    }

    private fun handleFileAck(header: JSONObject) {
        val transferId = header.requiredString("transferId")
        val transfer = outgoingTransfers.remove(transferId) ?: return
        eventListener(
            mapOf(
                "type" to "transferCompleted",
                "transferId" to transferId,
                "direction" to "outgoing",
                "fileName" to transfer.fileName,
                "bytesTransferred" to transfer.totalBytes,
                "localPath" to transfer.sourcePath,
                "remotePath" to header.optString("localPath").takeIf { it.isNotEmpty() },
                "sha256" to header.optString("sha256").takeIf { it.isNotEmpty() },
                "timestampMs" to System.currentTimeMillis(),
            ),
        )
    }

    private fun handleFileError(header: JSONObject) {
        val transferId = header.requiredString("transferId")
        val outgoing = outgoingTransfers.remove(transferId)
        incomingTransfers.remove(transferId)?.abort()
        emitFailure(
            transferId,
            if (outgoing == null) "incoming" else "outgoing",
            outgoing?.fileName,
            header.optString("code", "peer_error"),
            header.optString("message", "The peer rejected the transfer."),
            recoverable = true,
        )
    }

    private fun heartbeat() {
        if (!running.get()) return
        val now = System.currentTimeMillis()
        if (isActive && now - lastPeerHeartbeat > configuration.peerTimeoutMs) {
            disconnect()
            return
        }
        if (!isActive || !heartbeatWriteInFlight.compareAndSet(false, true)) return

        // A USB accessory write can legitimately wait while the desktop host is
        // not issuing bulk-IN requests. Keep that wait away from the watchdog
        // scheduler so peer timeout detection and descriptor recovery continue.
        executor.execute {
            try {
                writeFrame(TYPE_HEARTBEAT, JSONObject())
            } catch (_: Exception) {
                disconnect()
            } finally {
                heartbeatWriteInFlight.set(false)
            }
        }
    }

    private fun writeFrame(type: Int, header: JSONObject, payload: ByteArray = byteArrayOf()) {
        val headerBytes = header.toString().toByteArray(Charsets.UTF_8)
        synchronized(writeLock) {
            check(running.get()) { "USB session is closed." }
            output.writeInt(MAGIC)
            output.writeByte(PROTOCOL_VERSION)
            output.writeByte(type)
            output.writeInt(headerBytes.size)
            output.writeLong(payload.size.toLong())
            output.write(headerBytes)
            output.write(payload)
            output.flush()
            if (isDiagnosticFrame(type)) {
                Log.i(LOG_TAG, "USB TX frame type=$type bytes=${18 + headerBytes.size + payload.size}")
            }
        }
    }

    private fun readFrame(): Frame {
        if (input.readInt() != MAGIC) throw IOException("Invalid Ares frame magic.")
        val version = input.readUnsignedByte()
        if (version != PROTOCOL_VERSION) throw IOException("Unsupported Ares protocol $version.")
        val type = input.readUnsignedByte()
        val headerLength = input.readInt()
        val payloadLength = input.readLong()
        if (headerLength !in 0..MAX_HEADER_BYTES || payloadLength !in 0..MAX_PAYLOAD_BYTES) {
            throw IOException("Invalid Ares frame length.")
        }
        val headerBytes = ByteArray(headerLength)
        input.readFully(headerBytes)
        val payload = ByteArray(payloadLength.toInt())
        input.readFully(payload)
        if (isDiagnosticFrame(type)) {
            Log.i(LOG_TAG, "USB RX frame type=$type bytes=${18 + headerLength + payload.size}")
        }
        return Frame(type, JSONObject(String(headerBytes, Charsets.UTF_8)), payload)
    }

    private fun safeDestination(root: File, relativePath: String): File {
        val destination = File(root, relativePath)
        val rootPath = root.canonicalFile.toPath()
        val destinationPath = destination.canonicalFile.toPath()
        if (!destinationPath.startsWith(rootPath)) {
            throw IOException("Destination escapes the configured incoming directory.")
        }
        return destination.canonicalFile
    }

    private fun isDiagnosticFrame(type: Int): Boolean = when (type) {
        TYPE_HELLO,
        TYPE_READY,
        TYPE_FILE_BEGIN,
        TYPE_FILE_END,
        TYPE_FILE_ACK,
        TYPE_FILE_ERROR,
        -> true
        else -> false
    }

    private fun resolveCollision(requested: File): File {
        if (!requested.exists()) return requested
        return when (configuration.overwritePolicy) {
            "replace" -> requested
            "reject" -> throw IOException("Destination already exists: ${requested.name}")
            else -> {
                val name = requested.nameWithoutExtension
                val extension = requested.extension.takeIf { it.isNotEmpty() }?.let { ".$it" } ?: ""
                var index = 1
                var candidate: File
                do {
                    candidate = File(requested.parentFile, "$name ($index)$extension")
                    index++
                } while (candidate.exists())
                candidate
            }
        }
    }

    private fun emitProgress(
        transferId: String,
        direction: String,
        fileName: String,
        transferred: Long,
        total: Long,
        stage: String,
        startedAtMs: Long? = null,
    ) {
        val elapsedMs = startedAtMs?.let { System.currentTimeMillis() - it } ?: 0L
        val bytesPerSecond = if (transferred > 0 && elapsedMs > 0) {
            transferred.toDouble() * 1000.0 / elapsedMs.toDouble()
        } else {
            null
        }
        val estimatedRemainingMs = bytesPerSecond?.takeIf { it > 0 }?.let {
            (((total - transferred).coerceAtLeast(0)).toDouble() / it * 1000.0).toLong()
        }
        eventListener(
            mapOf(
                "type" to "transferProgress",
                "transferId" to transferId,
                "direction" to direction,
                "stage" to stage,
                "fileName" to fileName,
                "bytesTransferred" to transferred,
                "totalBytes" to total,
                "bytesPerSecond" to bytesPerSecond,
                "estimatedTimeRemainingMs" to estimatedRemainingMs,
                "timestampMs" to System.currentTimeMillis(),
            ),
        )
    }

    private fun emitFailure(
        transferId: String,
        direction: String,
        fileName: String?,
        code: String,
        message: String,
        recoverable: Boolean,
    ) {
        eventListener(
            mapOf(
                "type" to "transferFailed",
                "transferId" to transferId,
                "direction" to direction,
                "fileName" to fileName,
                "code" to code,
                "message" to message,
                "recoverable" to recoverable,
                "timestampMs" to System.currentTimeMillis(),
            ),
        )
    }

    private fun emitConnection(state: String, message: String? = null) {
        eventListener(
            mapOf(
                "type" to "connection",
                "state" to state,
                "localRole" to "usbAccessory",
                "message" to message,
                "timestampMs" to System.currentTimeMillis(),
            ),
        )
    }

    private fun disconnect() {
        if (!running.compareAndSet(true, false)) return
        isActive = false
        closeResources()
        disconnectedListener()
    }

    fun close() {
        if (running.compareAndSet(true, false)) {
            isActive = false
            closeResources()
        }
    }

    private fun closeResources() {
        heartbeatTask?.cancel(true)
        incomingTransfers.values.forEach(IncomingTransfer::abort)
        incomingTransfers.clear()
        // Close the descriptor first. Closing BufferedOutputStream attempts a
        // final flush, which can otherwise wait indefinitely after the Mac host
        // exits and keep the session's write lock occupied during reconnect.
        try {
            descriptor.close()
        } catch (_: Exception) {
        }
        try {
            input.close()
        } catch (_: Exception) {
        }
        try {
            output.close()
        } catch (_: Exception) {
        }
        scheduler.shutdownNow()
        executor.shutdownNow()
    }

    private data class Frame(val type: Int, val header: JSONObject, val payload: ByteArray)
    private data class OutgoingTransfer(
        val fileName: String,
        val sourcePath: String,
        val totalBytes: Long,
        val startedAtMs: Long,
    )

    private class IncomingTransfer(
        val transferId: String,
        val fileName: String,
        val totalBytes: Long,
        val temporary: File,
        val destination: File,
        val destinationPath: String,
    ) {
        val startedAtMs: Long = System.currentTimeMillis()
        private val output = FileOutputStream(temporary)
        private val digest = MessageDigest.getInstance("SHA-256")
        var bytesTransferred: Long = 0
            private set

        fun write(bytes: ByteArray) {
            output.write(bytes)
            digest.update(bytes)
            bytesTransferred += bytes.size
        }

        fun finish(): String {
            // close() flushes the file before it is renamed. A durable fsync is
            // unnecessary here because SHA-256 was computed while streaming,
            // and it can turn a tiny USB transfer into a multi-second stall.
            output.close()
            return digest.digest().toHex()
        }

        fun abort() {
            try {
                output.close()
            } catch (_: Exception) {
            }
            temporary.delete()
        }
    }

    companion object {
        private const val LOG_TAG = "UsbBridge"
        private const val MAGIC = 0x41524553
        private const val PROTOCOL_VERSION = 1
        private const val MAX_HEADER_BYTES = 1024 * 1024
        private const val MAX_PAYLOAD_BYTES = 16L * 1024L * 1024L
        private const val TYPE_HELLO = 1
        private const val TYPE_READY = 2
        private const val TYPE_HEARTBEAT = 3
        private const val TYPE_FILE_BEGIN = 16
        private const val TYPE_FILE_CHUNK = 17
        private const val TYPE_FILE_END = 18
        private const val TYPE_FILE_ACK = 19
        private const val TYPE_FILE_ERROR = 20
    }
}

private fun JSONObject.requiredString(key: String): String {
    val value = optString(key)
    if (value.isEmpty()) throw IOException("Missing frame field $key.")
    return value
}

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
