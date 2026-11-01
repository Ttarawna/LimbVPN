package dev.quiet.quiet_vpn

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Хранилище секретов (профиль, пароль). Данные шифруются AES-256-GCM, ключ лежит в
 * Android Keystore и не может быть извлечён из устройства. Доступно всем процессам
 * приложения, в том числе после перезагрузки без участия пользователя.
 */
object SecureStore {
    private const val ALIAS = "quiet_vpn_key"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun file(ctx: Context, name: String): File {
        val safe = name.filter { it.isLetterOrDigit() || it == '_' }
        return File(ctx.filesDir, "secure_$safe")
    }

    @Synchronized
    fun write(ctx: Context, name: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        file(ctx, name).writeBytes(byteArrayOf(iv.size.toByte()) + iv + encrypted)
    }

    @Synchronized
    fun read(ctx: Context, name: String): String? {
        val f = file(ctx, name)
        if (!f.exists()) return null
        return try {
            val bytes = f.readBytes()
            val ivLen = bytes[0].toInt()
            val iv = bytes.copyOfRange(1, 1 + ivLen)
            val data = bytes.copyOfRange(1 + ivLen, bytes.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(data), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    @Synchronized
    fun delete(ctx: Context, name: String) {
        file(ctx, name).delete()
    }
}
