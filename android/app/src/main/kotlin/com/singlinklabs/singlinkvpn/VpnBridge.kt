// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

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
    private var epoch: Long = 0
    fun isPending(generation: Long) = generation == epoch && pendingEstablish != null
    fun hasSession() = pendingEstablish != null || lastFd >= 0

    private val main = Handler(Looper.getMainLooper())

    fun awaitEstablish(result: MethodChannel.Result, mtu: Int): Long {
        epoch += 1
        pendingEstablish?.error("superseded", "a newer establish call replaced this one", null)
        pendingEstablish = result
        pendingMtu = mtu
        return epoch
    }

    fun establishDone(fd: Int, generation: Long) {
        if (!isPending(generation)) {
            try { ParcelFileDescriptor.adoptFd(fd).close() } catch (_: Exception) {}
            return
        }
        lastFd = fd
        unadopted.add(fd)
        pendingEstablish?.success(fd)
        pendingEstablish = null
    }

    /**
     * Descriptors handed to Dart that the core has not taken yet. Only these
     * are ever closed here, and each at most once: a descriptor owned by the
     * core is closed by SingLinkTunStop, never by this bridge.
     */
    private val unadopted = mutableSetOf<Int>()

    /** SingLinkTunStart succeeded: the core owns [fd] now. */
    fun adopted(fd: Int) {
        unadopted.remove(fd)
    }

    /** Closes [fd] if the core never took it (start failed or was cancelled). */
    fun closeUnadopted(fd: Int) {
        if (fd < 0 || !unadopted.remove(fd)) return
        if (lastFd == fd) lastFd = -1
        try {
            ParcelFileDescriptor.adoptFd(fd).close()
        } catch (_: Exception) {
        }
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
        epoch += 1
        if (closeFd) closeUnadopted(lastFd)
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
