// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0
package com.singlinklabs.singlinkvpn

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-held wrapping key; files contain authenticated ciphertext only. */
class CredentialStore(private val context: Context) {
    private val keyAlias = "com.singlinklabs.singlinkvpn.credentials.aes.v1"
    private val reference = Regex("^slk_v1_[A-Za-z0-9_-]{43}$")
    private fun file(ref: String): AtomicFile {
        require(reference.matches(ref))
        val dir = File(context.noBackupFilesDir, "credential-v1")
        check(dir.exists() || dir.mkdirs())
        return AtomicFile(File(dir, "$ref.bin"))
    }
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(keyAlias)) return store.getKey(keyAlias, null) as SecretKey
        check(create) { "missing key" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }
    @Synchronized fun read(ref: String): String? {
        val file = file(ref)
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val data = file.readFully()
        require(data.size in 30..66000 && data[0] == 1.toByte() && data[1] == 12.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, data.copyOfRange(2, 14)))
        cipher.updateAAD(ref.toByteArray(Charsets.UTF_8))
        val plain = cipher.doFinal(data.copyOfRange(14, data.size))
        return plain.toString(Charsets.UTF_8).also { require(it.isNotEmpty()) }
    }
    @Synchronized fun write(ref: String, value: String) {
        require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 65536)
        val file = file(ref)
        val existing = read(ref) // AtomicFile also recovers a backup-only write.
        if (existing != null) { check(existing == value); return }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true)) // OS generates a fresh IV.
        require(cipher.iv.size == 12)
        cipher.updateAAD(ref.toByteArray(Charsets.UTF_8))
        val blob = byteArrayOf(1, 12) + cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        var stream: java.io.FileOutputStream? = null
        try { stream = file.startWrite(); stream.write(blob); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw e }
    }
    @Synchronized fun delete(ref: String) {
        val owned = file(ref)
        owned.delete()
        // AtomicFile.delete returns void even when a filesystem deletion fails.
        // Do not acknowledge cleanup until every file for this reference is gone.
        check(listOf(owned.baseFile, File(owned.baseFile.path + ".bak"),
            File(owned.baseFile.path + ".new")).none { it.exists() })
    }
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ref = call.argument<String>("reference")
        if (ref == null || !reference.matches(ref)) {
            result.error("invalid-reference", "Invalid credential reference", null); return
        }
        try {
            when (call.method) {
                "read" -> result.success(read(ref))
                "write" -> { write(ref, call.argument<String>("value") ?: ""); result.success(null) }
                "delete" -> { delete(ref); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (_: AEADBadTagException) { result.error("corrupt", "Protected credential integrity failed", null) }
          catch (_: SecurityException) { result.error("locked", "Protected credential access denied", null) }
          catch (_: Exception) { result.error("unavailable", "Protected credential operation failed", null) }
    }
}
