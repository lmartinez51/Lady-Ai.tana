package com.lmartinez.aitana.aitana

import android.app.PendingIntent
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import java.security.MessageDigest
import java.util.Locale
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Location & Geofencing
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiNetworkSpecifier
import android.content.Context
import android.content.SharedPreferences

import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Constraints
import java.util.concurrent.TimeUnit

// Lifecycle-aware coroutines
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.catch

// LiteRT-LM
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.tool
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags

// LiteRT (Standard) & TFLite Support
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.support.common.FileUtil
import java.nio.ByteBuffer
import java.nio.ByteOrder

// Camera X
import androidx.camera.core.Preview
import androidx.camera.video.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// Overlay window
import android.animation.ValueAnimator
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.provider.ContactsContract
import android.view.GestureDetector
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout

import java.io.File
import com.google.common.util.concurrent.ListenableFuture
import com.lmartinez.aitana.aitana.ModelFileResolver

/**
 * MainActivity bridges the Flutter UI layer to the native LiteRT-LM inference
 * engine via a [MethodChannel] (commands) and an [EventChannel] (streaming tokens).
 * It also handles native background Geofencing registration via Google Play Services.
 *
 * ## Dynamic Parameter Flow
 * Sampler parameters (temperature, topK, topP) arrive from Dart inside every
 * `send*` method-call payload. [extractSamplerConfig] reads them and persists
 * the result in [currentSamplerConfig]. The conversation is created lazily,
 * so the new config takes effect on the very next call after a reset.
 *
 * ## Thinking Mode
 * The `<|think|>` Gemma 4 control token is injected by the Dart layer into the
 * `system_prompt` string. Kotlin simply passes that string through unchanged —
 * no special processing required here.
 *
 * ## Session Lifecycle
 * `resetConversation` closes and nulls the [Conversation] object. The next
 * `send*` call lazily re-creates it with whatever [SamplerConfig] it receives,
 * guaranteeing that updated params are honored without restarting the [Engine].
 */
class MainActivity : FlutterFragmentActivity() {

    // ─── Engine / Session state ───────────────────────────────────────────────

    private var engine       : Engine?       = null
    private var conversation : Conversation? = null
    private var streamSink   : EventChannel.EventSink? = null
    private var activeInferenceJob: kotlinx.coroutines.Job? = null

    private val engineMutex       = Mutex()
    private val conversationMutex = Mutex()
    private val inferenceMutex    = Mutex()
    private val isInferenceRunning = java.util.concurrent.atomic.AtomicBoolean(false)
    private var isWokenByNexus = false

    /**
     * Tracks the base name of the currently-loaded model (e.g. "gemma_4b").
     * Initialised to "gemma_4b" for backward compatibility with existing send
     * paths that assume a model is present without an explicit initModel call.
     * Cleared to null when the engine is disposed or when a hot-swap teardown
     * occurs before the new engine is confirmed ready.
     */
    @Volatile
    private var activeModelBaseName: String? = "gemma_4b"

    /** Hoisted MethodChannel for the AI-Core channel; assigned in configureFlutterEngine. */
    private var aiCoreMethodChannel: MethodChannel? = null

    // ─── CameraX / Overlay state ─────────────────────────────────────────────

    private var videoCapture: VideoCapture<Recorder>? = null
    private var cameraPreview: Preview? = null
    private var recording: Recording? = null
    private lateinit var cameraExecutor: ExecutorService
    @Volatile
    private var pendingCameraResult: MethodChannel.Result? = null

    /** Launcher for the SYSTEM_ALERT_WINDOW (overlay) permission Settings screen. */
    private lateinit var overlayPermissionLauncher: ActivityResultLauncher<Intent>

    // Floating overlay
    private var overlayView: View? = null
    private var previewView: PreviewView? = null
    // Breathing halo animator — cancelled and nulled in hideCameraOverlay()
    private var haloAnimator: ValueAnimator? = null

    // DEVICE_EVENTS stream sink — emits real hardware start/stop confirmations to Dart
    private var deviceEventSink: EventChannel.EventSink? = null

    // ─── Geofencing state ─────────────────────────────────────────────────────

    private lateinit var geofencingClient: GeofencingClient

    /** Held so the local BroadcastReceiver can invoke Dart callbacks on the geofence channel. */
    private var geofenceMethodChannel: MethodChannel? = null

    /**
     * Receives ACTION_GEOFENCE_TRIGGERED local broadcasts from [GeofenceBroadcastReceiver]
     * and relays the record ID to Dart via the geofence MethodChannel.
     */
    private val geofenceTriggeredReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context, intent: android.content.Intent) {
            when (intent.action) {
                GeofenceBroadcastReceiver.ACTION_GEOFENCE_TRIGGERED -> {
                    val triggeredId = intent.getStringExtra(GeofenceBroadcastReceiver.EXTRA_GEOFENCE_ID) ?: return
                    Log.d("MainActivity", "📡 Relaying geofence trigger to Dart: ID=$triggeredId")
                    runOnUiThread {
                        geofenceMethodChannel?.invokeMethod("onGeofenceTriggered", triggeredId)
                    }
                }
                GeofenceBroadcastReceiver.ACTION_GEOFENCE_CLEARED -> {
                    val clearedId = intent.getStringExtra(GeofenceBroadcastReceiver.EXTRA_GEOFENCE_ID) ?: return
                    Log.d("MainActivity", "📡 Relaying geofence clear to Dart: ID=$clearedId")
                    runOnUiThread {
                        geofenceMethodChannel?.invokeMethod("onGeofenceCleared", clearedId)
                    }
                }
            }
        }
    }

    // Puente entre el callback nativo de Android y el resultado del MethodChannel
    @Volatile
    private var pendingPermissionResult: MethodChannel.Result? = null

    // ─── Wi-Fi Sniper state ───────────────────────────────────────────────────
    private val wifiNetworkRequest = NetworkRequest.Builder()
        .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        .build()

    private val wifiCallbackHandler = Handler(Looper.getMainLooper())
    private val trackedWifiSsidsByNetwork = mutableMapOf<Network, String>()

    private val wifiSniperCallback = object : ConnectivityManager.NetworkCallback(
        ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO
    ) {
        override fun onCapabilitiesChanged(
            network: Network,
            capabilities: NetworkCapabilities
        ) {
            val wifiInfo = capabilities.transportInfo as? WifiInfo
            val normalizedSsid = GeofenceUtils.normalizeSsid(wifiInfo?.ssid)

            if (normalizedSsid == null) {
                Log.d("WifiSniper", "Wi-Fi capabilities changed with redacted or unknown SSID.")
                GeofenceUtils.reconcileWifiSniper(this@MainActivity, null)
                return
            }

            val previousSsid = trackedWifiSsidsByNetwork.put(network, normalizedSsid)
            if (previousSsid != null && previousSsid != normalizedSsid) {
                GeofenceUtils.reconcileWifiSniper(this@MainActivity, previousSsid, force = true)
            }

            GeofenceUtils.reconcileWifiSniper(this@MainActivity, normalizedSsid)

            val prefs = getSharedPreferences("wifi_sniper_map", Context.MODE_PRIVATE)
            val geofenceId = prefs.getString(normalizedSsid, null)
            if (geofenceId != null) {
                Log.i("WifiSniper", "SSID match! Firing synthetic trigger for: $geofenceId")
                GeofenceUtils.fireSyntheticTrigger(this@MainActivity, geofenceId)
            }
        }

        override fun onLost(network: Network) {
            super.onLost(network)
            val droppedSsid = trackedWifiSsidsByNetwork.remove(network)
            GeofenceUtils.reconcileWifiSniper(this@MainActivity, droppedSsid, force = true)
        }
    }

    /**
     * Creates the PendingIntent that Google Play Services will fire when a geofence
     * boundary is crossed. FLAG_MUTABLE is strictly required in Android 14+ for this.
     */
    private val geofencePendingIntent: PendingIntent by lazy {
        val intent = Intent(this, GeofenceBroadcastReceiver::class.java)
        PendingIntent.getBroadcast(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
    }

    /**
     * Persists the last-applied [SamplerConfig] so that code paths that do
     * not supply sampler keys (e.g. background activations) can fall back
     * gracefully without crashing.
     */
    @Volatile
    private var currentSamplerConfig = SamplerConfig(
        topK        = 40,
        topP        = 0.90,
        temperature = 0.45
    )

    /**
     * Set to `true` by [disposeModel] to signal any in-flight [collect] loop
     * that it should drop tokens and return immediately, allowing
     * [inferenceMutex] to be released so the disposal can proceed safely.
     */
    @Volatile
    private var isDisposing = false

    // 🧠 Pilar 2: El Cerebro Vectorial (Embeddings)
    private var embeddingInterpreter: Interpreter? = null
    private val embeddingMutex = Mutex()

    /**
     * Initialises or returns the cached LiteRT Interpreter for the embedding model.
     *
     * Model  : embeddinggemma-300m
     * Output : 768-dimensional float32 vector (Matryoshka-capable; we use full 768).
     * Input  : Single tensor [1, seqLen] of int32 token IDs.
     *          BOS = 2  |  EOS = 1  |  vocab size = 256 000.
     */
    private suspend fun getOrInitEmbeddingInterpreter(): Interpreter = embeddingMutex.withLock {
        embeddingInterpreter?.let { return it }

        Log.i("MainActivity", "🧠 Loading Embedding Model: assets/models/embeddinggemma-300m.tflite")
        val modelFile = withContext(Dispatchers.IO) {
            FileUtil.loadMappedFile(this@MainActivity, "models/embeddinggemma-300m.tflite")
        }

        val options = Interpreter.Options().apply {
            setNumThreads(4)
            // CPU inference — avoids GPU context switching with the primary LLM.
        }

        val interpreter = Interpreter(modelFile, options)
        embeddingInterpreter = interpreter
        return interpreter
    }

    companion object {
        private const val AICORE_CHANNEL         = "com.lmartinez.aitana/aicore"
        private const val STREAM_CHANNEL         = "com.lmartinez.aitana/aicore_stream"
        private const val GEOFENCE_CHANNEL       = "com.lmartinez.aitana/geofence"
        private const val DEVICE_EVENTS_CHANNEL  = "com.lmartinez.aitana/device_events"
        private const val REQ_FINE_LOCATION       = 1001
        private const val REQ_BACKGROUND_LOCATION = 1002
        private const val REQ_CAMERA_VIDEO        = 1003
        // Android 13+ (API 33) requires POST_NOTIFICATIONS as a runtime permission
        private const val REQ_NOTIFICATIONS       = 1005
    }

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        overlayPermissionLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { _ ->
            if (Settings.canDrawOverlays(this)) {
                Log.i("CameraX", "Overlay permission granted — resuming recording.")
                pendingCameraResult?.let { startCameraXRecording(it) }
            } else {
                Log.w("CameraX", "Overlay permission denied — recording aborted.")
                pendingCameraResult?.error(
                    "OVERLAY_PERMISSION_DENIED",
                    "System overlay permission is required to show the camera preview.",
                    null
                )
            }
            pendingCameraResult = null
        }

        super.onCreate(savedInstanceState)
        
        cameraExecutor = Executors.newSingleThreadExecutor()

        // Keep screen flags
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // RE-ENABLED: Check if we are coming from the Nexus notification
        // Using the safe call operator ?. to prevent NPE
        isWokenByNexus = intent?.getStringExtra("WAKE_SOURCE") == "nexus_dispatcher"
        
        if (isWokenByNexus) {
            // Attempt to cancel the notification safely
            try {
                cancelWakeNotification()
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to cancel wake notification: ${e.message}")
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        isWokenByNexus = intent.getStringExtra("WAKE_SOURCE") == "nexus_dispatcher"

        if (isWokenByNexus) {
            // BUG-1 FIX (receive side) — Re-apply window visibility flags.
            //
            // setShowWhenLocked() and setTurnScreenOn() are applied in onCreate(),
            // but when the Activity is already alive and brought to the foreground
            // via onNewIntent() (SINGLE_TOP / REORDER_TO_FRONT), those flags are
            // NOT automatically re-evaluated by the WindowManager.
            //
            // Re-applying them here ensures the window is correctly elevated over
            // the Keyguard on every Nexus-triggered resume, not just on cold-starts.
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            Log.i("MainActivity", "onNewIntent: Nexus wake received — window flags re-applied.")
            cancelWakeNotification()
        }
    }

    // Helper function to clear the ghost notification
    private fun cancelWakeNotification() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as? android.app.NotificationManager
        nm?.cancel(9001) // 9001 is the ID used by Nexus
    }

    override fun onStart() {
        super.onStart()
    }

    override fun onStop() {
        super.onStop()
    }

    override fun onDestroy() {
        super.onDestroy()
        cameraExecutor.shutdown()

        // ── Geofence receiver cleanup ─────────────────────────────────────────
        try { unregisterReceiver(geofenceTriggeredReceiver) } catch (_: Exception) {}
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.unregisterNetworkCallback(wifiSniperCallback)
        } catch (_: Exception) {}

        // ── Zombie prevention: stop any active recording and remove the overlay ──
        try {
            recording?.stop()
            recording = null
        } catch (_: Exception) {}
        hideCameraOverlay()

        // Best-effort cleanup: disposeModel may have already closed these.
        // Wrap individually so a failure on one does not prevent the other.
        try {
            conversation?.close()
        } catch (_: Exception) { /* already closed via disposeModel */ }
        conversation = null
        try {
            engine?.close()
        } catch (_: Exception) { /* already closed via disposeModel */ }
        engine = null
    }

    // ─── Channel Setup ────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupAiCoreChannel(flutterEngine)
        aiCoreMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AICORE_CHANNEL)
        setupStreamChannel(flutterEngine)
        setupGeofenceChannel(flutterEngine)
        setupDeviceEventsChannel(flutterEngine)
    }

    private fun setupDeviceEventsChannel(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    deviceEventSink = events
                    Log.i("DeviceEvents", "DEVICE_EVENTS stream connected.")
                }
                override fun onCancel(arguments: Any?) {
                    deviceEventSink = null
                }
            })
    }

    private fun setupStreamChannel(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    streamSink = events
                }
                override fun onCancel(arguments: Any?) {
                    streamSink = null
                    Log.i("LiteRT-LM", "EventChannel stream cancelled. Terminating active inference job.")
                    activeInferenceJob?.cancel()
                    activeInferenceJob = null
                }
            })
    }

    private fun setupGeofenceChannel(flutterEngine: FlutterEngine) {
        geofencingClient = LocationServices.getGeofencingClient(this)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GEOFENCE_CHANNEL)
        geofenceMethodChannel = channel // ← hoist reference for the triggered receiver

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestLocationPermissions" -> handleLocationPermissionRequest(result)

                "addGeofence" -> {
                    val id = call.argument<String>("id")
                        ?: return@setMethodCallHandler result.error("INVALID_ID", "ID is required", null)
                    val title = call.argument<String>("title") ?: "Recordatorio"
                    val lat = call.argument<Double>("lat")
                        ?: return@setMethodCallHandler result.error("INVALID_LAT", "Latitude is required", null)
                    val lng = call.argument<Double>("lng")
                        ?: return@setMethodCallHandler result.error("INVALID_LNG", "Longitude is required", null)
                    val radius = call.argument<Double>("radius")?.toFloat() ?: 200f
                    val targetSsids = call.argument<List<String>>("targetSsids") ?: emptyList()

                    val prefs = getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
                    prefs.edit().putString(id, title).apply()

                    addGeofenceToSystem(id, lat, lng, radius, targetSsids, result)
                }

                "removeGeofence" -> {
                    val id = call.argument<String>("id")
                        ?: return@setMethodCallHandler result.error("INVALID_ID", "ID is required", null)
                    
                    try {
                        geofencingClient.removeGeofences(listOf(id))
                        GeofenceUtils.clearTriggeredStateAndSniperMap(this@MainActivity, id)
                        result.success("success")
                    } catch (e: Exception) {
                        result.error("REMOVE_FAILED", e.message, null)
                    }
                }

                "getTriggeredGeofences" -> {
                    val prefs = getSharedPreferences("geofence_idempotency", Context.MODE_PRIVATE)
                    val triggeredIds = prefs.getStringSet("triggered_ids", emptySet())?.toList() ?: emptyList<String>()
                    result.success(triggeredIds)
                }

                "getRegisteredGeofences" -> {
                    val prefs = getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
                    val registeredIds = prefs.all.keys.toList()
                    result.success(registeredIds)
                }

                "fireSyntheticTrigger" -> {
                    val id = call.argument<String>("id")
                        ?: return@setMethodCallHandler result.error("INVALID_ID", "ID is required", null)
                    GeofenceUtils.fireSyntheticTrigger(this@MainActivity, id)
                    result.success("success")
                }

                else -> result.notImplemented()
            }
        }

        // Register local receiver so GeofenceBroadcastReceiver can relay triggered IDs here.
        val filter = android.content.IntentFilter().apply {
            addAction(GeofenceBroadcastReceiver.ACTION_GEOFENCE_TRIGGERED)
            addAction(GeofenceBroadcastReceiver.ACTION_GEOFENCE_CLEARED)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(geofenceTriggeredReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(geofenceTriggeredReceiver, filter)
        }

        // Register Wi-Fi Sniper Callback
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.registerNetworkCallback(wifiNetworkRequest, wifiSniperCallback, wifiCallbackHandler)
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to register NetworkCallback: ${e.message}")
        }

        // Schedule Wi-Fi Sniper Worker
        val sniperWorkRequest = PeriodicWorkRequestBuilder<WifiSniperWorker>(
            repeatInterval = 15, // Minimum is 15 minutes — WorkManager enforces this
            repeatIntervalTimeUnit = TimeUnit.MINUTES
        )
        .setConstraints(
            Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
        )
        .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "wifi_sniper",
            ExistingPeriodicWorkPolicy.KEEP,
            sniperWorkRequest
        )
    }

    /**
     * Multi-step permission chain for geofencing.
     *
     * The chain proceeds in order:
     *   Step 1 — ACCESS_FINE_LOCATION (REQ_FINE_LOCATION)
     *   Step 2 — ACCESS_BACKGROUND_LOCATION (REQ_BACKGROUND_LOCATION)
     *   Step 3 — POST_NOTIFICATIONS on API 33+ (REQ_NOTIFICATIONS)
     *
     * [onRequestPermissionsResult] drives the chain forward. Dart only receives
     * result.success("granted") when ALL three steps pass.
     */
    private fun handleLocationPermissionRequest(result: MethodChannel.Result) {
        val fineLoc = android.Manifest.permission.ACCESS_FINE_LOCATION
        val bgLoc   = android.Manifest.permission.ACCESS_BACKGROUND_LOCATION

        val fineGranted = checkSelfPermission(fineLoc) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        val bgGranted   = checkSelfPermission(bgLoc) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED

        when {
            // Fine + Background both granted → check notifications (Step 3)
            fineGranted && bgGranted -> {
                Log.i("Permissions", "✅ Location permissions granted → checking notifications...")
                pendingPermissionResult = result
                requestNotificationPermissionIfNeeded(result)
            }

            // Only background missing → skip to Step 2
            fineGranted && !bgGranted -> {
                Log.i("Permissions", "⚡ Fine granted, requesting background...")
                pendingPermissionResult = result
                requestPermissions(arrayOf(bgLoc), REQ_BACKGROUND_LOCATION)
            }

            // Both needed → start from Step 1
            else -> {
                Log.i("Permissions", "🔑 Requesting fine location first...")
                pendingPermissionResult = result
                requestPermissions(arrayOf(fineLoc), REQ_FINE_LOCATION)
            }
        }
    }

    /**
     * Step 3 of the permission chain.
     * On Android 13+ (API 33), POST_NOTIFICATIONS is a runtime permission.
     * On older APIs it is implicitly granted — resolve immediately.
     */
    private fun requestNotificationPermissionIfNeeded(result: MethodChannel.Result) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            val notifPerm = android.Manifest.permission.POST_NOTIFICATIONS
            val notifGranted = checkSelfPermission(notifPerm) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED

            if (!notifGranted) {
                Log.i("Permissions", "🔔 Requesting POST_NOTIFICATIONS (API 33+)...")
                // pendingPermissionResult is already set by the caller
                requestPermissions(arrayOf(notifPerm), REQ_NOTIFICATIONS)
            } else {
                Log.i("Permissions", "✅ POST_NOTIFICATIONS already granted.")
                pendingPermissionResult?.success("granted")
                pendingPermissionResult = null
            }
        } else {
            // Pre-API-33: notification permission is implicit — all done.
            Log.i("Permissions", "✅ All permissions granted (pre-API-33, notifications implicit).")
            pendingPermissionResult?.success("granted")
            pendingPermissionResult = null
        }
    }

    /**
     * Step 2: Called when the user responds to the ACCESS_FINE_LOCATION popup.
     * If granted, we launch the background location request (Step 2 → Step 3).
     * If denied, we return an error to Dart so the UI can handle it.
     */
    private fun onFineLocationGranted() {
        Log.i("Permissions", "✅ Fine location granted → requesting background...")
        requestPermissions(
            arrayOf(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION),
            REQ_BACKGROUND_LOCATION
        )
    }

    /**
     * Unified Android callback for the three-step permission chain:
     *   REQ_FINE_LOCATION → REQ_BACKGROUND_LOCATION → REQ_NOTIFICATIONS
     *
     * Dart only receives result.success("granted") after all three steps pass.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        val granted = android.content.pm.PackageManager.PERMISSION_GRANTED

        when (requestCode) {
            // Step 1 result
            REQ_FINE_LOCATION -> {
                if (grantResults.isNotEmpty() && grantResults[0] == granted) {
                    // Chain to Step 2 — do NOT resolve Dart yet
                    onFineLocationGranted()
                } else {
                    Log.w("Permissions", "🔴 Fine location denied by user.")
                    pendingPermissionResult?.error(
                        "PERMISSION_DENIED",
                        "The user denied the location permission.",
                        null
                    )
                    pendingPermissionResult = null
                }
            }

            // Step 2 result
            REQ_BACKGROUND_LOCATION -> {
                if (grantResults.isNotEmpty() && grantResults[0] == granted) {
                    Log.i("Permissions", "✅ Background location granted → checking notifications...")
                    // Chain to Step 3 — do NOT resolve Dart yet
                    requestNotificationPermissionIfNeeded(
                        pendingPermissionResult ?: return
                    )
                } else {
                    Log.w("Permissions", "🔴 Background location denied → user must go to Settings.")
                    pendingPermissionResult?.error(
                        "BACKGROUND_PERMISSION_DENIED",
                        "The user did not grant 'Allow all the time'. They must go to Settings.",
                        null
                    )
                    pendingPermissionResult = null
                }
            }

            // Step 3 result (Android 13+ only)
            REQ_NOTIFICATIONS -> {
                if (grantResults.isNotEmpty() && grantResults[0] == granted) {
                    Log.i("Permissions", "✅ POST_NOTIFICATIONS granted. All permissions complete.")
                    pendingPermissionResult?.success("granted")
                } else {
                    Log.w("Permissions", "🔴 POST_NOTIFICATIONS denied by user.")
                    pendingPermissionResult?.error(
                        "NOTIFICATION_PERMISSION_DENIED",
                        "The user denied notification permission. Geofence alerts will not appear.",
                        null
                    )
                }
                pendingPermissionResult = null
            }

            REQ_CAMERA_VIDEO -> {
                val camGranted = grantResults.isNotEmpty() && grantResults[0] == granted
                val audGranted = grantResults.size > 1 && grantResults[1] == granted
                if (camGranted && audGranted) {
                    pendingCameraResult?.let { startCameraXRecording(it) }
                } else {
                    pendingCameraResult?.error("PERMISSION_DENIED", "Camera or audio permissions denied", null)
                }
                pendingCameraResult = null
            }
        }
    }


    private fun addGeofenceToSystem(id: String, lat: Double, lng: Double, radius: Float, targetSsids: List<String>, result: MethodChannel.Result) {
        Log.d("GeofenceManager", "🛠️ Creando GeofenceRequest con INITIAL_TRIGGER_DWELL...")
        val geofence = Geofence.Builder()
            .setRequestId(id)
            .setCircularRegion(lat, lng, radius)
            .setExpirationDuration(Geofence.NEVER_EXPIRE) 
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT or Geofence.GEOFENCE_TRANSITION_DWELL)
            .setLoiteringDelay(120000) // 2 minutes este metodo revisa si ya entre a la zona cada 2 minutos y manda la notificacion
            .setNotificationResponsiveness(30000) // 30 seconds este metodo revisa si ya entre a la zona cada 30 segundos y manda la notificacion
            .build()

        val geofencingRequest = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_DWELL)
            .addGeofence(geofence)
            .build()

        // Security Check: Assuming Dart has already requested ACCESS_FINE_LOCATION and ACCESS_BACKGROUND_LOCATION.
        try {
            geofencingClient.addGeofences(geofencingRequest, geofencePendingIntent).run {
                addOnSuccessListener {
                    Log.d("GeofenceManager", "✅ Geofence added successfully: $id")
                    if (targetSsids.isNotEmpty()) {
                        persistSniperMap(this@MainActivity, id, targetSsids)
                    }
                    result.success("success")
                }
                addOnFailureListener { exception ->
                    Log.e("GeofenceManager", "🔴 Failed to add geofence: ${exception.message}")
                    result.error("GEOFENCE_ERROR", exception.message, null)
                }
            }
        } catch (_: SecurityException) {
            Log.e("GeofenceManager", "🔴 Security Exception: Background location permission missing.")
            result.error("PERMISSION_DENIED", "Missing location permissions", null)
        }
    }

    private fun persistSniperMap(context: Context, geofenceId: String, ssids: List<String>) {
        val prefs = context.getSharedPreferences("wifi_sniper_map", Context.MODE_PRIVATE)
        val editor = prefs.edit()
        ssids.forEach { ssid ->
            editor.putString(ssid.lowercase(), geofenceId) // key=SSID (lowercase), value=geofenceId
        }
        editor.apply()
    }

    private fun setupAiCoreChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AICORE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // ── Engine initialisation / Hot Swap ─────────────────────
                    "initModel" -> {
                        // [1] Parse mandatory modelName argument from Flutter.
                        val requestedBaseName = call.argument<String>("modelName")
                            ?: return@setMethodCallHandler result.error(
                                "MISSING_ARGUMENT",
                                "initModel requires a 'modelName' argument.",
                                null
                            )

                        lifecycleScope.launch(Dispatchers.IO) {
                            // [2] Short-circuit: requested model is already loaded.
                            if (requestedBaseName == activeModelBaseName && engine != null) {
                                withContext(Dispatchers.Main) { result.success("model_ready") }
                                return@launch
                            }

                            // [3] VALIDATION GATE — confirm the target model exists on
                            //     disk BEFORE touching the running engine or GPU memory.
                            //     If the file is absent we abort and keep the current
                            //     model alive so the user is never left without a model.
                            if (!modelExistsOnDisk(requestedBaseName)) {
                                Log.w(
                                    "LiteRT-LM",
                                    "Hot-swap aborted: '$requestedBaseName' not found on device. " +
                                            "Current model '${activeModelBaseName}' remains active."
                                )
                                withContext(Dispatchers.Main) {
                                    result.error(
                                        "MODEL_NOT_FOUND",
                                        "Model '$requestedBaseName' not found on device. " +
                                                "Current model remains active.",
                                        null
                                    )
                                }
                                return@launch
                            }

                            // [4] Teardown — only reached after validation passes.
                            //     Uses the identical mutex nesting order as disposeModel
                            //     to prevent deadlocks with in-flight inference.
                            isDisposing = true
                            try {
                                inferenceMutex.withLock {
                                    engineMutex.withLock {
                                        conversationMutex.withLock {
                                            try {
                                                conversation?.close(); conversation = null
                                                engine?.close();       engine = null
                                                activeModelBaseName = null
                                                Log.i(
                                                    "LiteRT-LM",
                                                    "Hot-swap teardown complete — GPU memory freed ✓"
                                                )
                                            } catch (e: Exception) {
                                                Log.e(
                                                    "LiteRT-LM",
                                                    "Teardown error during hot-swap: ${e.message}"
                                                )
                                            }
                                        }
                                    }
                                }
                            } finally {
                                isDisposing = false
                            }

                            // [5] Initialise the new engine.
                            //     If this throws (e.g. corrupt file), activeModelBaseName
                            //     stays null and Flutter receives LLM_INIT_ERROR.
                            try {
                                getOrInitEngine(requestedBaseName)
                                activeModelBaseName = requestedBaseName
                                Log.i(
                                    "LiteRT-LM",
                                    "Hot-swap complete → active model: '$requestedBaseName' ✓"
                                )
                                withContext(Dispatchers.Main) { result.success("model_ready") }
                            } catch (e: Exception) {
                                Log.e(
                                    "LiteRT-LM",
                                    "Engine init failed for '$requestedBaseName': ${e.message}"
                                )
                                withContext(Dispatchers.Main) {
                                    result.error("LLM_INIT_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    "checkWakeSource" -> {
                        result.success(isWokenByNexus)
                        // Clear the flag for future normal launches
                        isWokenByNexus = false
                    }

                    // ── Generate Vector Embedding (Pilar 2) ───────────────────
                    "generateEmbedding" -> {
                        val text = call.argument<String>("text")
                            ?: return@setMethodCallHandler result.error("MISSING_TEXT", "Text is required", null)

                        lifecycleScope.launch(Dispatchers.Default) {
                            try {
                                val interpreter = getOrInitEmbeddingInterpreter()

                                // ── Tokenisation: Gemma SentencePiece-compatible stub ────────────
                                //
                                // Production: replace with a bundled SentencePiece model.
                                // Until then, we use a deterministic hash-based mapping
                                // scaled to Gemma's 256 000-token vocabulary.
                                //
                                // Special tokens:
                                //   BOS (Beginning-of-Sequence) = 2
                                //   EOS (End-of-Sequence)       = 1
                                //   PAD                         = 0
                                val maxLength = 1024
                                val inputIds  = IntArray(maxLength) // PAD = 0 by default

                                val cleanText = text.lowercase(Locale.ROOT)
                                val words     = cleanText.split(Regex("\\s+")).filter { it.isNotEmpty() }

                                inputIds[0] = 2 // BOS
                                var currentIdx = 1

                                for (word in words) {
                                    if (currentIdx >= maxLength - 1) break
                                    // Deterministic hash -> [3, 255999] (avoids special IDs 0-2)
                                    val tokenId = ((word.hashCode() and 0x7FFF_FFFF) % 255_997) + 3
                                    inputIds[currentIdx++] = tokenId
                                }
                                // EOS marks end of content; remaining slots stay 0 (PAD)
                                if (currentIdx < maxLength) inputIds[currentIdx] = 1 // EOS

                                // ── Inference ────────────────────────────────────────────────────
                                //
                                // embeddinggemma-300m takes ONE input: [1, seqLen] int32
                                // and produces ONE output: [1, 768] float32.
                                val inputTensor  = arrayOf(inputIds)        // shape [1, 1024]
                                val outputTensor = Array(1) { FloatArray(768) }

                                interpreter.run(inputTensor, outputTensor)

                                val finalVector = outputTensor[0]

                                withContext(Dispatchers.Main) {
                                    result.success(finalVector.toList())
                                }
                            } catch (e: Exception) {
                                Log.e("MainActivity", "❌ Embedding Error: ${e.message}", e)
                                withContext(Dispatchers.Main) {
                                    result.error("EMBEDDING_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    // ── Video Recording ───────────────────────────────────────
                    "startVideoRecording" -> {
                        requestCameraPermissions(result)
                    }
                    
                    "stopVideoRecording" -> {
                        val curRecording = recording
                        if (curRecording != null) {
                            curRecording.stop()
                            recording = null
                            result.success("Recording stopped")
                        } else {
                            result.error("NOT_RECORDING", "No active recording.", null)
                        }
                    }

                    // ── Text-only inference ───────────────────────────────────
                    "sendMessage" -> handleSendMessage(call, result)

                    "sendOneShotMessage" -> handleSendOneShotMessage(call, result)

                    // ── Conversation reset (triggered by param changes or clear) ──
                    "resetConversation" -> {
                        lifecycleScope.launch(Dispatchers.IO) {
                            conversationMutex.withLock {
                                conversation?.close()
                                conversation = null
                                Log.i("LiteRT-LM", "Conversation reset ✓")
                            }
                            withContext(Dispatchers.Main) { result.success("conversation_reset") }
                        }
                    }

                    // ── Complete Engine Disposal (Secure Exit / Release GPU) ──
                    "disposeModel" -> {
                        lifecycleScope.launch(Dispatchers.IO) {
                            isDisposing = true
                            try {
                                inferenceMutex.withLock {
                                    engineMutex.withLock {
                                        conversationMutex.withLock {
                                            try {
                                                conversation?.close()
                                                conversation = null
                                                engine?.close()
                                                engine = null
                                                activeModelBaseName = null
                                                Log.i(
                                                    "LiteRT-LM",
                                                    "Engine and Conversation disposed (3.5GB GPU memory freed) ✓"
                                                )
                                                withContext(Dispatchers.Main) {
                                                    result.success("model_disposed")
                                                }
                                            } catch (e: Exception) {
                                                withContext(Dispatchers.Main) {
                                                    result.error("DISPOSE_ERROR", e.message, null)
                                                }
                                            }
                                        }
                                    }
                                }
                            } finally {
                                isDisposing = false
                            }
                        }
                    }

                    // ── Vision inference (image + text) ───────────────────────
                    "sendMessageWithImage" -> handleSendMessageWithImage(call, result)

                    // ── Audio inference (audio + text) ────────────────────────
                    "sendMessageWithAudio" -> handleSendMessageWithAudio(call, result)

                    // ── Personal Vault Phase 1 ──────────────────────────────
                    "initVaultSandbox" -> {
                        val sandbox = File(filesDir, "vault/analyzed_images")
                        if (!sandbox.exists()) {
                            sandbox.mkdirs()
                        }
                        result.success(sandbox.absolutePath)
                    }

                    "calculateSHA256" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) {
                            result.error("MISSING_ARG", "filePath is required", null)
                        } else {
                            lifecycleScope.launch(Dispatchers.IO) {
                                try {
                                    val hash = calculateSHA256(filePath)
                                    withContext(Dispatchers.Main) {
                                        result.success(hash)
                                    }
                                } catch (e: Exception) {
                                    withContext(Dispatchers.Main) {
                                        result.error("HASH_ERROR", e.message, null)
                                    }
                                }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ─── Send-method handlers (extracted from setupAiCoreChannel) ─────────────

    private fun handleSendOneShotMessage(call: MethodCall, result: MethodChannel.Result) {
        val prompt       = call.argument<String>("prompt")       ?: ""
        val systemPrompt = call.argument<String>("system_prompt") ?: ""

        if (prompt.isBlank()) {
            result.error("INVALID_PROMPT", "Prompt must not be empty.", null)
            return
        }

        val sampler = extractSamplerConfig(call)

        Log.d(
            "LiteRT-LM",
            "sendOneShotMessage → SamplerConfig(temp=${sampler.temperature}, " +
                    "topK=${sampler.topK}, topP=${sampler.topP})"
        )

        lifecycleScope.launch(Dispatchers.IO) {
            val currentBaseName = activeModelBaseName
            if (currentBaseName == null) {
                withContext(Dispatchers.Main) {
                    result.error("NO_MODEL_LOADED", "No active model is loaded.", null)
                }
                return@launch
            }

            inferenceMutex.withLock {
                isInferenceRunning.set(true)
                var tempConversation: Conversation? = null
                try {
                    val currentEngine = getOrInitEngine(currentBaseName)
                    val config = ConversationConfig(
                        systemInstruction = Contents.of(systemPrompt),
                        samplerConfig     = sampler,
                        tools             = emptyList()
                    )
                    tempConversation = currentEngine.createConversation(config)

                    val buffer = StringBuilder()
                    tempConversation.sendMessageAsync(prompt)
                        .catch { e ->
                            Log.e("LiteRT-LM", "One-shot stream error: ${e.message}", e)
                            throw e
                        }
                        .collect { message ->
                            if (isDisposing) return@collect
                            buffer.append(message.toString())
                        }

                    withContext(Dispatchers.Main) {
                        result.success(buffer.toString().trim())
                    }
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        result.error("LLM_ONE_SHOT_ERROR", e.message, null)
                    }
                } finally {
                    try {
                        tempConversation?.close()
                    } catch (_: Exception) {}
                    isInferenceRunning.set(false)
                }
            }
        }
    }

    private fun handleSendMessage(call: MethodCall, result: MethodChannel.Result) {
        val prompt       = call.argument<String>("prompt")       ?: ""
        val systemPrompt = call.argument<String>("system_prompt") ?: ""

        if (prompt.isBlank()) {
            result.error("INVALID_PROMPT", "Prompt must not be empty.", null)
            return
        }

        val sampler = extractSamplerConfig(call)
        currentSamplerConfig = sampler

        Log.d(
            "LiteRT-LM",
            "sendMessage → SamplerConfig(temp=${sampler.temperature}, " +
                    "topK=${sampler.topK}, topP=${sampler.topP})"
        )

        activeInferenceJob = lifecycleScope.launch(Dispatchers.IO) {
            val currentBaseName = activeModelBaseName
            if (currentBaseName == null) {
                withContext(Dispatchers.Main) {
                    result.error("NO_MODEL_LOADED", "No active model is loaded.", null)
                }
                return@launch
            }

            if (isInferenceRunning.get()) {
                withContext(Dispatchers.Main) {
                    result.error("BUSY", "Inference already running.", null)
                }
                return@launch
            }

            inferenceMutex.withLock {
                isInferenceRunning.set(true)
                try {
                    val conv = getOrInitConversation(systemPrompt, sampler, currentBaseName)

                    conv.sendMessageAsync(prompt)
                        .catch { e ->
                            withContext(Dispatchers.Main) {
                                streamSink?.error("STREAM_ERROR", e.message, null)
                            }
                        }
                        .collect { message ->
                            if (isDisposing) return@collect
                            withContext(Dispatchers.Main) {
                                streamSink?.success(message.toString())
                            }
                        }

                    withContext(Dispatchers.Main) {
                        streamSink?.success("[DONE]")
                        result.success("ok")
                    }
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        result.error("LLM_INFERENCE_ERROR", e.message, null)
                    }
                } finally {
                    isInferenceRunning.set(false)
                }
            }
        }
    }

    private fun handleSendMessageWithImage(call: MethodCall, result: MethodChannel.Result) {
        val prompt       = call.argument<String>("prompt")       ?: ""
        val systemPrompt = call.argument<String>("system_prompt") ?: ""
        val imagePath    = call.argument<String>("imagePath")    ?: ""

        if (prompt.isBlank() || imagePath.isBlank()) {
            result.error("INVALID_ARGS", "prompt and imagePath required.", null)
            return
        }

        val sampler = extractSamplerConfig(call)
        currentSamplerConfig = sampler

        Log.d(
            "LiteRT-LM",
            "sendMessageWithImage → SamplerConfig(temp=${sampler.temperature}, " +
                    "topK=${sampler.topK}, topP=${sampler.topP})"
        )

        activeInferenceJob = lifecycleScope.launch(Dispatchers.IO) {
            val currentBaseName = activeModelBaseName
            if (currentBaseName == null) {
                withContext(Dispatchers.Main) {
                    result.error("NO_MODEL_LOADED", "No active model is loaded.", null)
                }
                return@launch
            }

            val file = File(imagePath)
            if (!file.exists()) {
                withContext(Dispatchers.Main) {
                    result.error("FILE_NOT_FOUND", "Image file not found at: $imagePath", null)
                }
                return@launch
            }

            if (isInferenceRunning.get()) {
                withContext(Dispatchers.Main) {
                    result.error("BUSY", "Inference already running.", null)
                }
                return@launch
            }

            inferenceMutex.withLock {
                isInferenceRunning.set(true)
                try {
                    val conv = getOrInitConversation(systemPrompt, sampler, currentBaseName)

                    val contents = Contents.of(
                        Content.ImageFile(imagePath),
                        Content.Text(prompt)
                    )

                    conv.sendMessageAsync(Message.user(contents))
                        .catch { e ->
                            withContext(Dispatchers.Main) {
                                result.error("LLM_VISION_ERROR", e.message, null)
                            }
                        }
                        .collect { message ->
                            if (isDisposing) return@collect
                            withContext(Dispatchers.Main) {
                                streamSink?.success(message.toString())
                            }
                        }

                    withContext(Dispatchers.Main) {
                        streamSink?.success("[DONE]")
                        result.success("ok")
                    }
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        result.error("LLM_VISION_ERROR", e.message, null)
                    }
                } finally {
                    isInferenceRunning.set(false)
                }
            }
        }
    }

    private fun handleSendMessageWithAudio(call: MethodCall, result: MethodChannel.Result) {
        val prompt       = call.argument<String>("prompt")
            ?: "Listen to this audio and respond."
        val systemPrompt = call.argument<String>("system_prompt") ?: ""
        val audioPath    = call.argument<String>("audioPath")    ?: ""

        if (audioPath.isBlank()) {
            result.error("INVALID_ARGS", "audioPath required.", null)
            return
        }

        val sampler = extractSamplerConfig(call)
        currentSamplerConfig = sampler

        Log.d(
            "LiteRT-LM",
            "sendMessageWithAudio → SamplerConfig(temp=${sampler.temperature}, " +
                    "topK=${sampler.topK}, topP=${sampler.topP})"
        )

        activeInferenceJob = lifecycleScope.launch(Dispatchers.IO) {
            val currentBaseName = activeModelBaseName
            if (currentBaseName == null) {
                withContext(Dispatchers.Main) {
                    result.error("NO_MODEL_LOADED", "No active model is loaded.", null)
                }
                return@launch
            }

            val file = File(audioPath)
            if (!file.exists()) {
                withContext(Dispatchers.Main) {
                    result.error("FILE_NOT_FOUND", "Audio file not found at: $audioPath", null)
                }
                return@launch
            }

            if (isInferenceRunning.get()) {
                withContext(Dispatchers.Main) {
                    result.error("BUSY", "Inference already running.", null)
                }
                return@launch
            }

            inferenceMutex.withLock {
                isInferenceRunning.set(true)
                try {
                    val conv = getOrInitConversation(systemPrompt, sampler, currentBaseName)

                    val contents = Contents.of(
                        Content.AudioFile(audioPath),
                        Content.Text(prompt)
                    )

                    conv.sendMessageAsync(Message.user(contents))
                        .catch { e ->
                            withContext(Dispatchers.Main) {
                                streamSink?.error("STREAM_ERROR", e.message, null)
                            }
                        }
                        .collect { messageDelta ->
                            if (isDisposing) return@collect
                            val token = messageDelta.toString()
                            withContext(Dispatchers.Main) {
                                streamSink?.success(token)
                            }
                        }

                    withContext(Dispatchers.Main) {
                        streamSink?.success("[DONE]")
                        result.success("ok")
                    }
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) {
                        result.error("LLM_AUDIO_ERROR", e.message, null)
                    }
                } finally {
                    isInferenceRunning.set(false)
                }
            }
        }
    }

    // ─── CameraX Recording Logic ──────────────────────────────────────────────

    /**
     * Entry point for the startVideoRecording MethodCall.
     * Enforces the camera/audio permission chain, then checks the overlay
     * permission (SYSTEM_ALERT_WINDOW) before delegating to [startCameraXRecording].
     * Recording does NOT start until ALL permissions are confirmed.
     */
    private fun requestCameraPermissions(result: MethodChannel.Result) {
        val cameraGranted = ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.CAMERA
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val audioGranted = ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.RECORD_AUDIO
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

        if (!cameraGranted || !audioGranted) {
            pendingCameraResult = result
            requestPermissions(
                arrayOf(
                    android.Manifest.permission.CAMERA,
                    android.Manifest.permission.RECORD_AUDIO
                ),
                REQ_CAMERA_VIDEO
            )
            return
        }

        // Camera + Audio granted — now check overlay (SYSTEM_ALERT_WINDOW).
        if (!Settings.canDrawOverlays(this)) {
            Log.w("CameraX", "Overlay not granted — redirecting to Settings.")
            pendingCameraResult = result
            val intent = android.content.Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                android.net.Uri.parse("package:$packageName")
            )
            overlayPermissionLauncher.launch(intent)
            return
        }

        startCameraXRecording(result)
    }

    /**
     * Starts the CameraX recording and shows the floating preview overlay.
     * Binds [Preview] and [VideoCapture] together in one session so they share
     * the camera ISP pipeline without frame drops.
     */
    private fun startCameraXRecording(result: MethodChannel.Result) {
        if (recording != null) {
            result.error("ALREADY_RECORDING", "A recording is already in progress.", null)
            return
        }

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            try {
                val cameraProvider: ProcessCameraProvider = cameraProviderFuture.get()

                // ── Build the floating overlay BEFORE binding Preview ──────────
                showCameraOverlay()

                // ── Preview use-case (attached to the floating PreviewView) ────
                cameraPreview = Preview.Builder().build().also { preview ->
                    previewView?.let { preview.surfaceProvider = it.surfaceProvider }
                }

                // ── VideoCapture use-case ──────────────────────────────────────
                val recorder = Recorder.Builder()
                    .setQualitySelector(QualitySelector.from(Quality.HIGHEST))
                    .build()
                videoCapture = VideoCapture.withOutput(recorder)

                // ── Bind BOTH use-cases to the same camera session ─────────────
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this,
                    androidx.camera.core.CameraSelector.DEFAULT_BACK_CAMERA,
                    cameraPreview!!,
                    videoCapture!!
                )

                // ── Prepare MediaStore output ──────────────────────────────────
                val name = "Aitana-Video-" + System.currentTimeMillis() + ".mp4"
                val contentValues = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                        put(
                            android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                            "Movies/Aitana-Videos"
                        )
                    }
                }

                val mediaStoreOutputOptions = MediaStoreOutputOptions
                    .Builder(
                        contentResolver,
                        android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    )
                    .setContentValues(contentValues)
                    .build()

                recording = videoCapture!!.output
                    .prepareRecording(this, mediaStoreOutputOptions)
                    .apply {
                        if (ContextCompat.checkSelfPermission(
                                this@MainActivity,
                                android.Manifest.permission.RECORD_AUDIO
                            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                        ) {
                            withAudioEnabled()
                        }
                    }
                    .start(ContextCompat.getMainExecutor(this)) { recordEvent ->
                        when (recordEvent) {
                            is VideoRecordEvent.Start -> {
                                Log.i("CameraX", "✅ Video recording started")
                                // Notify Dart of the REAL hardware start
                                deviceEventSink?.success(mapOf("event" to "videoRecordingStarted"))
                            }
                            is VideoRecordEvent.Finalize -> {
                                Log.i("CameraX", "✅ Video recording finalized")
                                recording = null
                                hideCameraOverlay()
                                // Notify Dart of the real stop + output URI
                                val uri = recordEvent.outputResults.outputUri.toString()
                                deviceEventSink?.success(
                                    mapOf("event" to "videoRecordingStopped", "uri" to uri)
                                )
                            }
                            else -> Unit
                        }
                    }

                result.success("Recording started")
            } catch (exc: Exception) {
                hideCameraOverlay()
                result.error("CAMERA_ERROR", "Failed to start camera: ${exc.message}", null)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    /**
     * Creates and attaches the draggable [PreviewView] overlay — wrapped in a
     * "Safety Halo" [FrameLayout] — to the system [WindowManager].
     *
     * ## Safety Halo
     * A [GradientDrawable] border (Neon Purple → Deep Indigo, 8dp thick) is
     * applied as the [FrameLayout] background. A [ValueAnimator] pulses the
     * border alpha in an infinite reverse loop to create a breathing effect
     * that is visible even in bright ambient environments (e.g., driving).
     *
     * ## Double-Tap to Stop
     * A [GestureDetector] is layered over the touch pipeline. On double-tap:
     *  1. The breathing animator is cancelled.
     *  2. The border instantly turns solid red as visual confirmation.
     *  3. The container animates to 80% scale over 200 ms.
     *  4. [recording?.stop()] is called — the existing [VideoRecordEvent.Finalize]
     *     callback handles file save and window teardown automatically.
     *
     * ## Drag Coexistence
     * Every [MotionEvent] is dispatched to both the [GestureDetector] (for tap
     * classification) and the manual ACTION_MOVE handler (for window repositioning).
     * [GestureDetector.onTouchEvent] returns true only when it consumes the event
     * (e.g., a confirmed double-tap), allowing the drag logic to operate on all
     * other events without conflict.
     *
     * Safe to call multiple times — no-ops if the overlay is already shown.
     */
    private fun showCameraOverlay() {
        if (overlayView != null) return  // Already visible
        if (!Settings.canDrawOverlays(this)) {
            Log.e("CameraX", "showCameraOverlay() called without overlay permission — skipping.")
            return
        }

        val wm = getSystemService(WINDOW_SERVICE) as android.view.WindowManager

        // ── 1. PreviewView (camera feed, PERFORMANCE = TextureView pipeline) ───────
        //
        // PERFORMANCE mode uses a TextureView backed by a SurfaceTexture, living
        // inside the Activity's GL context. This is the only mode that renders above
        // the Keyguard because SurfaceView (used by COMPATIBLE) is composited by
        // SurfaceFlinger in a Z-layer behind the secure Keyguard window.
        val pv = PreviewView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ).also { lp ->
                // 8dp inset so the halo border is visible all around the preview
                val inset = dpToPx(8)
                lp.setMargins(inset, inset, inset, inset)
            }
            implementationMode = PreviewView.ImplementationMode.PERFORMANCE
        }
        previewView = pv

        // ── 2. Safety Halo border (GradientDrawable, Neon Purple → Deep Indigo) ────
        val haloBorder = GradientDrawable().apply {
            shape             = GradientDrawable.RECTANGLE
            gradientType      = GradientDrawable.LINEAR_GRADIENT
            orientation       = GradientDrawable.Orientation.TL_BR
            colors            = intArrayOf(
                Color.parseColor("#A020F0"),  // Neon Purple
                Color.parseColor("#4B0082")   // Deep Indigo
            )
            cornerRadius      = dpToPx(12).toFloat()
            // Stroke-only approach: fill is transparent, stroke carries the colour.
            // A stroke width of 8dp is clearly visible without obscuring the preview.
            setStroke(dpToPx(8), Color.parseColor("#A020F0"))
            setColor(Color.TRANSPARENT)
        }

        // ── 3. FrameLayout container (halo + PreviewView) ─────────────────────────
        val container = FrameLayout(this).apply {
            background = haloBorder
            addView(pv)
        }

        // ── 4. Breathing ValueAnimator (alpha 255 → 100 → 255, infinite) ──────────
        //
        // We animate the STROKE alpha via a custom property rather than view alpha
        // so that the PreviewView inside is never dimmed — only the border breathes.
        haloAnimator = ValueAnimator.ofInt(255, 100).apply {
            duration       = 1200L          // ms for one half-cycle (in or out)
            repeatCount    = ValueAnimator.INFINITE
            repeatMode     = ValueAnimator.REVERSE
            addUpdateListener { animator ->
                val alpha  = animator.animatedValue as Int
                val color  = Color.argb(
                    alpha,
                    0xA0,   // R component of #A020F0
                    0x20,   // G
                    0xF0    // B
                )
                haloBorder.setStroke(dpToPx(8), color)
            }
            start()
        }

        // ── 5. WindowManager LayoutParams (full overlay, Keyguard bypass) ─────────
        //
        // The outer size includes the 8dp margins on both sides, so the actual window
        // is 240 + 16 dp wide and 180 + 16 dp tall to accommodate the visible halo.
        val overlayW = dpToPx(256)  // 240 (preview) + 8 (left) + 8 (right)
        val overlayH = dpToPx(196)  // 180 (preview) + 8 (top)  + 8 (bottom)
        val params = WindowManager.LayoutParams(
            overlayW,
            overlayH,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // FLAG_NOT_FOCUSABLE  — window never steals keyboard focus
            // FLAG_SHOW_WHEN_LOCKED — this overlay window renders above the Keyguard
            //                        (does not inherit from Activity's setShowWhenLocked)
            // FLAG_TURN_SCREEN_ON — wakes screen if overlay appears before full brightness
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.CENTER
            x = 0
            y = 0
        }

        // ── 6. GestureDetector — double-tap to stop recording ─────────────────────
        val gestureDetector = GestureDetector(
            this,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onDoubleTap(e: MotionEvent): Boolean {
                    Log.i("CameraX", "Double-tap detected — stopping recording.")

                    // a) Stop the breathing animation immediately
                    haloAnimator?.cancel()
                    haloAnimator = null

                    // b) Flash the border red as visual confirmation
                    haloBorder.setStroke(dpToPx(8), Color.RED)

                    // c) Animate the container to 80% scale over 200 ms
                    container.animate()
                        .scaleX(0.8f)
                        .scaleY(0.8f)
                        .setDuration(200L)
                        .start()

                    // d) Stop the recording — VideoRecordEvent.Finalize handles
                    //    file saving, EventChannel notification, and overlay teardown.
                    recording?.stop()

                    // e) Immediately notify Flutter via the DEVICE_EVENTS channel so
                    //    the UI can show the SnackBar and inject AI context without
                    //    waiting for the Finalize callback (which includes the overlay
                    //    scale-down animation delay).
                    //    The uri field is empty here because the file path is not yet
                    //    known; Finalize will emit videoRecordingStopped with the real URI.
                    deviceEventSink?.success(
                        mapOf("event" to "videoRecordingStoppedManual")
                    )

                    return true  // event consumed
                }
            }
        )

        // ── 7. Touch listener: routes events to GestureDetector AND drag handler ───
        //
        // Strategy:
        //  • Every event is given to gestureDetector.onTouchEvent() for tap/double-tap
        //    classification. It returns true only when it definitively handles an event
        //    (i.e., on a confirmed double-tap).
        //  • ACTION_DOWN and ACTION_MOVE always update the drag origin/position so the
        //    window can be repositioned freely while double-tap detection continues.
        //  • We return true for DOWN and MOVE (always consumed) and defer to the
        //    gesture detector for UP/POINTER_UP events.
        var dragStartX = 0f
        var dragStartY = 0f
        container.setOnTouchListener { _, event ->
            // Let the gesture detector inspect the event first
            val gestureHandled = gestureDetector.onTouchEvent(event)

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    dragStartX = event.rawX - params.x
                    dragStartY = event.rawY - params.y
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = (event.rawX - dragStartX).toInt()
                    params.y = (event.rawY - dragStartY).toInt()
                    try {
                        wm.updateViewLayout(container, params)
                    } catch (_: IllegalArgumentException) { /* view detached race */ }
                    true
                }
                else -> gestureHandled
            }
        }

        wm.addView(container, params)
        overlayView = container
        Log.i("CameraX", "Safety Halo overlay shown (double-tap to stop).")
    }

    /**
     * Removes the floating Safety Halo overlay from [WindowManager].
     * Also cancels the breathing [haloAnimator] to prevent resource leaks on any
     * teardown path (normal stop, double-tap, or [onDestroy]).
     * Safe to call when no overlay is present — silently no-ops.
     */
    private fun hideCameraOverlay() {
        // Cancel the breathing animator regardless of whether the view is attached,
        // preventing an ObjectAnimator callback referencing a detached drawable.
        haloAnimator?.cancel()
        haloAnimator = null

        val view = overlayView ?: return
        try {
            val wm = getSystemService(WINDOW_SERVICE) as android.view.WindowManager
            wm.removeView(view)
        } catch (e: Exception) {
            Log.w("CameraX", "hideCameraOverlay: removeView failed — ${e.message}")
        } finally {
            overlayView = null
            previewView = null
            cameraPreview = null
        }
    }

    /** Converts dp units to pixels using the display density. */
    private fun dpToPx(dp: Int): Int =
        (dp * resources.displayMetrics.density).toInt()

    // ─── Engine & Conversation helpers ────────────────────────────────────────

    private fun closeLoadedAiEngine(clearActiveModel: Boolean, reason: String) {
        try {
            conversation?.close()
        } catch (e: Exception) {
            Log.w("LiteRT-LM", "Conversation close failed during $reason: ${e.message}")
        }
        conversation = null

        try {
            engine?.close()
        } catch (e: Exception) {
            Log.w("LiteRT-LM", "Engine close failed during $reason: ${e.message}")
        }
        engine = null

        if (clearActiveModel) {
            activeModelBaseName = null
        }
    }

    @OptIn(ExperimentalApi::class)
    private suspend fun getOrInitEngine(baseName: String): Engine {
        engineMutex.withLock {
            engine?.let {
                return it
            }

            val modelFile = resolveModelFile(baseName)
            val isVariant = baseName.contains("variant", ignoreCase = true)

            // 1. Conditional MTP: Only enable for the main E4B model.
            ExperimentalFlags.enableSpeculativeDecoding = !isVariant

            try {
                // Main Attempt: CPU with XNNPack (Most stable for MTP currently)
                val config = EngineConfig(
                    modelPath     = modelFile.absolutePath,
                    backend       = Backend.CPU(),
                    audioBackend  = Backend.CPU(),
                    visionBackend = Backend.CPU(),
                    cacheDir      = cacheDir.path
                )
                val eng = Engine(config)
                eng.initialize()
                
                val mtpStatus = if (!isVariant) "ON" else "OFF"
                Log.i("LiteRT-LM", "Engine listo con CPU ✓ (Speculative Decoding: $mtpStatus)")
                
                return eng.also { engine = it }

            } catch (e: Exception) {
                Log.e("LiteRT-LM", "Error crítico al inicializar el Engine: ${e.message}")
                throw e // Re-throw to handle it gracefully in the UI if possible
            }
        }
    }

    private suspend fun getOrInitConversation(
        systemInstructionText: String,
        samplerConfig: SamplerConfig,
        baseName: String
    ): Conversation {
        conversationMutex.withLock {
            conversation?.let { return it }

            val currentEngine = getOrInitEngine(baseName)

            val methodChannel = aiCoreMethodChannel
                ?: error("aiCoreMethodChannel not initialized")

            val config = ConversationConfig(
                systemInstruction = Contents.of(systemInstructionText),
                samplerConfig     = samplerConfig,
                tools             = listOf(tool(CalendarControls(methodChannel)), tool(VaultControls(methodChannel)))
            )

            Log.i(
                "LiteRT-LM",
                "New Conversation → SamplerConfig(" +
                        "temp=${samplerConfig.temperature}, " +
                        "topK=${samplerConfig.topK}, " +
                        "topP=${samplerConfig.topP})"
            )

            return currentEngine.createConversation(config).also { conversation = it }
        }
    }

    private fun extractSamplerConfig(call: MethodCall): SamplerConfig {
        val temperature = call.argument<Double>("temperature")
            ?: currentSamplerConfig.temperature
        val topK = call.argument<Int>("top_k")
            ?: currentSamplerConfig.topK
        val topP = call.argument<Double>("top_p")
            ?: currentSamplerConfig.topP

        return SamplerConfig(
            topK        = topK,
            topP        = topP,
            temperature = temperature
        )
    }

    // ─── Model file resolution ────────────────────────────────────────────────

    /**
     * Probes both the owned and raw shell paths for [baseName] without
     * performing any I/O side-effects. Used by the hot-swap validation gate
     * in [initModel] to confirm the target model exists before tearing down
     * the running engine.
     *
     * Returns `true` if either `{baseName}_owned.litertlm` or
     * `{baseName}.litertlm` is present in the app's external files directory.
     */
    private fun modelExistsOnDisk(baseName: String): Boolean {
        return ModelFileResolver.modelExistsOnDisk(this, baseName)
    }

    /**
     * Resolves or creates the owned `.litertlm` file for [baseName].
     *
     * Resolution order:
     *  1. If `{baseName}_owned.litertlm` already exists → return it (fast path).
     *  2. If `{baseName}.litertlm` (raw shell) exists → copy to owned, delete
     *     the shell, and return the new owned file (first-run ownership transfer).
     *  3. Neither file found → throw [IllegalStateException] with an ADB hint.
     *
     * @param baseName The model base name without extension (e.g. "gemma_4b").
     */
    private fun resolveModelFile(baseName: String): File {
        return ModelFileResolver.resolveForEngine(this, baseName)
    }

    /**
     * Calculates a SHA-256 hash of a file for deduplication in the Personal Vault.
     * Uses a buffer to handle large files efficiently on the IO thread.
     */
    private fun calculateSHA256(filePath: String): String {
        val file = File(filePath)
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            var bytesRead = input.read(buffer)
            while (bytesRead != -1) {
                digest.update(buffer, 0, bytesRead)
                bytesRead = input.read(buffer)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
