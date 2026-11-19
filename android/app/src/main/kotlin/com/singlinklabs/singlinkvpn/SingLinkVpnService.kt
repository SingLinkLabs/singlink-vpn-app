// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

package com.singlinklabs.singlinkvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Foreground VpnService that owns the device-wide VPN session "SingLinkVPN".
 *
 * It only builds the TUN interface; the descriptor is detached and handed to
 * Dart, which passes it to the Go core (SingLinkTunStart). The core relays
 * every packet through the SingLink node on its own duplicate of the
 * descriptor; [VpnBridge] closes the original once that call has returned.
 *
 * Always-on VPN (App F-04): Android starts this service itself, without the
 * app's CONNECT intent, when the user picked SingLinkVPN as the always-on VPN
 * (also after boot). The service then goes foreground, starts the Dart side
 * through [EngineHost] if needed and lets it connect the saved profile; the
 * TUN is established in place. With "Block connections without VPN" Android
 * blocks all traffic whenever no session is up: that is the kill switch.
 */
class SingLinkVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT = "com.singlinklabs.singlinkvpn.CONNECT"

        /** How long an always-on start may take before the service gives up. */
        const val SYSTEM_START_TIMEOUT_MS = 90_000L
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL = "vpn_status"
        private const val SESSION = "SingLinkVPN"

        // Private addresses for the TUN interface. The core answers DNS on
        // any UDP/53 address, so DNS_SERVER only has to be inside the tunnel.
        private const val ADDRESS_V4 = "172.19.0.1"
        private const val PREFIX_V4 = 30
        private const val DNS_SERVER = "172.19.0.2"
        private const val ADDRESS_V6 = "fdfe:dcba:9876::1"
        private const val PREFIX_V6 = 126
    }

    override fun onCreate() {
        super.onCreate()
        VpnBridge.service = this
    }

    override fun onDestroy() {
        handler.removeCallbacks(systemStartTimeout)
        if (VpnBridge.service === this) VpnBridge.service = null
        super.onDestroy()
    }

    private val handler by lazy { Handler(Looper.getMainLooper()) }

    /** An always-on start is waiting for Dart to connect the saved profile. */
    private var systemStartActive = false
    private var stopping = false

    private val systemStartTimeout = Runnable {
        if (systemStartActive) VpnBridge.systemStartFailed()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val kind = StartKind.classify(intent?.action, VpnBridge.hasSession() || systemStartActive)
        return when (kind) {
            StartKind.CONNECT -> connectIntent(intent!!, startId)
            StartKind.SYSTEM -> { systemStart(); START_NOT_STICKY }
            // A session (or an always-on start) is already running: keep it.
            StartKind.ALREADY_RUNNING -> START_NOT_STICKY
            StartKind.UNKNOWN -> { stopSelf(startId); START_NOT_STICKY }
        }
    }

    /**
     * Always-on start without the app: show the foreground notification at
     * once, then let the Dart side connect the saved profile. If it cannot
     * (no saved server, locked storage, warnings to review) or does not
     * answer within [SYSTEM_START_TIMEOUT_MS], the service stops; with
     * "Block connections without VPN" Android keeps traffic blocked.
     */
    private fun systemStart() {
        try {
            goForeground(connecting = true)
        } catch (_: Exception) {
            stopSelf()
            return
        }
        stopping = false
        systemStartActive = true
        handler.removeCallbacks(systemStartTimeout)
        handler.postDelayed(systemStartTimeout, SYSTEM_START_TIMEOUT_MS)
        VpnBridge.requestSystemStart()
        EngineHost.ensureRunningAsync(applicationContext) { VpnBridge.systemStartFailed() }
    }

    /** True while an always-on start waits for Dart's `establish`. */
    fun acceptsInPlaceConnect() = systemStartActive && foregrounded && !stopping

    /** Establishes the TUN for Dart's pending `establish` [generation]. */
    fun connectSession(generation: Long) {
        if (!VpnBridge.isPending(generation)) return
        try {
            goForeground()
        } catch (e: Exception) {
            VpnBridge.establishFailed("foreground", e.message ?: e.toString())
            return
        }
        try {
            val fd = establishTun(VpnBridge.pendingMtu)
            systemStartActive = false
            handler.removeCallbacks(systemStartTimeout)
            VpnBridge.establishDone(fd, generation)
        } catch (e: Exception) {
            VpnBridge.establishFailed("establish", e.message ?: e.toString())
            shutdown()
        }
    }

    private fun connectIntent(intent: Intent, startId: Int): Int {
        stopping = false
        val generation = intent.getLongExtra("generation", -1)
        // Started with startForegroundService: Android requires startForeground
        // even for a start that is already obsolete, or it kills the app.
        val foreground = try { goForeground(); null } catch (e: Exception) { e }
        if (!VpnBridge.isPending(generation)) {
            if (!VpnBridge.hasSession()) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        if (foreground != null) {
            val e = foreground
            VpnBridge.establishFailed("foreground", e.message ?: e.toString())
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val fd = establishTun(VpnBridge.pendingMtu)
            VpnBridge.establishDone(fd, generation)
        } catch (e: Exception) {
            VpnBridge.establishFailed("establish", e.message ?: e.toString())
            shutdown()
        }
        return START_NOT_STICKY
    }

    /** Builds the interface and returns its detached descriptor. */
    private fun establishTun(mtu: Int): Int {
        val builder = Builder()
            .setSession(SESSION)
            .setMtu(mtu)
            .addAddress(ADDRESS_V4, PREFIX_V4)
            .addAddress(ADDRESS_V6, PREFIX_V6)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .addDnsServer(DNS_SERVER)
            // The core's own sockets (to the node) must not loop back into
            // the tunnel.
            .addDisallowedApplication(packageName)
            .setConfigureIntent(openAppIntent())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
        val pfd = builder.establish()
            ?: throw IllegalStateException("VPN permission was not granted")
        // The raw descriptor now belongs to VpnBridge, which closes it exactly
        // once (the core only ever closes its own duplicate).
        return pfd.detachFd()
    }

    private var foregrounded = false

    /** Stops the foreground service; the core closes its TUN duplicate. */
    fun shutdown() {
        // A stop can land between onCreate and onStartCommand. Satisfy the
        // startForegroundService contract before stopping, or Android crashes
        // the app with ForegroundServiceDidNotStartInTimeException.
        if (!foregrounded) try { goForeground() } catch (_: Exception) {}
        stopping = true
        systemStartActive = false
        handler.removeCallbacks(systemStartTimeout)
        stopForeground(STOP_FOREGROUND_REMOVE)
        foregrounded = false
        stopSelf()
    }

    override fun onRevoke() {
        // Another VPN took over, or the user disconnected in system settings.
        // onRevoke arrives on a binder thread; the bridge and the service
        // state are only touched on the main thread.
        Handler(Looper.getMainLooper()).post {
            VpnBridge.revoked()
            shutdown()
        }
    }

    /**
     * Notification text (App F-04): says what the app does while connected,
     * without claiming leak-proof protection.
     */
    private fun goForeground(connecting: Boolean = false) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "VPN status",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while SingLinkVPN is connected or connecting"
                    setShowBadge(false)
                },
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentTitle(if (connecting) NotificationText.CONNECTING_TITLE else NotificationText.CONNECTED_TITLE)
            .setContentText(if (connecting) NotificationText.CONNECTING_TEXT else NotificationText.CONNECTED_TEXT)
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        foregrounded = true
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

/** How onStartCommand treats a start request. */
enum class StartKind {
    /** The app's own start (Dart `establish`). */
    CONNECT,

    /** Android started the VPN without the app: always-on VPN. */
    SYSTEM,

    /** A session or an always-on start already runs; nothing to do. */
    ALREADY_RUNNING,

    /** Anything else without a session: stop. */
    UNKNOWN;

    companion object {
        fun classify(action: String?, hasSession: Boolean): StartKind = when {
            action == SingLinkVpnService.ACTION_CONNECT -> CONNECT
            hasSession -> ALREADY_RUNNING
            action == VpnService.SERVICE_INTERFACE -> SYSTEM
            else -> UNKNOWN
        }
    }
}

/** Notification wording (App F-04), shared with the unit tests. */
object NotificationText {
    const val CONNECTED_TITLE = "SingLinkVPN is connected"
    const val CONNECTED_TEXT = "Device traffic goes through SingLinkVPN while connected"
    const val CONNECTING_TITLE = "SingLinkVPN is connecting"
    const val CONNECTING_TEXT = "Started by the Always-on VPN setting"
}
