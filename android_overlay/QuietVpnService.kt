package dev.quiet.quiet_vpn

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import quietcore.Protector
import quietcore.Quietcore
import java.io.File

/**
 * Создаёт туннель и отдаёт его ядру Mihomo.
 * Состояния для интерфейса: "on", "off", "error:<текст>".
 */
class QuietVpnService : VpnService() {

    companion object {
        const val ACTION_START = "dev.quiet.quiet_vpn.START"
        const val ACTION_STOP = "dev.quiet.quiet_vpn.STOP"

        @Volatile
        var listener: ((String) -> Unit)? = null

        @Volatile
        var current: String = "off"

        fun report(state: String) {
            current = state
            listener?.invoke(state)
        }
    }

    private var tun: ParcelFileDescriptor? = null
    private var worker: Thread? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra("config")
                if (config == null) {
                    report("error:Нет конфига")
                } else {
                    start(config)
                }
            }
            ACTION_STOP -> {
                stopAll()
                report("off")
            }
        }
        return START_NOT_STICKY
    }

    private fun start(config: String) {
        worker = Thread {
            try {
                startCore(config)
                report("on")
            } catch (t: Throwable) {
                stopAll()
                report("error:" + (t.message ?: t.toString()))
            }
        }.also { it.start() }
    }

    private fun startCore(config: String) {
        val home = File(filesDir, "mihomo").apply { mkdirs() }
        copyGeoFiles(home)

        val builder = Builder()
            .setSession("Quiet VPN")
            .setMtu(1500)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("172.19.0.2")
            .addAddress("fdfe:dcba:9876::1", 126)
            .addRoute("::", 0)
        try {
            // Само приложение (и ядро внутри него) в туннель не заворачиваем.
            builder.addDisallowedApplication(packageName)
        } catch (_: Exception) {
        }

        val pfd = builder.establish() ?: throw IllegalStateException("Не удалось создать туннель")
        tun = pfd

        val protector = object : Protector {
            override fun protect(fd: Long): Boolean = this@QuietVpnService.protect(fd.toInt())
        }
        Quietcore.start(home.absolutePath, config, pfd.fd.toLong(), protector)
    }

    /** Списки РФ кладутся в APK при сборке. Если их нет, Mihomo скачает сам. */
    private fun copyGeoFiles(home: File) {
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val target = File(home, name)
            if (target.exists()) continue
            try {
                assets.open("geo/$name").use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun stopAll() {
        try {
            Quietcore.stop()
        } catch (_: Throwable) {
        }
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        stopSelf()
    }

    override fun onRevoke() {
        stopAll()
        report("off")
    }

    override fun onDestroy() {
        stopAll()
        report("off")
        super.onDestroy()
    }
}
