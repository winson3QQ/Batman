package dev.batman.batman_app.qr

/**
 * 254-app-qr on-device fix (S20: the preview was stretched): the size the preview SurfaceView is laid out at so the
 * camera image keeps its aspect ratio. Pure, so the JVM tests run it.
 * - [displayed]: the buffer as it appears on screen — width and height swap when the camera image is rotated 90° / 270°
 *   to display it (SurfaceRequest.TransformationInfo.rotationDegrees; the S20's back sensor is mounted at 90°).
 * - [centerCrop]: the smallest size at that aspect that covers the whole container; the view is centered and the
 *   overflow is clipped. Fill, not fit: the whole screen is viewfinder (no bars to aim around) and only the preview's
 *   edges are lost — the decoder reads the full ImageAnalysis frame.
 */
object ViewfinderFit {
    fun displayed(bufW: Int, bufH: Int, rotationDegrees: Int): Pair<Int, Int> =
        if (rotationDegrees % 180 != 0) bufH to bufW else bufW to bufH

    fun centerCrop(contentW: Int, contentH: Int, containerW: Int, containerH: Int): Pair<Int, Int> {
        if (contentW <= 0 || contentH <= 0 || containerW <= 0 || containerH <= 0) return containerW to containerH
        val scale = maxOf(containerW.toDouble() / contentW, containerH.toDouble() / contentH)
        return Math.round(contentW * scale).toInt() to Math.round(contentH * scale).toInt()
    }
}
