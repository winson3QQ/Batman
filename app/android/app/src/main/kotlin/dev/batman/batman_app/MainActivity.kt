package dev.batman.batman_app

import dev.batman.batman_app.keystore.KeyAnswer
import dev.batman.batman_app.keystore.KeyHandlers
import dev.batman.batman_app.keystore.KeyRole
import dev.batman.batman_app.keystore.Keys
import dev.batman.batman_app.qr.QrScan
import dev.batman.batman_app.qr.QrScanActivity
import dev.batman.batman_app.swupd.SwUpload
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.content.pm.PackageManager

class MainActivity : FlutterActivity() {
    // BLE (design §2 BLE rules): scan + connect only, never pairing; BLUETOOTH_SCAN is declared neverForLocation
    private val blePerms = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    private var blePending: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // v0.4.3: a node reboot while connected must not kill the app (BleRx); before the engine starts BLE work
        BleRx.install { Log.i("BMAPP", it) }
        super.onCreate(savedInstanceState)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == BLE_REQ) {
            blePending?.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
            blePending = null
        }
    }

    // software update (254-app-update §11.1): channel dev.batman/swupdate
    private var swUpload: SwUpload? = null

    @Deprecated("FlutterActivity is a plain Activity: the SAF picker answers here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (swUpload?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        swUpload?.dispose()
        swUpload = null
        QrScan.shared.dropOwner(this) // 254-app-qr §2: a scan this engine started is not answered any more
        super.onDestroy()
    }

    // 254-app-qr §2: one scan at a time (busy otherwise); QrScanActivity answers in memory, never through the Intent
    private fun scanQr(result: MethodChannel.Result) {
        val gen = QrScan.shared.put(this, object : QrScan.Reply {
            override fun done(text: String?) = result.success(text)
            override fun fail() = result.error("camera", null, null)
        }) ?: return result.error("busy", null, null)
        try {
            startActivity(Intent(this, QrScanActivity::class.java).putExtra(QrScanActivity.EXTRA_GEN, gen))
        } catch (e: Exception) {
            QrScan.shared.take(gen)?.fail() // A r2-m1: no slot left stuck
        }
    }

    // design 254-app-s1 §4.1: the key uses of the channel (keyLevels / signOwner / signAdmin / ecdh / seal) are
    // KeyHandlers' (pure, JVM-tested): it reads the four live levels and KeyPolicy decides before a key is touched,
    // whatever the Dart side checked or skipped. Here a call is only forwarded, off the UI thread (every Keystore read
    // is), and the answer handed back; [wipe] zeroes a secret (ECDH z) once handed over. Not gated: `open` (record
    // decryption), `publicKeys`, and `firstRun` (generation + self-test at first install).
    private fun keyCall(result: MethodChannel.Result, wipe: Boolean = false, f: (KeyHandlers) -> KeyAnswer) = Thread {
        val a = try {
            f(Keys().handlers(BuildConfig.DEV_TRUST))
        } catch (e: Exception) {
            KeyAnswer.Err("keystore", "${e.javaClass.simpleName}: ${e.message}", null) // the Keystore itself did not open
        }
        runOnUiThread {
            when (a) {
                is KeyAnswer.Ok -> { result.success(a.value); if (wipe) (a.value as? ByteArray)?.fill(0) }
                is KeyAnswer.Err -> result.error(a.code, a.message, a.details)
            }
        }
    }.start()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        swUpload?.dispose()
        swUpload = SwUpload(this, flutterEngine.dartExecutor.binaryMessenger)
        // design 254-app-s1 §4: FLAG_SECURE while a page that shows a secret is up (lib/secure_screen.dart); the answer
        // is the state the window now has. A new Activity's window starts without the flag.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SecureScreen.CHANNEL).setMethodCallHandler { call, result ->
            val on = SecureScreen.wanted(call.method, call.arguments) ?: return@setMethodCallHandler result.error("arg", null, null)
            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            result.success(window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.batman/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                // the flavor's build constant, compared with the Rust library's at startup (design v8.5.1 §4.1)
                "devTrust" -> result.success(BuildConfig.DEV_TRUST)
                // #329 §5.8 10.6 (A5): the version the build carries (pubspec version)
                "appVersion" -> result.success(BuildConfig.VERSION_NAME)
                // the app-private directory the Rust record store lives in
                "filesDir" -> result.success(filesDir.absolutePath)
                // first install only (Dart checked: no marker, no record): four keys, all or nothing
                "firstRun" -> Thread {
                    val r = try {
                        Result.success(Keys().firstRun().mapKeys { it.key.name })
                    } catch (e: Exception) {
                        Result.failure(e)
                    }
                    runOnUiThread {
                        r.fold({ result.success(it) }, { result.error("firstRun", "${it.javaClass.simpleName}: ${it.message}", null) })
                    }
                }.start()
                // the live level of each key (null = no key yet) and what that allows; no key is generated here
                "keyLevels" -> keyCall(result) { it.keyLevels() }
                // the claim path (design §5.1): public keys, sig_enc (owner key, allow-listed input only), record sealing.
                // Failures come back as errors, never as a guessed value.
                "publicKeys" -> Thread {
                    val r = runCatching { mapOf("owner" to Keys().publicKey65(KeyRole.OWNER_SIGN), "ownerEnc" to Keys().publicKey65(KeyRole.OWNER_ENC), "admin" to Keys().publicKey65(KeyRole.ADMIN_SIGN)) }
                    runOnUiThread { r.fold({ result.success(it) }, { result.error("keystore", "${it.javaClass.simpleName}: ${it.message}", null) }) }
                }.start()
                "signOwner" -> keyCall(result) { it.signOwner(call.argument<ByteArray>("input")) }
                // make-network (design §5.4): the admin key signs only COSE Sig_structures (SignAllowList.adminMaySign)
                "signAdmin" -> keyCall(result) { it.signAdmin(call.argument<ByteArray>("input")) }
                // remote invites (254-app-member-join §2): ECDH of the owner_enc key with an approval's ephemeral key.
                // Dev builds only, a P-256 peer (KeyHandlers.ecdh); z is zeroed once handed over; any failure is an
                // error and the caller writes nothing.
                "ecdh" -> keyCall(result, wipe = true) { it.ecdh(call.argument<ByteArray>("peer")) }
                "open" -> Thread {
                    val sealed = call.argument<ByteArray>("sealed"); val aad = call.argument<ByteArray>("aad")
                    val r = runCatching { Keys().open(requireNotNull(sealed) { "no record" }, requireNotNull(aad) { "no aad" }) }
                    runOnUiThread { r.fold({ result.success(it) }, { result.error("keystore", "${it.javaClass.simpleName}: ${it.message}", null) }) }
                }.start()
                "seal" -> keyCall(result) { it.seal(call.argument<ByteArray>("plain"), call.argument<ByteArray>("aad")) }
                // the claim QR from the camera (254-app-qr): the text, null when left without one, error `camera` / `busy`
                "scanQr" -> scanQr(result)
                // true when both BLE permissions are granted (asks once if not)
                "blePermissions" -> {
                    if (blePerms.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) result.success(true)
                    else if (blePending != null) result.error("ble", "a permission request is already open", null)
                    else { blePending = result; requestPermissions(blePerms, BLE_REQ) }
                }
                else -> result.notImplemented()
            }
        }
    }
}

private const val BLE_REQ = 4201
