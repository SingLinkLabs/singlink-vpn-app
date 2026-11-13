// Copyright 2026 SingLinkLabs
// SPDX-License-Identifier: Apache-2.0
package com.singlinklabs.singlinkvpn

import android.content.pm.ApplicationInfo
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CredentialStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val store = CredentialStore(context)
    private val references = mutableListOf<String>()
    private fun reference(): String {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        return ("slk_v1_" + Base64.encodeToString(bytes,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)).also { references.add(it) }
    }
    private fun file(ref: String) = File(context.noBackupFilesDir, "credential-v1/$ref.bin")
    private fun payload(marker: String) = "{\"version\":1,\"link\":\"singlink://SYNTHETIC-$marker@node.invalid\",\"acknowledgedWarnings\":[]}"
    private fun fails(block: () -> Unit) {
        var rejected = false
        try { block() } catch (_: Exception) { rejected = true }
        assertTrue("Expected protected operation to reject invalid input", rejected)
    }
    @After fun cleanup() { references.forEach { store.delete(it) } }
    @Test fun nativeRoundTripUsesCiphertextAndDeviceHeldKey() {
        val ref = reference(); val plain = payload("fresh-fixture")
        store.write(ref, plain)
        assertEquals(plain, CredentialStore(context).read(ref))
        assertFalse(file(ref).readBytes().toString(Charsets.UTF_8).contains(plain))
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertNull(ks.getKey("com.singlinklabs.singlinkvpn.credentials.aes.v1", null).encoded)
        store.delete(ref); assertNull(store.read(ref))
    }
    @Test fun corruptedCiphertextFailsClosed() {
        val ref = reference(); store.write(ref, payload("integrity"))
        val data = file(ref).readBytes(); data[data.lastIndex] = (data.last().toInt() xor 1).toByte()
        file(ref).writeBytes(data); fails { store.read(ref) }
    }
    @Test fun ciphertextCannotMoveToDifferentReference() {
        val a = reference(); val b = reference()
        store.write(a, payload("first")); store.write(b, payload("second"))
        file(b).writeBytes(file(a).readBytes()); fails { store.read(b) }
    }
    @Test fun referencesAreImmutableAndInvalidPathsRejected() {
        val ref = reference(); val plain = payload("immutable")
        store.write(ref, plain); store.write(ref, plain)
        fails { store.write(ref, payload("replacement")) }
        assertEquals(plain, store.read(ref))
        fails { store.read("../not-a-reference") }
    }
    @Test fun backupOnlyRecoveryCannotOverwriteImmutableReference() {
        val ref = reference(); val plain = payload("backup-recovery")
        store.write(ref, plain)
        assertTrue(file(ref).renameTo(File(file(ref).path + ".bak")))
        fails { store.write(ref, payload("replacement")) }
        assertEquals(plain, store.read(ref))
    }
    @Test fun deletionFailureMustRemainRetryable() {
        val ref = reference(); val owned = file(ref)
        assertTrue(owned.mkdirs())
        File(owned, "synthetic-child").writeText("synthetic")
        try { fails { store.delete(ref) } }
        finally { assertTrue(owned.deleteRecursively()) }
        store.delete(ref) // A later retry can complete.
    }
    @Test fun ordinaryBackupIsExplicitlyDisabled() {
        assertEquals(0, context.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP)
        assertTrue(context.noBackupFilesDir.exists())
    }
}
