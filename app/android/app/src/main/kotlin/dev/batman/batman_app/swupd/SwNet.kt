package dev.batman.batman_app.swupd

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.HandlerThread
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 254-app-update v0.4 D5: which Network the PUT goes out on.
 * - [findDirect]: the phone's current Wi-Fi, when one of its routes covers the node IP directly (on-link: not the
 *   default route, no gateway). Seen through registerNetworkCallback (not the deprecated getAllNetworks); no SSID read,
 *   no location permission, no bindProcessToNetwork.
 * - [join]: the fallback, a WifiNetworkSpecifier (WPA2, F27) without the INTERNET capability, `requestNetwork(…, 60 s)`;
 *   the request is kept for the whole upload stage (no re-request between retries) until [release]. Its onLost calls
 *   [onLost] (the caller aborts the running PUT). The passphrase is used only to build the specifier; never stored here.
 * Blocking calls: never on the UI thread. Callbacks run on this object's own HandlerThread.
 */
class SwNet(context: Context, private val onLost: (Network) -> Unit) {
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val thread = HandlerThread("swupd-net").apply { start() }
    private val handler = Handler(thread.looper)
    private val lock = Any()
    private var specifier: ConnectivityManager.NetworkCallback? = null
    private var joined: Network? = null
    private var joinedSsid: String? = null
    @Volatile private var waiting: CountDownLatch? = null

    /**
     * The Specifier network this upload stage holds (code review r1 A-M2 / B-M1): the next PUT of the stage goes out on
     * it again — no new request (each would cut the phone's Wi-Fi, and TAK, twice). Null when none is held.
     */
    fun held(): Network? = synchronized(lock) { joined }

    private fun wifi(): NetworkRequest.Builder = NetworkRequest.Builder()
        .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) // the node's AP has no internet

    /** D5 primary: the Wi-Fi network with a direct route to [ip], or null. Existing networks are reported at once. */
    fun findDirect(ip: InetAddress, waitMs: Long = FIND_WAIT_MS): Network? {
        var hit: Network? = null
        val done = CountDownLatch(1)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(n: Network, lp: LinkProperties) {
                if (hit == null && directRoute(lp, ip)) { hit = n; done.countDown() }
            }
        }
        cm.registerNetworkCallback(wifi().build(), cb, handler)
        try {
            done.await(waitMs, TimeUnit.MILLISECONDS)
        } finally {
            cm.unregisterNetworkCallback(cb)
        }
        return hit
    }

    /**
     * D5 fallback: "ok" + the Network, or "no_network" + null. Android reports a refused dialog and the 60 s timeout the
     * same way (onUnavailable): they are not told apart (code review r1 B-m5; the app shows one text for both).
     * A network this stage already holds for the same ssid is returned as is (r1 A-M2: never released and requested
     * again within the stage). A [release] meanwhile (a cancel) ends the wait at once (r1 B-m3).
     */
    fun join(ssid: String, pass: String): Pair<String, Network?> {
        synchronized(lock) { joined?.let { if (joinedSsid == ssid) return "ok" to it } }
        release()
        val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).setWpa2Passphrase(pass).build()
        val req = wifi().setNetworkSpecifier(spec).build()
        var answer = "no_network"
        var got: Network? = null
        val done = CountDownLatch(1)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(n: Network) {
                synchronized(lock) { if (specifier === this) { joined = n; joinedSsid = ssid } }
                if (done.count > 0) { answer = "ok"; got = n; done.countDown() }
            }
            override fun onUnavailable() {
                done.countDown()
            }
            override fun onLost(n: Network) {
                val mine = synchronized(lock) { (specifier === this && joined == n).also { if (it) joined = null } }
                if (mine) onLost(n)
            }
        }
        synchronized(lock) { specifier = cb }
        waiting = done
        cm.requestNetwork(req, cb, handler, JOIN_TIMEOUT_MS.toInt())
        if (!done.await(JOIN_TIMEOUT_MS + 5_000, TimeUnit.MILLISECONDS) || answer != "ok") {
            release()
            return "no_network" to null
        }
        waiting = null
        if (synchronized(lock) { specifier !== cb }) return "no_network" to null // released (cancelled) meanwhile
        return answer to got
    }

    /** Ends the Specifier request (U8 / cancel / 3 failures; D5). Harmless when there is none. */
    fun release() {
        val cb = synchronized(lock) { specifier.also { specifier = null; joined = null; joinedSsid = null } }
        waiting?.countDown() // a join waiting for the dialog ends now (r1 B-m3), not after 65 s
        if (cb != null) try { cm.unregisterNetworkCallback(cb) } catch (_: IllegalArgumentException) {} // already gone
    }

    fun dispose() {
        release()
        thread.quitSafely()
    }

    companion object {
        const val FIND_WAIT_MS = 1_000L
        const val JOIN_TIMEOUT_MS = 60_000L

        /** D5: a route covering [ip] directly (on-link): not the default route and without a gateway. */
        fun directRoute(lp: LinkProperties, ip: InetAddress) =
            lp.routes.any { it.matches(ip) && !it.isDefaultRoute && !it.hasGateway() }
    }
}
