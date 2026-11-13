package dev.batman.batman_app.qr

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest

/**
 * 254-app-qr §1 (v2.3): the preview without camera-view's PreviewView, which brought appcompat, camera-video, media3
 * and guava into the process that holds K. A SurfaceView (not TextureView): the camera writes straight to its layer,
 * and setSecure(true) keeps that layer out of screenshots / Recents next to the window's FLAG_SECURE.
 * Main thread only. The buffer size is the request's resolution (Camera2 needs a supported size). The S20 showed it
 * stretched to the screen, so the SurfaceView is laid out at the buffer's on-screen aspect (rotation from the request's
 * TransformationInfo), center-cropped inside [root] ([ViewfinderFit]); scanning reads ImageAnalysis frames, not this.
 */
class Viewfinder(context: Context) : SurfaceHolder.Callback, Preview.SurfaceProvider {
    val view = SurfaceView(context).apply { setSecure(true) }
    /** what the Activity shows: a black frame that clips the centered, cropped preview */
    val root = FrameLayout(context).apply {
        setBackgroundColor(Color.BLACK)
        addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER))
    }
    private val main = context.mainExecutor
    private var request: SurfaceRequest? = null
    private var provided = false
    private var w = -1
    private var h = -1
    private var rotation = -1 // TransformationInfo.rotationDegrees; -1 = not known yet

    init {
        view.holder.addCallback(this)
        root.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob -> if (r - l != or - ol || b - t != ob - ot) fit() }
    }

    override fun onSurfaceRequested(r: SurfaceRequest) {
        request?.willNotProvideSurface()
        request = r
        provided = false
        r.addRequestCancellationListener(main) { if (request === r) request = null }
        r.setTransformationInfoListener(main) { if (request === r) { rotation = it.rotationDegrees; fit() } }
        view.holder.setFixedSize(r.resolution.width, r.resolution.height)
        offer()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {}

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        w = width; h = height
        offer()
    }

    // the camera must stop drawing into a destroyed surface: invalidate -> CameraX asks again once one exists
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        w = -1; h = -1
        val r = request ?: return
        request = null
        if (provided) r.invalidate() else r.willNotProvideSurface()
    }

    // the surface goes out once it exists at the requested size; the SurfaceView owns it, so the result needs no release
    private fun offer() {
        val r = request ?: return
        val s = view.holder.surface
        if (provided || s == null || !s.isValid || w != r.resolution.width || h != r.resolution.height) return
        provided = true
        r.provideSurface(s, main) { }
    }

    // the view at the buffer's on-screen aspect, covering the frame (the buffer size itself stays the request's)
    private fun fit() {
        val r = request ?: return
        if (rotation < 0 || root.width <= 0 || root.height <= 0) return
        val (cw, ch) = ViewfinderFit.displayed(r.resolution.width, r.resolution.height, rotation)
        val (vw, vh) = ViewfinderFit.centerCrop(cw, ch, root.width, root.height)
        val lp = view.layoutParams as FrameLayout.LayoutParams
        if (lp.width == vw && lp.height == vh) return
        view.layoutParams = FrameLayout.LayoutParams(vw, vh, Gravity.CENTER)
    }
}
