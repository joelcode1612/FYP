package com.example.fyp.camera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Rear-camera intrinsics for the 360° capture plan.
 *
 * The Flutter `camera` plugin exposes no intrinsics on Android, so the capture
 * plan used to assume a 65° vertical field of view for every device. That
 * assumption is only safe while it is *conservative*: it makes the planned
 * spacing tighter than the lens needs, which costs photographs but never
 * leaves a gap. It is not safe for projection — the backend scales every frame
 * by `focal_px`, and a focal that is 10% wrong stretches the panorama and
 * smears seams.
 *
 * This channel reports what the device actually knows:
 *
 *  * `focalLengthMm` — LENS_INFO_AVAILABLE_FOCAL_LENGTHS[0], the wide lens;
 *  * `sensorWidthMm` / `sensorHeightMm` — SENSOR_INFO_PHYSICAL_SIZE;
 *  * `pixelArrayWidth` / `pixelArrayHeight` — SENSOR_INFO_PIXEL_ARRAY_SIZE,
 *    the full sensor raster the saved JPEG is derived from;
 *  * `activeArrayWidth` / `activeArrayHeight` — SENSOR_INFO_ACTIVE_ARRAY_SIZE,
 *    which excludes the optical-black border;
 *  * `sensorOrientation` — SENSOR_ORIENTATION (90 on a typical phone);
 *  * `horizontalFovDeg` / `verticalFovDeg` when the platform reports them.
 *
 * Everything is nullable: a device that does not report a field returns null
 * for it, and the Dart side falls back to its documented assumption rather
 * than inventing a number. No value here is claimed to be calibrated beyond
 * what the platform states.
 */
class CameraIntrinsicsChannel(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "adaptive360/camera_intrinsics"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "rearCameraIntrinsics") {
            result.notImplemented()
            return
        }
        try {
            result.success(rearCameraIntrinsics())
        } catch (error: Exception) {
            // A camera service that refuses to enumerate must not break the
            // capture flow: the caller falls back to the documented assumption.
            result.error("camera_intrinsics_unavailable", error.message, null)
        }
    }

    private fun rearCameraIntrinsics(): Map<String, Any?> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = manager.cameraIdList.firstOrNull { id ->
            manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: return mapOf("available" to false)

        val characteristics = manager.getCameraCharacteristics(cameraId)
        val focalLengths = characteristics
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val physicalSize = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val pixelArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        val activeArray = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION)

        val focalMm = focalLengths?.minOrNull()?.toDouble()
        val sensorWidthMm = physicalSize?.width?.toDouble()
        val sensorHeightMm = physicalSize?.height?.toDouble()

        // Focal length in *pixel-array* pixels: the conversion the projection
        // needs. Pixels per millimetre comes from the physical sensor size, so
        // it stays correct for a device whose saved JPEG is a crop.
        val focalPx: Double? =
            if (focalMm != null && sensorWidthMm != null && pixelArray != null &&
                sensorWidthMm > 0.0
            ) {
                focalMm * (pixelArray.width.toDouble() / sensorWidthMm)
            } else null

        var horizontalFovDeg: Double? = null
        var verticalFovDeg: Double? = null
        if (focalMm != null && sensorWidthMm != null && sensorHeightMm != null &&
            focalMm > 0.0
        ) {
            horizontalFovDeg = Math.toDegrees(2.0 * Math.atan(sensorWidthMm / (2.0 * focalMm)))
            verticalFovDeg = Math.toDegrees(2.0 * Math.atan(sensorHeightMm / (2.0 * focalMm)))
        }

        return mapOf(
            "available" to (focalPx != null),
            "cameraId" to cameraId,
            "focalLengthMm" to focalMm,
            "sensorWidthMm" to sensorWidthMm,
            "sensorHeightMm" to sensorHeightMm,
            "focalPxSensor" to focalPx,
            "pixelArrayWidth" to pixelArray?.width,
            "pixelArrayHeight" to pixelArray?.height,
            "activeArrayWidth" to activeArray?.width(),
            "activeArrayHeight" to activeArray?.height(),
            "activeArrayLeft" to activeArray?.left,
            "activeArrayTop" to activeArray?.top,
            "sensorOrientation" to orientation,
            "horizontalFovDeg" to horizontalFovDeg,
            "verticalFovDeg" to verticalFovDeg,
            "apiLevel" to Build.VERSION.SDK_INT,
        )
    }
}
