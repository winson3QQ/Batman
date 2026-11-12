package dev.batman.batman_app.swupd

import android.app.Activity
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

/**
 * 254-app-update v0.4 §11.1: the Kotlin side of the software update, channel `dev.batman/swupdate`.
 * - `pickUpdateFiles` (D1, U1): SAF; Rust tells the two files apart. A gzip file is read only for its first 2 bytes.
 * - `findNodeNetwork` / `joinAp` (D5, [SwNet]): the Network the PUT goes out on, remembered here.
 * - `upload` / `cancelUpload` / `uploadProgress` (D4, [SwPut]): the raw-socket PUT on that Network's socket factory.
 * - `keepScreenOn` (D9), `wifiPanel` (U5).
 * Work runs off the UI thread; results go back on it. Errors are `result.error(code, null, null)` only (D8: no message,
 * no details). Nothing is logged and nothing is persisted (D7): the AP passphrase and the bearer live only in the call
 * arguments, the specifier and the request bytes; the picked URIs and the Network only in memory, cleared by
 * `cancelUpload` / [dispose].
 */
class SwUpload(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val lock = Any()
    private var pickPending: MethodChannel.Result? = null
    private val picked = HashSet<String>() // URIs the picker handed out in this process; `upload` reads only these
    private var network: Network? = null // the one `upload` uses (direct, or the Specifier's)
    @Volatile private var put: SwPut? = null
    @Volatile private var running = false
    /** the last PUT's non-secret code (refused / unreached / connect_io / file_io / watchdog / status / io / ...), v0.4.2 */
    @Volatile private var lastCode = ""
    /** cancelUpload calls so far: a lookup that started before one does not remember its network (r1 B-m3) */
    @Volatile private var cancels = 0
    private val net = SwNet(activity) { lost ->
        synchronized(lock) { if (network == lost) network = null }
        put?.abort("network_lost") // D4: the Specifier network's onLost aborts the socket (linger 0)
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickUpdateFiles" -> pick(result)
                "findNodeNetwork" -> {
                    val ip = call.argument<String>("ip")?.let(SwPut::ipv4)
                    if (ip == null) result.error("args", null, null)
                    else bg(result, "network") {
                        // r1 A-M2 / B-M1: the Specifier network this stage holds is the one to use again (no new request)
                        val gen = cancels // first (r2 B m-r2-4): a cancel after this point is seen below
                        val held = net.held()
                        val n = held ?: net.findDirect(ip)
                        synchronized(lock) { if (n != null && gen == cancels) network = n }
                        n != null && gen == cancels
                    }
                }
                "joinAp" -> {
                    val ssid = call.argument<String>("ssid"); val pass = call.argument<String>("pass")
                    if (ssid.isNullOrEmpty() || pass.isNullOrEmpty()) result.error("args", null, null)
                    else bg(result, "network") {
                        val (answer, n) = net.join(ssid, pass)
                        if (n != null) synchronized(lock) { network = n }
                        answer
                    }
                }
                "upload" -> upload(call.argument<String>("uri"), call.argument<Number>("size")?.toLong(),
                    call.argument<String>("ip"), call.argument<Number>("port")?.toInt(), call.argument<String>("bearer"), result)
                "cancelUpload" -> bg(result, "cancel") { cancelUpload(); null }
                // v0.4.2 (04 + S20: WireGuard took every PUT into tun0, the node saw no SYN): is this app's default
                // network a VPN? ConnectivityManager.getActiveNetwork() is the calling app's default network — the
                // VPN when one applies to our UID (AOSP ConnectivityService.getActiveNetwork -> getActiveNetworkForUid)
                "vpnActive" -> bg(result, "network") { vpnCovers() }
                "lastUploadCode" -> result.success(lastCode)
                "uploadProgress" -> result.success(put?.takeIf { running }?.sent ?: 0L)
                "keepScreenOn" -> {
                    val on = call.argument<Boolean>("on")
                    if (on == null) result.error("args", null, null) else {
                        if (on) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                }
                "wifiPanel" -> try {
                    activity.startActivity(Intent(Settings.Panel.ACTION_WIFI)); result.success(null)
                } catch (e: Exception) {
                    result.error("panel", null, null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** MainActivity forwards its onActivityResult here; true = it was the picker's. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQ) return false
        val result = synchronized(lock) { pickPending.also { pickPending = null } } ?: return true
        val uris = ArrayList<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add)
            else data.data?.let(uris::add)
        }
        bg(result, "pick") {
            uris.map { describe(it) }.also { synchronized(lock) { uris.forEach { u -> picked.add(u.toString()) } } }
        }
        return true
    }

    /** The activity is going away: abort, release, forget (D7). */
    fun dispose() {
        channel.setMethodCallHandler(null)
        cancelUpload()
        synchronized(lock) { picked.clear() }
        net.dispose()
    }

    private fun pick(result: MethodChannel.Result) {
        synchronized(lock) {
            if (pickPending != null) { result.error("busy", null, null); return }
            pickPending = result
        }
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        try {
            @Suppress("DEPRECATION") activity.startActivityForResult(i, PICK_REQ)
        } catch (e: Exception) {
            synchronized(lock) { pickPending = null }
            result.error("pick", null, null)
        }
    }

    // §11.1 pickUpdateFiles: {uri, size (statSize, -1 unknown), head (<= 2 bytes), data (the whole file, only when not
    // gzip and 0 <= size <= 64 KiB; at most 64 KiB + 1 read, more -> empty)}. A read failure throws -> error("pick").
    private fun describe(uri: Uri): Map<String, Any> {
        val cr = activity.contentResolver
        val size = cr.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
        val (head, data) = (cr.openInputStream(uri) ?: throw IOException()).use { inp -> SwPick.readHead(inp, size) }
        return mapOf("uri" to uri.toString(), "size" to size, "head" to head, "data" to data)
    }

    private fun upload(uri: String?, size: Long?, ip: String?, port: Int?, bearer: String?, result: MethodChannel.Result) {
        val addr = ip?.let(SwPut::ipv4)
        if (uri == null || size == null || size <= 0 || addr == null || port == null || port !in 1..65535 ||
            bearer == null || !SwPut.isBearerHex(bearer) || synchronized(lock) { uri !in picked }) {
            result.error("args", null, null); return
        }
        val p = SwPut()
        val n = synchronized(lock) {
            if (running) { result.error("busy", null, null); return }
            network?.also { running = true; put = p }
        } ?: run { lastCode = "no_network_held"; result.success(SwPut.Result.NO_NETWORK.wire); return }
        Thread({
            val o = try {
                p.put(n.socketFactory, addr, port, bearer, size) {
                    activity.contentResolver.openInputStream(Uri.parse(uri)) ?: throw IOException()
                }
            } catch (e: Exception) {
                SwPut.Outcome(SwPut.Result.OTHER, "error")
            }
            running = false
            lastCode = o.code
            activity.runOnUiThread { result.success(o.result.wire) }
        }, "swupd-put").start()
    }

    private fun vpnCovers(): Boolean {
        val cm = activity.getSystemService(ConnectivityManager::class.java)
        val n = cm.activeNetwork ?: return false
        return SwPut.vpnCovers(cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
    }

    // §11.1 cancelUpload: abort the PUT (linger 0), release the Specifier network, forget the chosen Network
    private fun cancelUpload() {
        cancels++
        put?.abort("cancelled")
        net.release()
        synchronized(lock) { network = null }
    }

    // background work, the answer on the UI thread; a failure is error(code) without message or details (D8)
    private fun <T> bg(result: MethodChannel.Result, code: String, work: () -> T) {
        Thread({
            val r = runCatching(work)
            activity.runOnUiThread { r.fold({ result.success(it) }, { result.error(code, null, null) }) }
        }, "swupd").start()
    }

    companion object {
        const val CHANNEL = "dev.batman/swupdate"
        const val PICK_REQ = 4202
    }
}
