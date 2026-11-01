package dev.quiet.quiet_vpn

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val requestVpn = 4711
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
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("bad_args", "Нет конфига", null)
                    } else {
                        pendingStart = result
                        startService(
                            Intent(this, QuietVpnService::class.java)
                                .setAction(QuietVpnService.ACTION_START)
                                .putExtra("config", config)
                                .putExtra("excludeRu", call.argument<Boolean>("excludeRu") ?: true)
                                .putExtra("debug", call.argument<Boolean>("debug") ?: false)
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
                "excludedApps" -> {
                    val f = java.io.File(filesDir, "mihomo/excluded_apps.txt")
                    result.success(try { if (f.exists()) f.readText() else "" } catch (e: Exception) { "" })
                }
                "readLog" -> {
                    val file = java.io.File(filesDir, "mihomo/core.log")
                    val androidNotes = try {
                        val f = java.io.File(filesDir, "mihomo/app.log")
                        if (f.exists()) f.readText() else ""
                    } catch (e: Exception) {
                        ""
                    }
                    val text = try {
                        if (!file.exists()) "Журнал пока пуст"
                        else {
                            val noise = "check interface: permission denied"
                            val lines = file.readLines()
                            val skipped = lines.count { it.contains(noise) }
                            val all = lines.filter { !it.contains(noise) }.joinToString("\n") +
                                (if (skipped > 0) "\n(повторяющаяся строка 'check interface: permission denied' скрыта, раз: " + skipped + ")" else "")
                            if (all.length > 40000) all.take(7000) + "\n...\n" + all.takeLast(33000) else all
                        }
                    } catch (e: Exception) {
                        "Не удалось прочитать журнал: " + e.message
                    }
                    result.success(androidNotes + text)
                }
                "openVpnSettings" -> {
                    startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
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
