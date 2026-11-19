// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

package com.singlinklabs.singlinkvpn

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The one Flutter engine of the process, shared by [MainActivity] and
 * [SingLinkVpnService]. The Dart side owns every VPN session (status poll,
 * revoke handling, protected credentials), so an always-on start by Android
 * (App F-04) runs the same Dart code without an Activity: the service starts
 * this engine if the app is not open, and the Activity reuses it later.
 */
object EngineHost {
    private const val ENGINE_ID = "main"
    private const val SECRETS_CHANNEL = "com.singlinklabs.singlinkvpn/secrets"

    fun obtain(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        return FlutterEngine(app).also {
            configure(it, app)
            cache.put(ENGINE_ID, it)
        }
    }

    /** Registers the app's channels on [engine]; safe to repeat. */
    fun configure(engine: FlutterEngine, app: Context) {
        val messenger = engine.dartExecutor.binaryMessenger
        VpnChannelHandler.appContext = app.applicationContext
        val vpn = MethodChannel(messenger, VpnBridge.CHANNEL)
        vpn.setMethodCallHandler(VpnChannelHandler)
        VpnBridge.channel = vpn
        val credentialStore = CredentialStore(app.applicationContext)
        MethodChannel(messenger, SECRETS_CHANNEL).setMethodCallHandler(credentialStore::handle)
    }

    /**
     * Runs Dart main() unless the engine already runs it. The Flutter
     * library is loaded off the main thread first, so a service started by
     * Android never blocks its main thread on engine start-up (a slow first
     * load would otherwise trip the service start timeout).
     */
    fun ensureRunningAsync(context: Context, onFailure: () -> Unit) {
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationCompleteAsync(app, null, main) {
                try {
                    val engine = obtain(app)
                    if (!engine.dartExecutor.isExecutingDart) {
                        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
                    }
                } catch (_: Exception) {
                    onFailure()
                }
            }
        } catch (_: Exception) {
            onFailure()
        }
    }
}

/**
 * Channel `com.singlinklabs.singlinkvpn/vpn` (see lib/platform/android.dart).
 * Works with or without an Activity: consent dialogs need [activity]; an
 * always-on start relies on the consent Android already has.
 */
object VpnChannelHandler : MethodChannel.MethodCallHandler {
    lateinit var appContext: Context

    /** The visible Activity, if any (set in onCreate, cleared in onDestroy). */
    var activity: MainActivity? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "filesDir" -> result.success(appContext.filesDir.absolutePath)
            "prepare" -> {
                // An always-on start never waits for a dialog in an Activity
                // that may be in the background; Android already consented.
                val systemStart = VpnBridge.service?.acceptsInPlaceConnect() == true
                val a = activity
                if (a != null && !systemStart) a.prepare(result) else result.success(preparedWithoutUi())
            }
            "establish" -> VpnBridge.establish(appContext, call.argument<Int>("mtu") ?: 1500, result)
            "stop" -> {
                activity?.cancelConsent()
                VpnBridge.stop()
                result.success(null)
            }
            "closeFd" -> { VpnBridge.release(call.argument<Int>("fd") ?: -1); result.success(null) }
            "takeSystemStart" -> result.success(VpnBridge.takeSystemStart())
            "systemStartFailed" -> { VpnBridge.systemStartFailed(); result.success(null) }
            "openVpnSettings" -> result.success(openVpnSettings())
            else -> result.notImplemented()
        }
    }

    /** Without UI no consent can be asked: true only if already granted. */
    private fun preparedWithoutUi(): Boolean = try {
        VpnService.prepare(appContext) == null
    } catch (_: Exception) {
        false
    }

    /** Android's VPN settings: Always-on VPN and "Block connections without VPN". */
    private fun openVpnSettings(): Boolean = try {
        val intent = Intent(Settings.ACTION_VPN_SETTINGS)
        val a = activity
        if (a != null) {
            a.startActivity(intent)
        } else {
            appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        true
    } catch (_: Exception) {
        false
    }
}
