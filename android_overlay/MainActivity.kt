package dev.quiet.quiet_vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val requestVpn = 4711
    private var channel: MethodChannel? = null
    private var pendingPrepare: MethodChannel.Result? = null
    private var pendingStart: MethodChannel.Result? = null

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
                "status" -> result.success(QuietVpnService.current)
                "readLog" -> {
                    val file = java.io.File(filesDir, "mihomo/core.log")
                    val text = try {
                        if (!file.exists()) "Журнал пока пуст"
                        else {
                            val all = file.readText()
                            if (all.length > 30000) all.take(6000) + "\n...\n" + all.takeLast(24000) else all
                        }
                    } catch (e: Exception) {
                        "Не удалось прочитать журнал: " + e.message
                    }
                    result.success(text)
                }
                "openVpnSettings" -> {
                    startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        QuietVpnService.listener = { state -> runOnUiThread { onServiceState(state) } }
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
