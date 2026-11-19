// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

package com.singlinklabs.singlinkvpn

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val REQ_NOTIFY = 0x5602
    }

    /** `prepare` call waiting for the consent / permission dialogs. */
    private var pendingPrepare: MethodChannel.Result? = null
    private var requestSequence = 0
    private var currentVpnRequest: Int? = null
    private var waitingNotification = false

    /**
     * One engine per process, kept across Activity instances and shared with
     * an always-on start of [SingLinkVpnService] ([EngineHost]): the Dart side
     * owns the VPN session, so it keeps running without a visible Activity.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine = EngineHost.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        VpnChannelHandler.activity = this
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EngineHost.configure(flutterEngine, applicationContext)
        VpnChannelHandler.activity = this
    }

    override fun onDestroy() {
        pendingPrepare?.success(false)
        pendingPrepare = null
        if (VpnChannelHandler.activity === this) VpnChannelHandler.activity = null
        super.onDestroy()
    }

    /** `stop` from Dart: abandon a consent dialog that is still open. */
    fun cancelConsent() {
        pendingPrepare?.success(false); pendingPrepare = null
        currentVpnRequest = null; waitingNotification = false
    }

    // ---- consent -----------------------------------------------------------

    fun prepare(result: MethodChannel.Result) {
        pendingPrepare?.success(false)
        pendingPrepare = result
        currentVpnRequest = null
        waitingNotification = false
        // Android 13+: ask once for notifications so the "connected" notice is
        // visible; the VPN works either way.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED &&
            !getPreferences(MODE_PRIVATE).getBoolean("askedNotify", false)
        ) {
            getPreferences(MODE_PRIVATE).edit().putBoolean("askedNotify", true).apply()
            waitingNotification = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
            return
        }
        askVpnConsent()
    }

    private fun askVpnConsent() {
        val intent = try {
            VpnService.prepare(this)
        } catch (e: Exception) {
            finishPrepare(false)
            return
        }
        if (intent == null) {
            finishPrepare(true) // already allowed
            return
        }
        try {
            requestSequence = (requestSequence + 1) and 0x1fff
            val request = 0x6000 + requestSequence
            currentVpnRequest = request
            startActivityForResult(intent, request)
        } catch (e: Exception) {
            finishPrepare(false)
        }
    }

    private fun finishPrepare(granted: Boolean) {
        pendingPrepare?.success(granted)
        pendingPrepare = null
        currentVpnRequest = null; waitingNotification = false
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFY && pendingPrepare != null && waitingNotification) {
            waitingNotification = false; askVpnConsent()
        }
    }

    @Deprecated("Activity result API; FlutterActivity still forwards it")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == currentVpnRequest) finishPrepare(resultCode == RESULT_OK)
    }
}
