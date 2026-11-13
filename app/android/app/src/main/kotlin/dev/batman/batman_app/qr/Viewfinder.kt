package dev.batman.batman_app.qr

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest

/**
 * 254-app-qr §1 (v2.3): the preview without camera-view's PreviewView, which brought appcompat, camera-video, media3
 * and guava into the process that holds K. A SurfaceView (not TextureView): the camera writes straight to its layer,
 * and setSecure(true) keeps that layer out of screenshots / Recents next to the window's FLAG_SECURE.
 * Main thread only. The buffer size is the request's resolution (Camera2 needs a supported size), so the image is
 * scaled to the view, not cropped; scanning reads ImageAnalysis frames, not this preview.
 */
class Viewfinder(context: Context) : SurfaceHolder.Callback, Preview.SurfaceProvider {
    val view = SurfaceView(context).apply { setSecure(true) }
    private val main = context.mainExecutor
    private var request: SurfaceRequest? = null
    private var provided = false
    private var w = -1
    private var h = -1

    init {
        view.holder.addCallback(this)
    }

    override fun onSurfaceRequested(r: SurfaceRequest) {
        request?.willNotProvideSurface()
        request = r
        provided = false
        r.addRequestCancellationListener(main) { if (request === r) request = null }
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
}
