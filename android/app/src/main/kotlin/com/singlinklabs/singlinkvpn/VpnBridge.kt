// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

package com.singlinklabs.singlinkvpn

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodChannel

/**
 * Process-wide glue between the Flutter channel ([VpnChannelHandler]) and the
 * running [SingLinkVpnService]. Everything here runs on the main thread.
 *
 * The platform hooks [closeFd] and [post] are the only Android calls on the
 * descriptor and threading paths; JVM unit tests (VpnBridgeTest) replace them
 * to check that every descriptor is closed exactly once.
 */
object VpnBridge {
    const val CHANNEL = "com.singlinklabs.singlinkvpn/vpn"

    /** Channel of the (cached, long-lived) Flutter engine. */
    var channel: MethodChannel? = null

    /** The running service, set in onCreate / cleared in onDestroy. */
    var service: SingLinkVpnService? = null

    /** Closes a raw descriptor this bridge owns. */
    internal var closeFd: (Int) -> Unit = { fd -> ParcelFileDescriptor.adoptFd(fd).close() }

    /** Runs [block] on the main thread later. */
    internal var post: (() -> Unit) -> Unit = { block -> mainHandler.post(block) }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    /** `establish` call waiting for the service to come up. */
    private var pendingEstablish: MethodChannel.Result? = null
    var pendingMtu: Int = 1500
        private set

    /** True while a TUN descriptor handed to Dart belongs to this session. */
    private var handedOut = false
    private var epoch: Long = 0
    fun isPending(generation: Long) = generation == epoch && pendingEstablish != null
    fun hasSession() = pendingEstablish != null || handedOut

    fun awaitEstablish(result: MethodChannel.Result, mtu: Int): Long {
        epoch += 1
        pendingEstablish?.error("superseded", "a newer establish call replaced this one", null)
        pendingEstablish = result
        pendingMtu = mtu
        return epoch
    }

    /**
     * Dart's `establish`: brings the TUN up in the service. A service that
     * Android started for always-on VPN is already in the foreground and
     * establishes in place; otherwise the service is started for it.
     */
    fun establish(context: Context, mtu: Int, result: MethodChannel.Result) {
        val generation = awaitEstablish(result, mtu)
        val running = service
        if (running != null && running.acceptsInPlaceConnect()) {
            running.connectSession(generation)
            return
        }
        val intent = Intent(context, SingLinkVpnService::class.java)
            .setAction(SingLinkVpnService.ACTION_CONNECT)
            .putExtra("generation", generation)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            establishFailed("service", e.message ?: e.toString())
        }
    }

    fun establishDone(fd: Int, generation: Long) {
        if (!isPending(generation)) {
            // Nobody will ever receive this descriptor: it is the bridge's
            // own, never handed out, so it is closed here exactly once.
            closeQuietly(fd)
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
        closeQuietly(fd)
    }

    private fun closeQuietly(fd: Int) {
        try {
            closeFd(fd)
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
        systemStartPending = false
        establishFailed("stopped", "VPN stopped")
        service?.shutdown()
    }

    /** onRevoke: the core still holds its duplicate; Dart stops it. */
    fun revoked() {
        handedOut = false
        post { channel?.invokeMethod("revoked", null) }
    }

    // ---- always-on VPN (App F-04) ------------------------------------------

    /** Android started the service for always-on VPN; Dart has not taken it yet. */
    private var systemStartPending = false

    /**
     * Records an always-on start and tells a running Dart side. A Dart side
     * that starts later pulls it with [takeSystemStart] once it has loaded.
     */
    fun requestSystemStart() {
        systemStartPending = true
        post { channel?.invokeMethod("systemStart", null) }
    }

    /** True once per always-on start request. */
    fun takeSystemStart(): Boolean {
        val pending = systemStartPending
        systemStartPending = false
        return pending
    }

    /**
     * Dart could not connect for an always-on start (no saved server, locked
     * storage, warnings to review) or did not answer in time: take the
     * placeholder service down unless a session is being set up.
     */
    fun systemStartFailed() {
        systemStartPending = false
        if (!hasSession()) service?.shutdown()
    }

    /** JVM unit tests only: back to the initial state. */
    internal fun resetForTest() {
        channel = null
        service = null
        pendingEstablish = null
        pendingMtu = 1500
        handedOut = false
        epoch = 0
        heldFds.clear()
        systemStartPending = false
    }
}
