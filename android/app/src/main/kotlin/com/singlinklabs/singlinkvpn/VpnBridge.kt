// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
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

    /** True while a TUN descriptor handed to Dart belongs to this session. */
    private var handedOut = false
    private var epoch: Long = 0
    fun isPending(generation: Long) = generation == epoch && pendingEstablish != null
    fun hasSession() = pendingEstablish != null || handedOut

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
        handedOut = true
        heldFds.add(fd)
        pendingEstablish?.success(fd)
        pendingEstablish = null
    }

    /**
     * Descriptors handed to Dart and not closed yet. The bridge always owns
     * them: SingLinkTunStart works on its own duplicate and never closes
     * these, whatever its result. Dart releases each one exactly once, after
     * the core call returned (or when the start was abandoned before it), so
     * this is the only place they are closed, and only once.
     */
    private val heldFds = mutableSetOf<Int>()

    /** Closes [fd] if this bridge handed it out and has not closed it yet. */
    fun release(fd: Int) {
        if (fd < 0 || !heldFds.remove(fd)) return
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
     * Stops the service. It never closes a descriptor: one Dart still holds
     * may be on its way into SingLinkTunStart (closing it now could let the
     * number be reused before the core duplicates it); Dart releases it once
     * that call has returned.
     */
    fun stop() {
        epoch += 1
        handedOut = false
        establishFailed("stopped", "VPN stopped")
        service?.shutdown()
    }

    /** onRevoke: the core still holds its duplicate; Dart stops it. */
    fun revoked() {
        handedOut = false
        main.post { channel?.invokeMethod("revoked", null) }
    }
}
