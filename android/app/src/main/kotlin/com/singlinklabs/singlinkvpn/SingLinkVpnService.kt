// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
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

/**
 * Foreground VpnService that owns the device-wide VPN session "SingLinkVPN".
 *
 * It only builds the TUN interface; the descriptor is detached and handed to
 * the Go core (SingLinkTunStart, called from Dart), which relays every packet
 * through the SingLink node and closes the descriptor when it stops.
 */
class SingLinkVpnService : VpnService() {

    companion object {
        const val ACTION_CONNECT = "com.singlinklabs.singlinkvpn.CONNECT"
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
        if (VpnBridge.service === this) VpnBridge.service = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_CONNECT) {
            // Started by the system (for example always-on VPN) without the
            // app: there is no session to resume, so do not stay around.
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            goForeground()
        } catch (e: Exception) {
            VpnBridge.establishFailed("foreground", e.message ?: e.toString())
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val fd = establishTun(VpnBridge.pendingMtu)
            VpnBridge.establishDone(fd)
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
        // Ownership moves to the core (it reads the descriptor through Go's
        // poller and closes it in SingLinkTunStop).
        return pfd.detachFd()
    }

    /** Stops the foreground service; the core already closed the TUN. */
    fun shutdown() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        // Another VPN took over, or the user disconnected in system settings.
        VpnBridge.revoked()
        shutdown()
    }

    private fun goForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "VPN status",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while SingLinkVPN is connected"
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
            .setContentTitle("SingLinkVPN is connected")
            .setContentText("All traffic is going through SingLinkVPN")
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
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
