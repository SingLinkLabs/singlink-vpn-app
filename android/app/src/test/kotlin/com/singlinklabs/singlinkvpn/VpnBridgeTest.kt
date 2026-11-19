// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

package com.singlinklabs.singlinkvpn

import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * App F-02 (VPN Labs): the Kotlin side of the TUN descriptor contract. The
 * bridge owns the descriptor it detached from the VpnService; SingLinkTunStart
 * only ever closes its own duplicate. So the bridge must close its original
 * exactly once on success, on failure and around stop, and never while Dart
 * may still be passing it to the core.
 *
 * Runs on the JVM: the descriptor close and main-thread posting are replaced
 * by recording hooks, so every close is counted.
 */
class VpnBridgeTest {
    private val closed = mutableListOf<Int>()

    private class RecordingResult : MethodChannel.Result {
        val successes = mutableListOf<Any?>()
        val errors = mutableListOf<String>()
        override fun success(result: Any?) { successes.add(result) }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { errors.add(errorCode) }
        override fun notImplemented() { errors.add("notImplemented") }
    }

    @Before
    fun setUp() {
        VpnBridge.resetForTest()
        closed.clear()
        VpnBridge.closeFd = { closed.add(it) }
        VpnBridge.post = { it() }
    }

    /** establish → the service hands fd over → Dart receives it. */
    private fun handOut(fd: Int): RecordingResult {
        val result = RecordingResult()
        val generation = VpnBridge.awaitEstablish(result, 1500)
        assertTrue(VpnBridge.isPending(generation))
        VpnBridge.establishDone(fd, generation)
        assertEquals(listOf<Any?>(fd), result.successes)
        assertTrue(VpnBridge.hasSession())
        return result
    }

    @Test
    fun successfulStartClosesTheOriginalExactlyOnce() {
        handOut(41)
        assertEquals("nothing closed while Dart passes it to the core", emptyList<Int>(), closed)
        VpnBridge.release(41) // after SingLinkTunStart returned ok
        assertEquals(listOf(41), closed)
        VpnBridge.release(41)
        VpnBridge.release(41)
        assertEquals("never closed twice", listOf(41), closed)
    }

    @Test
    fun failedStartClosesTheOriginalExactlyOnce() {
        handOut(42)
        VpnBridge.release(42) // after SingLinkTunStart returned an error
        VpnBridge.stop() // Dart stops the service after the failure
        VpnBridge.release(42)
        assertEquals(listOf(42), closed)
        assertFalse(VpnBridge.hasSession())
    }

    @Test
    fun stopNeverClosesAHandedOutDescriptor() {
        handOut(43)
        VpnBridge.stop() // may arrive while SingLinkTunStart is still running
        assertEquals("stop must not close it", emptyList<Int>(), closed)
        VpnBridge.release(43) // once the core call returned
        assertEquals(listOf(43), closed)
        VpnBridge.stop()
        VpnBridge.release(43)
        assertEquals(listOf(43), closed)
    }

    @Test
    fun revokeNeverClosesTheDescriptor() {
        handOut(44)
        VpnBridge.revoked()
        assertEquals(emptyList<Int>(), closed)
        VpnBridge.release(44)
        assertEquals(listOf(44), closed)
    }

    @Test
    fun descriptorForAStoppedStartIsClosedByTheBridgeOnly() {
        val result = RecordingResult()
        val generation = VpnBridge.awaitEstablish(result, 1500)
        VpnBridge.stop() // before the service established the TUN
        assertEquals(listOf("stopped"), result.errors)
        VpnBridge.establishDone(45, generation) // the service finishes late
        assertEquals("closed once by the bridge", listOf(45), closed)
        assertTrue("never handed to Dart", result.successes.isEmpty())
        VpnBridge.release(45) // a confused caller cannot close it again
        assertEquals(listOf(45), closed)
    }

    @Test
    fun supersededEstablishIsRejectedAndItsDescriptorClosedOnce() {
        val first = RecordingResult()
        val oldGeneration = VpnBridge.awaitEstablish(first, 1500)
        val second = RecordingResult()
        val generation = VpnBridge.awaitEstablish(second, 1400)
        assertEquals(listOf("superseded"), first.errors)
        VpnBridge.establishDone(46, oldGeneration)
        assertEquals(listOf(46), closed)
        VpnBridge.establishDone(47, generation)
        assertEquals(listOf<Any?>(47), second.successes)
        VpnBridge.release(47)
        assertEquals(listOf(46, 47), closed)
    }

    @Test
    fun releaseIgnoresDescriptorsItNeverHandedOut() {
        VpnBridge.release(-1)
        VpnBridge.release(0)
        VpnBridge.release(99)
        assertEquals(emptyList<Int>(), closed)
    }

    @Test
    fun aFailingCloseIsNotRetried() {
        var attempts = 0
        VpnBridge.closeFd = { attempts++; throw IllegalStateException("EBADF") }
        handOut(48)
        VpnBridge.release(48)
        VpnBridge.release(48)
        assertEquals(1, attempts)
    }

    // ---- always-on (App F-04) ---------------------------------------------

    @Test
    fun alwaysOnStartIsTakenExactlyOnce() {
        assertFalse(VpnBridge.takeSystemStart())
        VpnBridge.requestSystemStart()
        assertTrue(VpnBridge.takeSystemStart())
        assertFalse(VpnBridge.takeSystemStart())
    }

    @Test
    fun stopAndFailureDropAPendingAlwaysOnStart() {
        VpnBridge.requestSystemStart()
        VpnBridge.stop()
        assertFalse(VpnBridge.takeSystemStart())
        VpnBridge.requestSystemStart()
        VpnBridge.systemStartFailed()
        assertFalse(VpnBridge.takeSystemStart())
    }

    @Test
    fun startKindsAreClassified() {
        val connect = SingLinkVpnService.ACTION_CONNECT
        val system = android.net.VpnService.SERVICE_INTERFACE
        assertEquals("android.net.VpnService", system)
        assertEquals(StartKind.CONNECT, StartKind.classify(connect, false))
        assertEquals(StartKind.CONNECT, StartKind.classify(connect, true))
        assertEquals(StartKind.SYSTEM, StartKind.classify(system, false))
        assertEquals(
            "always-on start while connected keeps the session",
            StartKind.ALREADY_RUNNING,
            StartKind.classify(system, true),
        )
        assertEquals(StartKind.UNKNOWN, StartKind.classify(null, false))
        assertEquals(StartKind.ALREADY_RUNNING, StartKind.classify(null, true))
        assertEquals(StartKind.UNKNOWN, StartKind.classify("other", false))
    }

    @Test
    fun notificationWordingMakesNoLeakProofClaim() {
        for (text in listOf(NotificationText.CONNECTED_TEXT, NotificationText.CONNECTING_TEXT)) {
            assertFalse(text, text.contains("All traffic"))
            assertFalse(text, text.contains("protected", ignoreCase = true))
        }
        assertTrue(NotificationText.CONNECTED_TEXT.contains("while connected"))
        assertTrue(NotificationText.CONNECTED_TEXT.contains("SingLinkVPN"))
    }
}
