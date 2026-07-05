package com.meshlink.meshlink_app

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Native half of the `meshlink/secure_storage` platform channel on Android.
 *
 * The Android Keystore cannot export raw key material, so arbitrary secrets
 * (the identity private seed) can't live in it directly. Standard pattern:
 * a non-exportable AES-256 key is generated inside the Keystore — StrongBox
 * (dedicated secure element) when the device supports it, TEE fallback
 * otherwise — and each value is encrypted with AES/GCM under that key. The
 * ciphertext (IV ‖ ct, base64) sits in app-private SharedPreferences; it is
 * useless without the hardware-bound Keystore key, which never leaves
 * secure hardware. Uninstalling the app deletes both halves, so a reinstall
 * yields a fresh identity — the intended storage model.
 */
class KeystoreBridge(private val context: Context) {

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "meshlink/secure_storage").setMethodCallHandler { call, result ->
            val key = call.argument<String>("key")
            if (key == null) {
                result.error("bad_args", "missing key", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "read" -> result.success(read(key))
                    "write" -> {
                        val value = call.argument<String>("value")
                        if (value == null) {
                            result.error("bad_args", "missing value", null)
                        } else {
                            write(key, value)
                            result.success(null)
                        }
                    }
                    "delete" -> {
                        prefs().edit().remove(key).apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("keystore_error", e.toString(), null)
            }
        }
    }

    private fun prefs() =
        context.getSharedPreferences("meshlink_secure_storage", Context.MODE_PRIVATE)

    private fun read(key: String): String? {
        val stored = prefs().getString(key, null) ?: return null
        val blob = Base64.decode(stored, Base64.NO_WRAP)
        val iv = blob.copyOfRange(0, GCM_IV_BYTES)
        val ciphertext = blob.copyOfRange(GCM_IV_BYTES, blob.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, masterKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    private fun write(key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, masterKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val blob = cipher.iv + ciphertext
        prefs().edit().putString(key, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    /** Returns the Keystore-resident AES key, generating it on first use. */
    private fun masterKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(MASTER_KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val spec = KeyGenParameterSpec.Builder(
            MASTER_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                return generateKey(spec.setIsStrongBoxBacked(true).build())
            } catch (e: StrongBoxUnavailableException) {
                // No secure element on this device — fall through to TEE.
                spec.setIsStrongBoxBacked(false)
            }
        }
        return generateKey(spec.build())
    }

    private fun generateKey(spec: KeyGenParameterSpec): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(spec)
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val MASTER_KEY_ALIAS = "meshlink_secure_storage_master"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_IV_BYTES = 12
        const val GCM_TAG_BITS = 128
    }
}
