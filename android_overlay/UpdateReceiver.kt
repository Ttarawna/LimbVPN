package dev.quiet.quiet_vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller

/** Получает результат установки обновления от системного установщика. */
class UpdateReceiver : BroadcastReceiver() {

    companion object {
        /** Интерфейс подписывается, чтобы показать ошибку установки. */
        @Volatile
        var listener: ((String) -> Unit)? = null
    }

    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Системное окно «Обновить это приложение?»
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    if (confirm != null) context.startActivity(confirm)
                } catch (_: Exception) {
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // Приложение будет перезапущено системой.
            }
            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "неизвестная ошибка"
                listener?.invoke("error:$message")
            }
        }
    }
}
