package dev.quiet.quiet_vpn

import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.content.ComponentName
import android.content.Intent
import android.widget.Toast
import androidx.core.content.ContextCompat

class VpnQuickSettingsTile : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val state = QuietVpnService.readState(this)
        if (state == "connecting" || state == "disconnecting") {
            updateTile()
            return
        }
        val shouldStop = state == "on" || state == "blocked"

        if (!shouldStop && VpnService.prepare(this) != null) {
            startActivityAndCollapse(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            )
            Toast.makeText(this, "Сначала разрешите VPN в приложении", Toast.LENGTH_SHORT).show()
            return
        }
        if (!shouldStop && SecureStore.read(this, "session") == null) {
            BootReceiver.log(this, "плитка VPN: нет сохранённого профиля")
            startActivityAndCollapse(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            )
            Toast.makeText(this, "Сначала подключитесь один раз в приложении", Toast.LENGTH_SHORT).show()
            return
        }

        try {
            val intent = Intent(this, QuietVpnService::class.java)
                .setAction(
                    if (shouldStop) QuietVpnService.ACTION_STOP
                    else QuietVpnService.ACTION_START_SAVED
                )
            if (shouldStop) startService(intent) else ContextCompat.startForegroundService(this, intent)
            updateTile()
        } catch (e: Exception) {
            BootReceiver.log(this, "плитка VPN: " + (e.message ?: e.toString()))
            Toast.makeText(this, "Не удалось изменить состояние VPN", Toast.LENGTH_SHORT).show()
        }
    }

    private fun updateTile() {
        val state = QuietVpnService.readState(this)
        val active = state == "on" || state == "blocked" ||
            state == "connecting" || state == "disconnecting"
        qsTile?.apply {
            this.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            if (Build.VERSION.SDK_INT >= 29) {
                subtitle = when (state) {
                    "on" -> "Подключено"
                    "connecting" -> "Подключение…"
                    "blocked" -> "Связь потеряна"
                    else -> "Отключено"
                }
            }
            contentDescription = "Limb VPN: $state"
            updateTile()
        }
    }
}
