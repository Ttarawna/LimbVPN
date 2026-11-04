package dev.quiet.quiet_vpn

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** Russian-region suggestions match known package IDs and app names. */
object RuApps {

    data class App(
        val pkg: String,
        val label: String,
        val inRussianCatalog: Boolean,
        val excluded: Boolean
    )

    private data class Inventory(
        val scanCompleted: Boolean,
        val catalogVersion: Int,
        val apps: List<App>
    )

    private const val INVENTORY_FILE = "ru_apps.json"
    private const val CATALOG_VERSION = 4

    private val russianCatalog = setOf(
        "com.idamob.tinkoff.android",
        "com.wildberries.ru",
        "com.avito.android",
        "com.vkontakte.android",
        "ru.rostel",
        "ru.vk.store"
    )

    private val nonWordCharacters = Regex("[^\\p{L}\\p{N}]+")
    private val russianAppNames = setOf(
        // Government services and public-sector apps.
        "Государственные сервисы",
        "госуслуги",
        "госуслуги дом",
        "госуслуги авто",
        "госуслуги культура",
        "госуслуги решаем вместе",
        "госключ",
        "gosuslugi",
        "gosuslugi dom",
        "goskey",
        "fns",
        "nalog",
        "fssp",
        "rosreestr",
        "sfr",
        "pfr",
        "моя москва",
        "mos ru",
        "мой налог",
        "мобильный идентификатор",
        "фнс",
        "налоговая",
        "налоги фнс",
        "фссп",
        "росреестр",
        "мвд россии",
        "мчс россии",
        "росгвардия",
        "сфр",
        "социальный фонд россии",
        "пфр",
        "гис жкх",
        "госуслуги биометрия",
        "пушкинская карта",
        "банк россии",
        "единая карта петербуржца",
        // Russian banks and payment services.
        "сбер",
        "сбербанк",
        "сбербанк онлайн",
        "sber",
        "альфа банк",
        "альфа банка",
        "альфа онлайн",
        "alfa",
        "тинькофф",
        "tinkoff",
        "т банк",
        "т банк онлайн",
        "t bank",
        "tbank",
        "втб",
        "втб онлайн",
        "vtb",
        "газпромбанк",
        "газпромбанк онлайн",
        "почта банк",
        "псб",
        "промсвязьбанк",
        "совкомбанк",
        "озон банк",
        "ozon bank",
        "яндекс пэй",
        "yandex pay",
        "юmoney",
        "юмани",
        "мир пэй",
        "mir pay",
        // Major Russian brands, marketplaces, and retailers.
        "wildberries",
        "вайлдберриз",
        "wb",
        "ozon",
        "озон",
        "авито",
        "avito",
        "яндекс",
        "yandex",
        "вконтакте",
        "вк",
        "vk",
        "одноклассники",
        "ok ru",
        "mail ru",
        "почта россии",
        "российские железные дороги",
        "ржд",
        "rzd",
        "аэрофлот",
        "победа авиакомпания",
        "туту",
        "2гис",
        "2gis",
        "ситимобил",
        "яндекс go",
        "яндекс такси",
        "делимобиль",
        "яндекс лавка",
        "яндекс еда",
        "самокат",
        "куппер",
        "пятерочка",
        "перекресток",
        "магнит",
        "лента",
        "x5",
        "dns shop",
        // Telecom operators and home internet providers.
        "мтс",
        "mts",
        "билайн",
        "beeline",
        "мегафон",
        "megafon",
        "tele2",
        "теле2",
        "t2",
        "yota",
        "йота",
        "ростелеком",
        "rostelecom",
        "дом ru",
        "домру",
        "мгтс",
        "мотив",
        "сбермобайл",
        // Transport, delivery, utilities, and other infrastructure.
        "московский транспорт",
        "подорожник",
        "тройка",
        "московское метро",
        "яндекс карты",
        "яндекс навигатор",
        "яндекс доставка",
        "яндекс почта",
        "сдэк",
        "cdek",
        "авито доставка",
        "яндекс аренда",
        "яндекс недвижимость",
        "гис жкх",
        "мособлгаз",
        "мосэнергосбыт",
        "жкх",
        "единый диспетчерский центр",
        // Smart-home, appliance, camera, and device companion apps.
        "умный дом",
        "умный дом сбер",
        "умный дом мтс",
        "яндекс дом",
        "дом с алисой",
        "mi home",
        "mihome",
        "xiaomi home",
        "huawei ai life",
        "ai life",
        "tuya",
        "honor ai space",
        "honor smart home",
        "smartthings",
        "samsung smartthings",
        "tuya smart",
        "smart life",
        "tapo",
        "kasa smart",
        "aqara home",
        "aqara",
        "ewelink",
        "home assistant",
        "google home",
        "amazon alexa",
        "alexa",
        "apple home",
        "philips hue",
        "yeelight",
        "roborock",
        "dreamehome",
        "dreame home",
        "eufy clean",
        "imou life",
        "ezviz",
        "hik connect",
        "reolink",
        "домофон",
        "видеонаблюдение",
        "умная камера",
        "умная розетка",
        "умная лампа",
        "умная колонка",
        "умные устройства",
        "умный телевизор",
        "умный свет"
    ).map(::normalize).toSet()

    fun scan(ctx: Context, onProgress: (Int, Int) -> Unit): List<App> {
        onProgress(0, 0)
        val pm = ctx.packageManager
        @Suppress("DEPRECATION")
        val installed = pm.getInstalledApplications(0)
            .filter { it.packageName != ctx.packageName && isUserApp(ctx, it) }
        val previous = readState(ctx)
        val previousApps = previous.apps.associateBy { it.pkg }
        val apps = installed.mapIndexed { index, info ->
            if (index % 16 == 0 || index == installed.lastIndex) {
                onProgress(index + 1, installed.size)
            }
            val label = try {
                info.loadLabel(pm).toString().ifBlank { info.packageName }
            } catch (_: Exception) {
                info.packageName
            }
            val catalogMatch = isRussianApp(info.packageName, label)
            val excluded = if (!previous.scanCompleted) {
                catalogMatch
            } else if (info.packageName in previousApps) {
                val oldApp = previousApps.getValue(info.packageName)
                oldApp.excluded || (
                    previous.catalogVersion < CATALOG_VERSION &&
                        catalogMatch && !oldApp.inRussianCatalog
                    )
            } else {
                catalogMatch
            }
            App(
                pkg = info.packageName,
                label = label,
                inRussianCatalog = catalogMatch,
                excluded = excluded
            )
        }.sortedBy { it.label.lowercase() }

        writeState(
            ctx,
            Inventory(
                scanCompleted = true,
                catalogVersion = CATALOG_VERSION,
                apps = apps
            )
        )
        if (installed.isEmpty()) onProgress(0, 0)
        return apps
    }

    fun readInventory(ctx: Context): String {
        return encodeInventory(readState(ctx))
    }

    fun saveSelection(ctx: Context, packages: Set<String>) {
        val inventory = readState(ctx)
        if (!inventory.scanCompleted) {
            throw IllegalStateException("Сначала проверьте установленные приложения")
        }
        val knownPackages = inventory.apps.map { it.pkg }.toSet()
        if (!knownPackages.containsAll(packages)) {
            throw IllegalArgumentException("Выбрано неизвестное приложение")
        }
        val updated = inventory.apps.map { app ->
            app.copy(excluded = app.pkg in packages)
        }
        writeState(
            ctx,
            inventory.copy(catalogVersion = CATALOG_VERSION, apps = updated)
        )
    }

    fun selected(ctx: Context): List<App> {
        return readState(ctx).apps
            .filter { it.excluded }
    }

    private fun readState(ctx: Context): Inventory {
        val file = AtomicFile(File(ctx.filesDir, INVENTORY_FILE))
        val json = try {
            file.openRead().bufferedReader().use { it.readText() }
        } catch (_: FileNotFoundException) {
            return Inventory(
                scanCompleted = false,
                catalogVersion = 0,
                apps = emptyList()
            )
        }
        val root = JSONObject(json)
        val array = root.getJSONArray("apps")
        val apps = (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            App(
                pkg = item.getString("package"),
                label = item.getString("label"),
                inRussianCatalog = item.getBoolean("catalog"),
                excluded = item.getBoolean("excluded")
            )
        }.filter { app ->
            try {
                isUserApp(ctx, ctx.packageManager.getApplicationInfo(app.pkg, 0))
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        }
        return Inventory(
            scanCompleted = root.getBoolean("scanCompleted"),
            catalogVersion = root.optInt("catalogVersion", 0),
            apps = apps
        )
    }

    private fun isRussianApp(packageName: String, label: String): Boolean {
        if (packageName in russianCatalog || packageName.startsWith("ru.")) return true
        val normalizedPackage = " ${normalize(packageName)} "
        if (normalizedPackage.contains(" ru ") ||
            normalizedPackage.contains(" russian ")
        ) {
            return true
        }
        val normalizedLabel = " ${normalize(label)} "
        return russianAppNames.any { name ->
            normalizedPackage.contains(" $name ") || normalizedLabel.contains(" $name ")
        }
    }

    private fun normalize(value: String): String =
        value.lowercase(Locale.ROOT)
            .replace(nonWordCharacters, " ")
            .trim()

    private fun isUserApp(ctx: Context, info: ApplicationInfo): Boolean =
        info.packageName != ctx.packageName &&
            info.flags and (
                ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP
                ) == 0

    private fun writeState(ctx: Context, inventory: Inventory) {
        val file = AtomicFile(File(ctx.filesDir, INVENTORY_FILE))
        val output = file.startWrite()
        try {
            output.write(encodeInventory(inventory).toByteArray(Charsets.UTF_8))
            file.finishWrite(output)
        } catch (e: Exception) {
            file.failWrite(output)
            throw e
        }
    }

    private fun encodeInventory(inventory: Inventory): String =
        JSONObject()
            .put("scanCompleted", inventory.scanCompleted)
            .put("catalogVersion", inventory.catalogVersion)
            .put("apps", encodeApps(inventory.apps))
            .toString()

    private fun encodeApps(apps: List<App>): JSONArray = JSONArray().apply {
        apps.forEach { app ->
            put(
                JSONObject()
                    .put("package", app.pkg)
                    .put("label", app.label)
                    .put("catalog", app.inRussianCatalog)
                    .put("excluded", app.excluded)
            )
        }
    }
}
