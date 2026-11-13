package dev.batman.batman_app.qr

import androidx.camera.core.CameraState

/**
 * 254-app-qr §2 (code review r1 A-M1, r2-m1): a camera that is in use, disabled or broken does not make
 * bindToLifecycle throw — it shows up later as a CameraState error, and the screen would stay black. Every error ends
 * the scan with error `camera` except ERROR_OTHER_RECOVERABLE_ERROR (CameraX retries it). camera-core 1.6.2
 * StateError.getType(): codes 2 (IN_USE), 1 (MAX_CAMERAS_IN_USE), 3 (OTHER_RECOVERABLE_ERROR) are RECOVERABLE, all
 * others CRITICAL (STREAM_CONFIG included). IN_USE / MAX_CAMERAS_IN_USE are recoverable for CameraX (it waits for the
 * camera), but a user looking at a black screen is better told why.
 */
object CameraErrors {
    /** [code] = CameraState.error?.code (null = no error) */
    fun endsScan(code: Int?): Boolean = code != null && code != CameraState.ERROR_OTHER_RECOVERABLE_ERROR
}
