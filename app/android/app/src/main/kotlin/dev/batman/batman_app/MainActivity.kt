package dev.batman.batman_app

import dev.batman.batman_app.keystore.KeyPolicy
import dev.batman.batman_app.keystore.KeyRole
import dev.batman.batman_app.keystore.Keys
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
                else -> result.notImplemented()
            }
        }
    }
}
