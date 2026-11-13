package dev.batman.batman_app.qr

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 254-app-qr §2: the claim-QR camera scanner, started by MainActivity's `scanQr` with the call's gen. Not exported, own
 * empty task affinity, FLAG_SECURE (the preview shows K). Answers [QrScan.shared] on the main thread: the first decoded
 * text, null when left without one, fail() when the camera cannot be used. The text is never logged, put in an Intent
 * or stored.
 */
class QrScanActivity : ComponentActivity() {
    private var gen = 0L
    private var worker: ExecutorService? = null
    private lateinit var finder: Viewfinder
    private val ask = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) bind() else fail() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        gen = intent.getLongExtra(EXTRA_GEN, 0L)
        // not the pending call's Activity (e.g. restored from Recents after the process was killed): no camera (B r2-m3)
        if (!intent.hasExtra(EXTRA_GEN) || !QrScan.shared.isCurrent(gen)) {
            finish()
            return
        }
        worker = Executors.newSingleThreadExecutor()
        finder = Viewfinder(this)
        setContentView(finder.root)
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) bind()
        else ask.launch(Manifest.permission.CAMERA)
    }

    override fun onDestroy() {
        if (isFinishing) QrScan.shared.take(gen)?.done(null) // back / cancel without a code
        worker?.shutdown()
        super.onDestroy()
    }

    // no camera, a failed bind -> error `camera`; a camera in use / disabled / broken arrives later as a CameraState
    // error (bindToLifecycle does not throw for it, code review r1 A-M1) -> error `camera` too ([CameraErrors])
    private fun bind() {
        val f = ProcessCameraProvider.getInstance(this)
        f.addListener({
            try {
                val preview = Preview.Builder().build().also { it.setSurfaceProvider(mainExecutor, finder) }
                val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysis.setAnalyzer(worker!!) { analyze(analysis, it) }
                val p = f.get()
                p.unbindAll()
                val camera = p.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                camera.cameraInfo.cameraState.observe(this) { if (CameraErrors.endsScan(it.error?.code)) fail() }
            } catch (e: Exception) {
                fail()
            }
        }, mainExecutor)
    }

    // the analyzer thread: decode only; the answer goes out on the main thread (A r2-M1)
    private fun analyze(analysis: ImageAnalysis, image: ImageProxy) {
        var text: String? = null
        try {
            val y = image.planes[0]
            text = QrDecode.fromPlane(y.buffer, y.rowStride, y.pixelStride, image.width, image.height)
        } catch (e: Exception) {
            // a bad frame is dropped; nothing about it is logged
        } finally {
            image.close()
        }
        if (text == null) return
        analysis.clearAnalyzer() // A r3-3: the first code ends the scan
        runOnUiThread {
            // A-m3: this instance was recreated meanwhile (no configChanges: dark mode, density, multi-window); the new
            // one holds the same gen and scans again
            if (isDestroyed) return@runOnUiThread
            QrScan.shared.take(gen)?.done(text)
            finish() // also when the call was answered or dropped meanwhile (A r2-m6)
        }
    }

    private fun fail() {
        QrScan.shared.take(gen)?.fail()
        finish()
    }

    companion object {
        const val EXTRA_GEN = "dev.batman.batman_app.qr.GEN"
    }
}
