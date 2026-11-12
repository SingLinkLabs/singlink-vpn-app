// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

package com.singlinklabs.singlinkvpn

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val ENGINE_ID = "main"
        private const val REQ_VPN = 0x5601
        private const val REQ_NOTIFY = 0x5602
    }

    /** `prepare` call waiting for the consent / permission dialogs. */
    private var pendingPrepare: MethodChannel.Result? = null

    /**
     * One engine per process, kept across Activity instances: the Dart side
     * owns the VPN session (status poll, revoke handling), so it must keep
     * running while the foreground service runs without a visible Activity.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        return cache.get(ENGINE_ID)
            ?: FlutterEngine(context.applicationContext).also { cache.put(ENGINE_ID, it) }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VpnBridge.CHANNEL)
        channel.setMethodCallHandler(::onMethodCall)
        VpnBridge.channel = channel
    }

    override fun onDestroy() {
        pendingPrepare?.success(false)
        pendingPrepare = null
        super.onDestroy()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "filesDir" -> result.success(filesDir.absolutePath)
            "prepare" -> prepare(result)
            "establish" -> establish(call.argument<Int>("mtu") ?: 1500, result)
            "stop" -> {
                VpnBridge.stop(call.argument<Boolean>("closeFd") ?: false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---- consent -----------------------------------------------------------

    private fun prepare(result: MethodChannel.Result) {
        pendingPrepare?.success(false)
        pendingPrepare = result
        // Android 13+: ask once for notifications so the "connected" notice is
        // visible; the VPN works either way.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED &&
            !getPreferences(MODE_PRIVATE).getBoolean("askedNotify", false)
        ) {
            getPreferences(MODE_PRIVATE).edit().putBoolean("askedNotify", true).apply()
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
            startActivityForResult(intent, REQ_VPN)
        } catch (e: Exception) {
            finishPrepare(false)
        }
    }

    private fun finishPrepare(granted: Boolean) {
        pendingPrepare?.success(granted)
        pendingPrepare = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFY && pendingPrepare != null) askVpnConsent()
    }

    @Deprecated("Activity result API; FlutterActivity still forwards it")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) finishPrepare(resultCode == RESULT_OK)
    }

    // ---- TUN ---------------------------------------------------------------

    private fun establish(mtu: Int, result: MethodChannel.Result) {
        VpnBridge.awaitEstablish(result, mtu)
        val intent = Intent(this, SingLinkVpnService::class.java)
            .setAction(SingLinkVpnService.ACTION_CONNECT)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Exception) {
            VpnBridge.establishFailed("service", e.message ?: e.toString())
        }
    }
}
