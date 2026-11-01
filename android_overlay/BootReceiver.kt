package dev.quiet.quiet_vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Автозапуск VPN после перезагрузки телефона (если включён и разрешение VPN выдано). */
class BootReceiver : BroadcastReceiver() {

    companion object {
        /** Короткий журнал автозапуска: видно, дошла ли система до нас после загрузки. */
        fun log(ctx: Context, text: String) {
            try {
                val f = File(ctx.filesDir, "boot.log")
                val old = if (f.exists()) f.readLines().takeLast(30) else emptyList()
                val stamp = SimpleDateFormat("dd.MM HH:mm:ss", Locale.US).format(Date())
                f.writeText((old + "$stamp $text").joinToString("\n"))
            } catch (_: Exception) {
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON"
        ) return

        val prefs = context.getSharedPreferences("native", Context.MODE_PRIVATE)
        val auto = prefs.getBoolean("autostart", false)
        log(context, "получено событие загрузки, автозапуск включён: $auto")
        if (!auto) return
        if (VpnService.prepare(context) != null) {
            log(context, "нет разрешения VPN, подключитесь вручную один раз")
            return
        }
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, QuietVpnService::class.java)
                    .setAction(QuietVpnService.ACTION_START_SAVED)
            )
            log(context, "служба VPN запущена")
        } catch (e: Exception) {
            log(context, "ошибка запуска службы: " + e.message)
        }
    }
}
