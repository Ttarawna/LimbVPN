package dev.quiet.quiet_vpn

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val requestVpn = 4711
    private val requestNotifications = 4712
    private var channel: MethodChannel? = null
    private var pendingPrepare: MethodChannel.Result? = null
    private var pendingStart: MethodChannel.Result? = null
    private var receiverRegistered = false

    // Служба работает в другом процессе и сообщает состояние широковещательными сообщениями.
    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.getStringExtra("state")?.let { onServiceState(it) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quiet/vpn")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val intent = VpnService.prepare(this)
                    if (intent == null) {
                        result.success(true)
                    } else {
                        pendingPrepare = result
                        startActivityForResult(intent, requestVpn)
                    }
                }
                "askNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(
                            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                            requestNotifications
                        )
                    }
                    result.success(null)
                }
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("bad_args", "Нет конфига", null)
                    } else {
                        pendingStart = result
                        ContextCompat.startForegroundService(
                            this,
                            Intent(this, QuietVpnService::class.java)
                                .setAction(QuietVpnService.ACTION_START)
                                .putExtra("config", config)
                                .putExtra("excludeRu", call.argument<Boolean>("excludeRu") ?: true)
                                .putExtra("debug", call.argument<Boolean>("debug") ?: false)
                                .putExtra("killSwitch", call.argument<Boolean>("killSwitch") ?: true)
                        )
                    }
                }
                "stop" -> {
                    startService(
                        Intent(this, QuietVpnService::class.java)
                            .setAction(QuietVpnService.ACTION_STOP)
                    )
                    result.success(null)
                }
                "status" -> result.success(QuietVpnService.readState(this))
                "lockdown" -> result.success(readFile("mihomo/lockdown"))
                "excludedApps" -> result.success(readFile("mihomo/excluded_apps.txt"))
                "readLog" -> result.success(buildLogText())
                "bootCount" -> result.success(
                    try {
                        Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT, -1)
                    } catch (_: Exception) {
                        -1
                    }
                )
                "openAutostartSettings" -> {
                    openAutostartSettings()
                    result.success(null)
                }
                "openVpnSettings" -> {
                    startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                    result.success(null)
                }
                "setAutostart" -> {
                    getSharedPreferences("native", Context.MODE_PRIVATE).edit()
                        .putBoolean("autostart", call.argument<Boolean>("enabled") ?: false)
                        .apply()
                    result.success(null)
                }
                "forgetSession" -> {
                    SecureStore.delete(this, "session")
                    result.success(null)
                }
                "secureGet" -> result.success(
                    SecureStore.read(this, call.argument<String>("key") ?: "")
                )
                "secureSet" -> {
                    try {
                        SecureStore.write(
                            this,
                            call.argument<String>("key") ?: "",
                            call.argument<String>("value") ?: ""
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("secure_failed", e.message, null)
                    }
                }
                "secureDelete" -> {
                    SecureStore.delete(this, call.argument<String>("key") ?: "")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        if (!receiverRegistered) {
            ContextCompat.registerReceiver(
                this,
                stateReceiver,
                IntentFilter(QuietVpnService.ACTION_STATE),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            receiverRegistered = true
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (receiverRegistered) {
            try {
                unregisterReceiver(stateReceiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** Открывает экран разрешения автозапуска (у Xiaomi и других оболочек он отдельный). */
    private fun openAutostartSettings() {
        val candidates = listOf(
            Intent().setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"
            ),
            Intent().setClassName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
            ),
            Intent().setClassName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startup.StartupAppListActivity"
            ),
            Intent().setClassName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
            )
        )
        for (i in candidates) {
            try {
                startActivity(i)
                return
            } catch (_: Exception) {
            }
        }
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        )
    }

    private fun readFile(path: String): String = try {
        val f = File(filesDir, path)
        if (f.exists()) f.readText() else ""
    } catch (_: Exception) {
        ""
    }

    private fun buildLogText(): String = try {
        val boot = readFile("boot.log").trim()
        val bootPart = if (boot.isEmpty()) "" else "=== журнал автозапуска ===\n$boot\n\n"
        val file = File(filesDir, "mihomo/core.log")
        if (!file.exists()) {
            bootPart + "Журнал ядра пока пуст"
        } else {
            val noise = "check interface: permission denied"
            val lines = file.readLines()
            val skipped = lines.count { it.contains(noise) }
            val all = lines.filter { !it.contains(noise) }.joinToString("\n") +
                (if (skipped > 0) "\n(повторяющаяся строка скрыта, раз: $skipped)" else "")
            bootPart + (if (all.length > 40000) all.take(7000) + "\n...\n" + all.takeLast(33000) else all)
        }
    } catch (e: Exception) {
        "Не удалось прочитать журнал: " + e.message
    }

    private fun onServiceState(state: String) {
        channel?.invokeMethod("status", state)
        if (state == "on") {
            pendingStart?.success(null)
            pendingStart = null
        } else if (state.startsWith("error:")) {
            pendingStart?.error("start_failed", state.removePrefix("error:"), null)
            pendingStart = null
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == requestVpn) {
            pendingPrepare?.success(resultCode == Activity.RESULT_OK)
            pendingPrepare = null
        } else {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
