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

/** Возобновляет VPN после установки обновления приложения. */
class PackageUpdateReceiver : BroadcastReceiver() {

    companion object {
        /** Локальный журнал диагностики; не содержит адресов и параметров профиля. */
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
        if (action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val prefs = context.getSharedPreferences("native", Context.MODE_PRIVATE)
            val resume = prefs.getBoolean(
                "resumeAfterUpdate",
                prefs.getBoolean("resume", false)
            )
            prefs.edit()
                .putBoolean("updatePending", false)
                .putBoolean("resumeAfterUpdate", false)
                .putBoolean("resume", resume)
                .commit()
            log(context, "приложение обновлено, VPN был включён: $resume")
            if (resume && VpnService.prepare(context) == null) {
                try {
                    ContextCompat.startForegroundService(
                        context,
                        Intent(context, QuietVpnService::class.java)
                            .setAction(QuietVpnService.ACTION_START_SAVED)
                    )
                } catch (_: Exception) {
                }
            }
            return
        }
    }
}
