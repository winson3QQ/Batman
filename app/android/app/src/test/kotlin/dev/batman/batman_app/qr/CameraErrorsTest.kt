package dev.batman.batman_app.qr

import androidx.camera.core.CameraState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 254-app-qr code review r1 A-M1: which CameraState errors end the scan with error `camera` */
class CameraErrorsTest {
    @Test fun cameraUnusableEndsTheScan() {
        for (c in listOf(
            CameraState.ERROR_CAMERA_IN_USE, CameraState.ERROR_MAX_CAMERAS_IN_USE, CameraState.ERROR_CAMERA_DISABLED,
            CameraState.ERROR_CAMERA_FATAL_ERROR, CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED, CameraState.ERROR_CAMERA_REMOVED,
        )) assertTrue("code $c", CameraErrors.endsScan(c))
    }

    @Test fun recoverableOrNoErrorKeepsScanning() {
        assertFalse(CameraErrors.endsScan(null))
        assertFalse(CameraErrors.endsScan(CameraState.ERROR_OTHER_RECOVERABLE_ERROR))
        assertFalse(CameraErrors.endsScan(CameraState.ERROR_STREAM_CONFIG))
    }
}
