package com.example.ares_bridge

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry.NewIntentListener
import java.io.File

class AresBridgePlugin :
    FlutterPlugin,
    ActivityAware,
    NewIntentListener,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var usbManager: UsbManager
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false
    private var activityBinding: ActivityPluginBinding? = null
    private var configuration: AresAndroidConfiguration? = null
    private var session: AresAccessorySession? = null
    private var listeningRequested = false
    private var sessionGeneration = 0L
    private val reconnectRunnable = Runnable { reconnectAccessoryIfNeeded() }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        methodChannel = MethodChannel(binding.binaryMessenger, METHODS_CHANNEL)
        eventChannel = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        registerUsbReceiver()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> result.success(
                mapOf(
                    "platform" to "android",
                    "isSupported" to true,
                    "supportsUsbHost" to false,
                    "supportsUsbAccessory" to true,
                    "supportsBidirectionalTransfer" to true,
                    "reason" to null,
                ),
            )
            "initialize" -> initialize(call, result)
            "startListening" -> startListening(result)
            "stopListening" -> {
                listeningRequested = false
                mainHandler.removeCallbacks(reconnectRunnable)
                closeSession(emitStopped = true)
                result.success(null)
            }
            "sendFile" -> sendFile(call.arguments, result)
            "sendFiles" -> sendFiles(call.arguments, result)
            "cancelTransfer" -> {
                val transferId = (call.arguments as? Map<*, *>)?.get("transferId") as? String
                if (transferId.isNullOrBlank()) {
                    result.error("invalid_argument", "transferId must not be empty.", null)
                } else {
                    session?.cancelTransfer(transferId)
                    result.success(null)
                }
            }
            "dispose" -> {
                listeningRequested = false
                mainHandler.removeCallbacks(reconnectRunnable)
                closeSession(emitStopped = true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        if (arguments == null) {
            result.error("invalid_argument", "initialize expects a configuration map.", null)
            return
        }
        val role = arguments["role"] as? String ?: "automatic"
        if (role == "usbHost") {
            result.error(
                "unsupported_role",
                "Android is the USB accessory in the Ares desktop-to-Android topology.",
                null,
            )
            return
        }
        val heartbeatMs = (arguments["heartbeatIntervalMs"] as? Number)?.toLong() ?: 2000L
        val peerTimeoutMs = (arguments["peerTimeoutMs"] as? Number)?.toLong() ?: 8000L
        val chunkSize = (arguments["chunkSizeBytes"] as? Number)?.toInt() ?: 64 * 1024
        if (heartbeatMs <= 0 || peerTimeoutMs <= heartbeatMs || chunkSize <= 0) {
            result.error("invalid_configuration", "Invalid heartbeat, timeout, or chunk size.", null)
            return
        }
        val defaultIncoming = File(context.filesDir, "ares_bridge/incoming").absolutePath
        configuration = AresAndroidConfiguration(
            localPeerId = arguments["localPeerId"] as? String
                ?: "android-${Build.MANUFACTURER}-${Build.MODEL}",
            localPeerName = arguments["localPeerName"] as? String ?: Build.MODEL,
            incomingDirectory = arguments["incomingDirectory"] as? String ?: defaultIncoming,
            overwritePolicy = arguments["overwritePolicy"] as? String ?: "rename",
            chunkSizeBytes = chunkSize,
            heartbeatIntervalMs = heartbeatMs,
            peerTimeoutMs = peerTimeoutMs,
        )
        result.success(null)
    }

    private fun startListening(result: MethodChannel.Result) {
        val config = configuration
        if (config == null) {
            result.error("not_initialized", "Call initialize before startListening.", null)
            return
        }
        listeningRequested = true
        Log.i(LOG_TAG, "USB accessory listening requested")
        val existingSession = session
        if (existingSession?.isRunning == true) {
            emitConnection(if (existingSession.isActive) "active" else "connecting")
            result.success(null)
            return
        }
        emitConnection("listening")
        val accessory = usbManager.accessoryList?.firstOrNull()
        if (accessory == null) {
            // AOA re-enumeration and the Activity attach intent can complete a
            // few hundred milliseconds before UsbManager.accessoryList is
            // populated. Keep polling instead of leaving the listener idle.
            scheduleReconnect(500L)
            result.success(null)
            return
        }
        connectOrRequestPermission(accessory)
        result.success(null)
    }

    private fun handleAccessoryIntent(intent: Intent?): Boolean {
        if (intent?.action != UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            return false
        }
        val accessory = intent.accessoryExtra()
            ?: usbManager.accessoryList?.firstOrNull()
            ?: return true
        Log.i(LOG_TAG, "Received USB accessory activity intent")
        if (listeningRequested && configuration != null) {
            connectOrRequestPermission(accessory)
        }
        return true
    }

    override fun onNewIntent(intent: Intent): Boolean = handleAccessoryIntent(intent)

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        handleAccessoryIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachFromActivity()
    }

    private fun detachFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    private fun sendFile(arguments: Any?, result: MethodChannel.Result) {
        val request = arguments as? Map<*, *>
        if (request == null) {
            result.error("invalid_argument", "sendFile expects a transfer map.", null)
            return
        }
        val activeSession = session
        if (activeSession == null || !activeSession.isActive) {
            result.error("not_connected", "No active Ares USB peer.", null)
            return
        }
        try {
            result.success(activeSession.sendFile(request))
        } catch (error: Exception) {
            result.error("transfer_rejected", error.message, null)
        }
    }

    private fun sendFiles(arguments: Any?, result: MethodChannel.Result) {
        val requests = arguments as? List<*>
        if (requests == null) {
            result.error("invalid_argument", "sendFiles expects a list.", null)
            return
        }
        val activeSession = session
        if (activeSession == null || !activeSession.isActive) {
            result.error("not_connected", "No active Ares USB peer.", null)
            return
        }
        try {
            val ids = requests.map { request ->
                activeSession.sendFile(
                    request as? Map<*, *>
                        ?: throw IllegalArgumentException("Every transfer must be a map."),
                )
            }
            result.success(ids)
        } catch (error: Exception) {
            result.error("transfer_rejected", error.message, null)
        }
    }

    private fun connectOrRequestPermission(accessory: UsbAccessory) {
        if (usbManager.hasPermission(accessory)) {
            openAccessory(accessory)
            return
        }
        val permissionIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        usbManager.requestPermission(accessory, permissionIntent)
    }

    private fun openAccessory(accessory: UsbAccessory) {
        val config = configuration ?: return
        if (!listeningRequested) return
        if (session?.isRunning == true) return
        closeSession(emitStopped = false)
        val generation = ++sessionGeneration
        try {
            Log.i(LOG_TAG, "Opening Android accessory descriptor (generation=$generation)")
            session = AresAccessorySession(
                usbManager = usbManager,
                accessory = accessory,
                configuration = config,
                eventListener = ::emit,
                disconnectedListener = {
                    mainHandler.post {
                        if (generation != sessionGeneration) return@post
                        session = null
                        sessionGeneration++
                        Log.w(LOG_TAG, "Accessory session disconnected; scheduling recovery")
                        emitConnection("disconnected")
                        scheduleReconnect()
                    }
                },
            ).also { it.start() }
        } catch (error: Exception) {
            Log.e(LOG_TAG, "Unable to open Android accessory descriptor", error)
            emitConnection("failed", error.message)
            scheduleReconnect()
        }
    }

    private fun scheduleReconnect(delayMs: Long = 500L) {
        if (!listeningRequested) return
        mainHandler.removeCallbacks(reconnectRunnable)
        mainHandler.postDelayed(reconnectRunnable, delayMs)
    }

    private fun reconnectAccessoryIfNeeded() {
        if (!listeningRequested || session?.isRunning == true) return
        val accessory = usbManager.accessoryList?.firstOrNull()
        if (accessory == null) {
            // AOA re-enumeration can briefly remove the accessory between host
            // sessions. Keep listening even if the attach broadcast is missed.
            scheduleReconnect(1_000L)
            return
        }
        connectOrRequestPermission(accessory)
    }

    private fun closeSession(emitStopped: Boolean) {
        sessionGeneration++
        session?.close()
        session = null
        if (emitStopped) {
            emitConnection("stopped")
        }
    }

    private fun registerUsbReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
            addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(usbReceiver, filter)
        }
        receiverRegistered = true
    }

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val accessory = intent.accessoryExtra()
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) &&
                        accessory != null
                    ) {
                        openAccessory(accessory)
                    } else {
                        emitConnection("failed", "USB accessory permission was denied.")
                    }
                }
                UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> {
                    if (listeningRequested && configuration != null && accessory != null) {
                        connectOrRequestPermission(accessory)
                    }
                }
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    closeSession(emitStopped = false)
                    emitConnection("disconnected")
                    scheduleReconnect(1_000L)
                }
            }
        }
    }

    private fun Intent.accessoryExtra(): UsbAccessory? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }
    }

    private fun emitConnection(state: String, message: String? = null) {
        emit(
            mutableMapOf<String, Any?>(
                "type" to "connection",
                "state" to state,
                "localRole" to "usbAccessory",
                "message" to message,
                "timestampMs" to System.currentTimeMillis(),
            ),
        )
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        listeningRequested = false
        mainHandler.removeCallbacks(reconnectRunnable)
        closeSession(emitStopped = false)
        if (receiverRegistered) {
            context.unregisterReceiver(usbReceiver)
            receiverRegistered = false
        }
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        detachFromActivity()
    }

    companion object {
        private const val METHODS_CHANNEL = "ares_bridge/methods"
        private const val EVENTS_CHANNEL = "ares_bridge/events"
        private const val ACTION_USB_PERMISSION =
            "com.example.ares_bridge.USB_PERMISSION"
        private const val LOG_TAG = "UsbBridge"
    }
}

internal data class AresAndroidConfiguration(
    val localPeerId: String,
    val localPeerName: String,
    val incomingDirectory: String,
    val overwritePolicy: String,
    val chunkSizeBytes: Int,
    val heartbeatIntervalMs: Long,
    val peerTimeoutMs: Long,
)
