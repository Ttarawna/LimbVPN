package dev.quiet.quiet_vpn

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build

/**
 * Автоматически находит установленные российские приложения. Их исключают из VPN,
 * потому что только так Android перестаёт сообщать им, что VPN включён.
 * Определение по имени пакета и по магазину RuStore. Список можно дополнять.
 */
object RuApps {

    data class App(val pkg: String, val label: String)

    private val prefixes = listOf(
        "ru.", "com.yandex.", "com.vkontakte.", "com.vk.", "com.idamob.",
        "com.wildberries.", "com.avito.", "com.ozon.", "com.sberbank.",
        "com.mts.", "com.dodopizza.", "com.rostics"
    )

    // Эти приложения не исключаем: ими пользуются и с VPN (браузеры и т.п.).
    private val neverExclude = setOf(
        "com.yandex.browser", "com.yandex.browser.lite", "com.yandex.browser.beta",
        "com.yandex.browser.alpha", "ru.yandex.searchplugin.beta"
    )

    // Известные приложения, чьи пакеты не начинаются с типичных префиксов.
    private val extra = setOf(
        "com.idamob.tinkoff.android", "com.wildberries.ru", "com.avito.android",
        "com.vkontakte.android", "ru.rostel"
    )

    fun detect(ctx: Context): List<App> {
        val pm = ctx.packageManager
        val result = ArrayList<App>()
        val apps = try {
            pm.getInstalledApplications(0)
        } catch (_: Exception) {
            emptyList<ApplicationInfo>()
        }
        for (info in apps) {
            val pkg = info.packageName
            if (pkg == ctx.packageName || pkg in neverExclude) continue
            val isPureSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
                (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
            if (isPureSystem) continue
            val byName = prefixes.any { pkg.startsWith(it) } || pkg in extra
            val byStore = installer(pm, pkg) == "ru.vk.store" // RuStore
            if (byName || byStore) {
                val label = try {
                    info.loadLabel(pm).toString()
                } catch (_: Exception) {
                    pkg
                }
                result.add(App(pkg, label))
            }
        }
        return result.sortedBy { it.label.lowercase() }
    }

    @Suppress("DEPRECATION")
    private fun installer(pm: PackageManager, pkg: String): String? = try {
        if (Build.VERSION.SDK_INT >= 30) pm.getInstallSourceInfo(pkg).installingPackageName
        else pm.getInstallerPackageName(pkg)
    } catch (_: Exception) {
        null
    }
}
