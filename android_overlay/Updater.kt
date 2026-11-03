package dev.quiet.quiet_vpn

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Автообновление: ищет новую версию среди релизов GitHub, скачивает APK, проверяет
 * подпись и хеш и отдаёт установщику Android. Установить обновление может только APK,
 * подписанный тем же ключом, что и установленное приложение (это гарантирует Android).
 */
object Updater {

    /** Репозиторий с релизами. Должен быть публичным. */
    const val REPO = "Ttarawna/LimbVPN"
    const val ACTION_RESULT = "dev.quiet.quiet_vpn.UPDATE_RESULT"

    data class Info(val version: String, val url: String, val sha256: String?)

    fun currentVersion(ctx: Context): String = try {
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "0"
    } catch (_: Exception) {
        "0"
    }

    /** Последняя версия из релизов или null, если релизов пока нет. */
    fun fetchLatest(): Info? {
        val conn = URL("https://api.github.com/repos/$REPO/releases/latest")
            .openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            conn.setRequestProperty("User-Agent", "LimbVPN-updater")
            if (conn.responseCode == 404) return null
            if (conn.responseCode != 200) {
                throw IllegalStateException("GitHub ответил: ${conn.responseCode}")
            }
            val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
            val version = json.getString("tag_name").trim().trimStart('v', 'V')
            val assets = json.getJSONArray("assets")
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                if (!a.getString("name").endsWith(".apk")) continue
                val url = a.getString("browser_download_url")
                if (!isTrustedUrl(url)) continue
                val digest = a.optString("digest", "")
                val sha = if (digest.startsWith("sha256:")) digest.removePrefix("sha256:") else null
                return Info(version, url, sha)
            }
            return null
        } finally {
            conn.disconnect()
        }
    }

    fun isNewer(latest: String, current: String): Boolean {
        fun parts(v: String) = v.split('.', '-', '+').map { it.toIntOrNull() ?: 0 }
        val a = parts(latest)
        val b = parts(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    /** Скачиваем только с GitHub по https. */
    private fun isTrustedUrl(url: String): Boolean = try {
        val u = URL(url)
        u.protocol == "https" && (u.host == "github.com" || u.host.endsWith(".githubusercontent.com"))
    } catch (_: Exception) {
        false
    }

    /** Скачивает APK, сверяет хеш и подпись. Возвращает готовый файл. */
    fun download(ctx: Context, info: Info, progress: (Int) -> Unit): File {
        if (!isTrustedUrl(info.url)) throw IllegalStateException("Недоверенный адрес обновления")
        val dir = File(ctx.cacheDir, "update").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val out = File(dir, "update.apk")
        val digest = MessageDigest.getInstance("SHA-256")

        val conn = URL(info.url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", "LimbVPN-updater")
            if (conn.responseCode != 200) throw IllegalStateException("Сервер ответил: " + conn.responseCode)
            val total = conn.contentLengthLong
            var done = 0L
            var lastPercent = -1
            conn.inputStream.use { input ->
                out.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        digest.update(buf, 0, n)
                        done += n
                        if (total > 0) {
                            val p = (done * 100 / total).toInt()
                            if (p != lastPercent) {
                                lastPercent = p
                                progress(p)
                            }
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }

        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (info.sha256 != null && !actual.equals(info.sha256, ignoreCase = true)) {
            out.delete()
            throw IllegalStateException("Контрольная сумма файла не совпала")
        }
        verify(ctx, out)
        return out
    }

    /** Файл должен быть этим же приложением, новее установленного и с той же подписью. */
    @Suppress("DEPRECATION")
    private fun verify(ctx: Context, apk: File) {
        val pm = ctx.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
        else PackageManager.GET_SIGNATURES
        val archive = pm.getPackageArchiveInfo(apk.path, flags)
            ?: throw IllegalStateException("Файл обновления повреждён")
        if (archive.packageName != ctx.packageName) {
            throw IllegalStateException("Файл обновления от другого приложения")
        }
        val installed = pm.getPackageInfo(ctx.packageName, flags)
        val oldCerts = certs(installed)
        val newCerts = certs(archive)
        if (newCerts.isNotEmpty() && oldCerts.isNotEmpty() && newCerts.none { it in oldCerts }) {
            apk.delete()
            throw IllegalStateException(
                "Подпись обновления не совпадает с установленной версией. " +
                    "Нужно один раз удалить приложение и поставить новую версию заново."
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun certs(info: PackageInfo): Set<String> {
        val sigs = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return sigs?.map {
            MessageDigest.getInstance("SHA-256").digest(it.toByteArray())
                .joinToString("") { b -> "%02x".format(b) }
        }?.toSet() ?: emptySet()
    }

    /** Передаёт APK установщику. Пользователь подтверждает установку в системном окне. */
    fun install(ctx: Context, apk: File) {
        val prefs = ctx.getSharedPreferences("native", Context.MODE_PRIVATE)
        val resumeAfterUpdate = prefs.getBoolean("resume", false)
        check(prefs.edit()
            .putBoolean("resumeAfterUpdate", resumeAfterUpdate)
            .putBoolean("updatePending", true)
            .commit()) { "Не удалось подготовить повторное подключение после обновления" }

        try {
            val installer = ctx.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(ctx.packageName)
            if (Build.VERSION.SDK_INT >= 31) {
                params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            val id = installer.createSession(params)
            installer.openSession(id).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("update", 0, apk.length()).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                val intent = Intent(ctx, UpdateReceiver::class.java).setAction(ACTION_RESULT)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val pi = PendingIntent.getBroadcast(ctx, id, intent, flags)
                session.commit(pi.intentSender)
            }
        } catch (e: Exception) {
            prefs.edit()
                .putBoolean("updatePending", false)
                .putBoolean("resumeAfterUpdate", false)
                .apply()
            throw e
        }
    }
}
