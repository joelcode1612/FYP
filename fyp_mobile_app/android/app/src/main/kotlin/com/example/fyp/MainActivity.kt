package com.example.fyp

import android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
import com.example.fyp.ar.ArCoreCapturePlugin
import com.example.fyp.media.MediaStoreChannel
import com.example.fyp.sensors.RotationSensorChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var rotationChannel: EventChannel? = null
    private var mediaChannel: MethodChannel? = null
    private var screenChannel: MethodChannel? = null

    /**
     * Registers the ARCore host (other features still use it) and the 3DoF
     * rotation sensor of the 38-target sphere capture.
     *
     * The rotation channel is the only sensor the sphere-follows-phone flow
     * needs: `TYPE_ROTATION_VECTOR` at roughly 50 Hz on `adaptive360/rotation`.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ArCoreCapturePlugin())
        val channel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "adaptive360/rotation",
        )
        channel.setStreamHandler(RotationSensorChannel(applicationContext))
        rotationChannel = channel

        // Saves the finished panorama into the shared Pictures collection so
        // it appears in the phone's Gallery, not only in app-private storage.
        val media = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "adaptive360/media",
        )
        media.setMethodCallHandler(MediaStoreChannel(applicationContext))
        mediaChannel = media

        screenChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "adaptive360/screen",
        ).also { screen ->
            screen.setMethodCallHandler { call, result ->
                if (call.method != "setKeepScreenOn") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val enabled = call.arguments as? Boolean
                if (enabled == null) {
                    result.error("invalid_argument", "Expected a boolean", null)
                    return@setMethodCallHandler
                }
                if (enabled) window.addFlags(FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(FLAG_KEEP_SCREEN_ON)
                result.success(null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        rotationChannel?.setStreamHandler(null)
        rotationChannel = null
        mediaChannel?.setMethodCallHandler(null)
        mediaChannel = null
        screenChannel?.setMethodCallHandler(null)
        screenChannel = null
        window.clearFlags(FLAG_KEEP_SCREEN_ON)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
