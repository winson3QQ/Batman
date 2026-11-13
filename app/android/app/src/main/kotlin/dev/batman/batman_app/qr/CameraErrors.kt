package dev.batman.batman_app.qr

import androidx.camera.core.CameraState

/**
 * 254-app-qr §2 (code review r1 A-M1): a camera that is in use, disabled or broken does not make bindToLifecycle
 * throw — it shows up later as a CameraState error, and the screen would stay black. These codes end the scan with
 * error `camera`. Left to CameraX (it retries / reconfigures, the preview comes back): ERROR_OTHER_RECOVERABLE_ERROR,
 * ERROR_STREAM_CONFIG. IN_USE / MAX_CAMERAS_IN_USE are recoverable for CameraX (it waits for the camera), but a user
 * looking at a black screen is better told why.
 */
object CameraErrors {
    private val ending = setOf(
        CameraState.ERROR_CAMERA_IN_USE,
        CameraState.ERROR_MAX_CAMERAS_IN_USE,
        CameraState.ERROR_CAMERA_DISABLED,
        CameraState.ERROR_CAMERA_FATAL_ERROR,
        CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED,
        CameraState.ERROR_CAMERA_REMOVED,
    )

    /** [code] = CameraState.error?.code (null = no error) */
    fun endsScan(code: Int?): Boolean = code != null && code in ending
}
