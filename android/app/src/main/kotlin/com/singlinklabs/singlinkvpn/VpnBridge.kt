package com.singlinklabs.singlinkvpn

import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodChannel

/**
 * Process-wide glue between the Flutter channel (MainActivity) and the
 * running [SingLinkVpnService]. Everything here runs on the main thread.
 */
object VpnBridge {
    const val CHANNEL = "com.singlinklabs.singlinkvpn/vpn"

    /** Channel of the (cached, long-lived) Flutter engine. */
    var channel: MethodChannel? = null

    /** The running service, set in onCreate / cleared in onDestroy. */
    var service: SingLinkVpnService? = null

    /** `establish` call waiting for the service to come up. */
    private var pendingEstablish: MethodChannel.Result? = null
    var pendingMtu: Int = 1500
        private set

    /** Last TUN descriptor handed to Dart (owned by the core once started). */
    private var lastFd: Int = -1

    private val main = Handler(Looper.getMainLooper())

    fun awaitEstablish(result: MethodChannel.Result, mtu: Int) {
        pendingEstablish?.error("superseded", "a newer establish call replaced this one", null)
        pendingEstablish = result
        pendingMtu = mtu
    }

    fun establishDone(fd: Int) {
        lastFd = fd
        pendingEstablish?.success(fd)
        pendingEstablish = null
    }

    fun establishFailed(code: String, message: String) {
        pendingEstablish?.error(code, message, null)
        pendingEstablish = null
    }

    /**
     * Stops the service. With [closeFd] the core never took the descriptor
     * (SingLinkTunStart failed), so it is closed here, which removes the VPN
     * interface.
     */
    fun stop(closeFd: Boolean) {
        if (closeFd && lastFd >= 0) {
            try {
                ParcelFileDescriptor.adoptFd(lastFd).close()
            } catch (_: Exception) {
            }
        }
        lastFd = -1
        establishFailed("stopped", "VPN stopped")
        service?.shutdown()
    }

    /** onRevoke: the core still holds the descriptor; Dart stops it. */
    fun revoked() {
        lastFd = -1
        main.post { channel?.invokeMethod("revoked", null) }
    }
}
