package dev.quiet.quiet_vpn

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.AtomicFile
import java.io.FileNotFoundException
import org.json.JSONArray
import org.json.JSONObject

/** Russian-region suggestions use exact package IDs; other apps are left to user choice. */
object RuApps {

    data class App(
        val pkg: String,
        val label: String,
        val inRussianCatalog: Boolean,
        val excluded: Boolean
    )

    private data class Inventory(
        val scanCompleted: Boolean,
        val apps: List<App>
    )

    private const val INVENTORY_FILE = "ru_apps.json"

    private val russianCatalog = setOf(
        "com.idamob.tinkoff.android",
        "com.wildberries.ru",
        "com.avito.android",
        "com.vkontakte.android",
        "ru.rostel",
        "ru.vk.store"
    )

    fun scan(ctx: Context, onProgress: (Int, Int) -> Unit): List<App> {
        onProgress(0, 0)
        val pm = ctx.packageManager
        @Suppress("DEPRECATION")
        val installed = pm.getInstalledApplications(0)
            .filter { it.packageName != ctx.packageName }
        val previous = readState(ctx)
        val previousApps = previous.apps.associateBy { it.pkg }
        val apps = installed.mapIndexed { index, info ->
            if (index % 16 == 0 || index == installed.lastIndex) {
                onProgress(index + 1, installed.size)
            }
            val catalogMatch = info.packageName in russianCatalog
            val excluded = if (!previous.scanCompleted) {
                catalogMatch
            } else if (info.packageName in previousApps) {
                previousApps.getValue(info.packageName).excluded
            } else {
                catalogMatch
            }
            App(
                pkg = info.packageName,
                label = try {
                    info.loadLabel(pm).toString().ifBlank { info.packageName }
                } catch (_: Exception) {
                    info.packageName
                },
                inRussianCatalog = catalogMatch,
                excluded = excluded
            )
        }.sortedBy { it.label.lowercase() }

        writeState(ctx, Inventory(scanCompleted = true, apps = apps))
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
        writeState(ctx, inventory.copy(apps = updated))
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
            return Inventory(scanCompleted = false, apps = emptyList())
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
        }
        return Inventory(root.getBoolean("scanCompleted"), apps)
    }

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
            .put("apps", encodeApps(inventory.apps))
            .toString()

    private fun encodeApps(apps: List<App>): JSONArray = JSONArray().apply {
        apps.forEach { app ->
            put(
                JSONObject()
                    .put("package", app.pkg)
                    .put("label", app.label)
                    .put("catalog", app.inRussianCatalog)
                    .put("excluded", app.excluded                    )
            )
        }
    }
}
