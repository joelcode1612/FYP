package com.example.fyp

import android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
import com.example.fyp.camera.CameraIntrinsicsChannel
import com.example.fyp.sensors.RotationSensorChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var rotationChannel: EventChannel? = null
    private var screenChannel: MethodChannel? = null
    private var intrinsicsChannel: MethodChannel? = null

    /**
     * Registers the platform channels the 3DoF sphere capture needs.
     *
     * The rotation channel is the only sensor the sphere-follows-phone flow
     * needs: `TYPE_ROTATION_VECTOR` at roughly 50 Hz on `adaptive360/rotation`.
     * The camera-intrinsics channel feeds the adaptive capture plan's measured
     * lens profile, and the screen channel keeps the display awake for the
     * duration of a sweep.
     *
     * The ARCore host and the MediaStore gallery writer of the previous capture
     * engines were removed with those engines: no active feature opens an AR
     * session or writes to the shared Pictures collection any more.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "adaptive360/rotation",
        )
        channel.setStreamHandler(RotationSensorChannel(applicationContext))
        rotationChannel = channel

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

        // Rear-camera intrinsics for the capture plan and the backend
        // projection. Read-only: it reports what the platform exposes and
        // nothing else.
        intrinsicsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CameraIntrinsicsChannel.CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(CameraIntrinsicsChannel(applicationContext))
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        rotationChannel?.setStreamHandler(null)
        rotationChannel = null
        screenChannel?.setMethodCallHandler(null)
        screenChannel = null
        intrinsicsChannel?.setMethodCallHandler(null)
        intrinsicsChannel = null
        window.clearFlags(FLAG_KEEP_SCREEN_ON)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
