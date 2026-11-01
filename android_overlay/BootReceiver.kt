package dev.quiet.quiet_vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat

/** Автозапуск VPN после перезагрузки телефона (если включён и разрешение VPN выдано). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences("native", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("autostart", false)) return
        if (VpnService.prepare(context) != null) return // разрешение VPN ещё не выдано
        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, QuietVpnService::class.java)
                    .setAction(QuietVpnService.ACTION_START_SAVED)
            )
        } catch (_: Exception) {
        }
    }
}
