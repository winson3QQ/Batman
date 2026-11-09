package dev.batman.batman_app

import dev.batman.batman_app.keystore.KeyPolicy
import dev.batman.batman_app.keystore.KeyRole
import dev.batman.batman_app.keystore.Keys
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.content.pm.PackageManager

class MainActivity : FlutterActivity() {
    // BLE (design §2 BLE rules): scan + connect only, never pairing; BLUETOOTH_SCAN is declared neverForLocation
    private val blePerms = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    private var blePending: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == BLE_REQ) {
            blePending?.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
            blePending = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.batman/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                // the flavor's build constant, compared with the Rust library's at startup (design v8.5.1 §4.1)
                "devTrust" -> result.success(BuildConfig.DEV_TRUST)
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
                "keyLevels" -> try {
                    val levels = Keys().levels()
                    val a = KeyPolicy.abilities(levels, BuildConfig.DEV_TRUST)
                    result.success(
                        KeyRole.values().associate { it.name to levels[it] } + mapOf(
                            "appUsable" to a.appUsable, "claim" to a.claim, "login" to a.login,
                            "recover" to a.recover, "makeNetwork" to a.makeNetwork, "softOwnerEnc" to a.softOwnerEnc,
                        )
                    )
                } catch (e: Exception) {
                    result.error("keystore", e.javaClass.simpleName, null)
                }
                // the claim path (design §5.1): public keys, sig_enc (owner key, allow-listed input only), record sealing.
                // Keystore work off the UI thread; failures come back as errors, never as a guessed value.
                "publicKeys" -> Thread {
                    val r = runCatching { mapOf("owner" to Keys().publicKey65(KeyRole.OWNER_SIGN), "ownerEnc" to Keys().publicKey65(KeyRole.OWNER_ENC), "admin" to Keys().publicKey65(KeyRole.ADMIN_SIGN)) }
                    runOnUiThread { r.fold({ result.success(it) }, { result.error("keystore", "${it.javaClass.simpleName}: ${it.message}", null) }) }
                }.start()
                "signOwner" -> Thread {
                    val input = call.argument<ByteArray>("input")
                    val r = runCatching { Keys().sign(KeyRole.OWNER_SIGN, requireNotNull(input) { "no input" }) }
                    runOnUiThread { r.fold({ result.success(it) }, { result.error("keystore", "${it.javaClass.simpleName}: ${it.message}", null) }) }
                }.start()
                // make-network (design §5.4): the admin key signs only COSE Sig_structures (SignAllowList.adminMaySign)
                "signAdmin" -> Thread {
                    val input = call.argument<ByteArray>("input")
                    val r = runCatching { Keys().sign(KeyRole.ADMIN_SIGN, requireNotNull(input) { "no input" }) }
                    runOnUiThread { r.fold({ result.success(it) }, { result.error("keystore", "${it.javaClass.simpleName}: ${it.message}", null) }) }
                }.start()
                "open" -> Thread {
                    val sealed = call.argument<ByteArray>("sealed"); val aad = call.argument<ByteArray>("aad")
                    val r = runCatching { Keys().open(requireNotNull(sealed) { "no record" }, requireNotNull(aad) { "no aad" }) }
                    runOnUiThread { r.fold({ result.success(it) }, { result.error("keystore", "${it.javaClass.simpleName}: ${it.message}", null) }) }
                }.start()
                "seal" -> Thread {
                    val plain = call.argument<ByteArray>("plain"); val aad = call.argument<ByteArray>("aad")
                    val r = runCatching { Keys().seal(requireNotNull(plain) { "no plain" }, requireNotNull(aad) { "no aad" }) }
                    runOnUiThread { r.fold({ result.success(it) }, { result.error("keystore", "${it.javaClass.simpleName}: ${it.message}", null) }) }
                }.start()
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
