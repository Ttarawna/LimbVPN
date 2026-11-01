package dev.quiet.quiet_vpn

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build

/**
 * Автоматически находит российские приложения. Их исключают из VPN,
 * потому что только так Android перестаёт сообщать им, что VPN включён.
 * Признаки: имя пакета, магазин RuStore, название бренда в имени приложения.
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

    // Названия российских брендов (начало названия приложения, регистр не важен).
    // Нужны для приложений, у которых имя пакета не говорит о России.
    private val brands = listOf(
        "вкусно", "ростикс", "rostic", "додо", "dodo", "самокат", "купер", "вкусвилл",
        "бургер кинг", "пятёрочка", "пятерочка", "перекрёсток", "перекресток",
        "сбер", "sber", "тинькофф", "т-банк", "t-bank", "tinkoff", "втб", "vtb",
        "альфа-банк", "альфа банк", "газпромбанк", "райффайзен", "росбанк",
        "мтс", "билайн", "мегафон", "tele2", "теле2", "госуслуги", "почта россии",
        "ржд", "аэрофлот", "wildberries", "вайлдберриз", "ozon", "озон", "авито", "avito",
        "вконтакте", "яндекс", "дзен", "2гис", "2gis", "окко", "кинопоиск", "леруа",
        "м.видео", "эльдорадо", "спортмастер", "золотое яблоко", "мегамаркет", "fix price"
    )

    fun detect(ctx: Context): List<App> {
        val pm = ctx.packageManager
        val apps = try {
            pm.getInstalledApplications(0)
        } catch (_: Exception) {
            emptyList<ApplicationInfo>()
        }
        val result = ArrayList<App>()
        for (info in apps) {
            classify(ctx, pm, info)?.let { result.add(it) }
        }
        return result.sortedBy { it.label.lowercase() }
    }

    /** Проверка одного приложения (например, только что установленного). */
    fun isRussian(ctx: Context, pkg: String): Boolean = try {
        val pm = ctx.packageManager
        classify(ctx, pm, pm.getApplicationInfo(pkg, 0)) != null
    } catch (_: Exception) {
        false
    }

    private fun classify(ctx: Context, pm: PackageManager, info: ApplicationInfo): App? {
        val pkg = info.packageName
        if (pkg == ctx.packageName || pkg in neverExclude) return null
        val isPureSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
            (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
        if (isPureSystem) return null

        val label = try {
            info.loadLabel(pm).toString()
        } catch (_: Exception) {
            pkg
        }
        val lower = label.lowercase().trim()
        val byName = prefixes.any { pkg.startsWith(it) } || pkg in extra
        val byStore = installer(pm, pkg) == "ru.vk.store" // RuStore
        val byBrand = brands.any { lower.startsWith(it) }
        return if (byName || byStore || byBrand) App(pkg, label) else null
    }

    @Suppress("DEPRECATION")
    private fun installer(pm: PackageManager, pkg: String): String? = try {
        if (Build.VERSION.SDK_INT >= 30) pm.getInstallSourceInfo(pkg).installingPackageName
        else pm.getInstallerPackageName(pkg)
    } catch (_: Exception) {
        null
    }
}
