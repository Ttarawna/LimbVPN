package dev.quiet.quiet_vpn

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.Process
import quietcore.Protector
import quietcore.Quietcore
import java.io.File

/**
 * Работает в отдельном процессе (:vpn). Ядро Mihomo не умеет чисто останавливаться,
 * поэтому отключение = закрыть туннель и завершить этот процесс. Интерфейс не страдает.
 * Состояния: "on", "off", "error:<текст>". Передаются широковещательным сообщением
 * и записью в файл (по нему интерфейс узнаёт состояние после перезапуска).
 */
class QuietVpnService : VpnService() {

    companion object {
        const val ACTION_START = "dev.quiet.quiet_vpn.START"
        const val ACTION_STOP = "dev.quiet.quiet_vpn.STOP"
        const val ACTION_STATE = "dev.quiet.quiet_vpn.STATE"

        private fun stateFile(ctx: Context) = File(ctx.filesDir, "vpn_state")

        /** Текущее состояние. Если процесс службы уже мёртв, "on" не верим. */
        fun readState(ctx: Context): String {
            return try {
                val parts = stateFile(ctx).readText().split("|")
                val state = parts[0]
                val pid = parts.getOrNull(1)?.toIntOrNull()
                if (state == "on" && (pid == null || !File("/proc/$pid").exists())) "off" else state
            } catch (_: Exception) {
                "off"
            }
        }
    }

    private var tun: ParcelFileDescriptor? = null

    @Volatile
    private var finishing = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra("config")
                if (config == null) finish("error:Нет конфига") else start(
                    config,
                    intent.getBooleanExtra("excludeRu", true),
                    intent.getBooleanExtra("debug", false)
                )
            }
            ACTION_STOP -> finish("off")
        }
        return START_NOT_STICKY
    }

    private fun report(state: String) {
        try {
            stateFile(this).writeText(state + "|" + Process.myPid())
        } catch (_: Exception) {
        }
        sendBroadcast(Intent(ACTION_STATE).setPackage(packageName).putExtra("state", state))
    }

    private fun start(config: String, excludeRu: Boolean, debug: Boolean) {
        Thread {
            try {
                startCore(config, excludeRu, debug)
                report("on")
            } catch (t: Throwable) {
                finish("error:" + (t.message ?: t.toString()))
            }
        }.start()
    }

    /** Короткие записи о том, что Android думает о сети VPN (читаются вместе с журналом ядра). */
    private fun note(text: String) {
        try {
            File(filesDir, "mihomo/app.log").appendText(text + "\n")
        } catch (_: Exception) {
        }
    }

    private fun watchNetwork() {
        try {
            val cm = getSystemService(ConnectivityManager::class.java)
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    val internet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    note("Android: сеть VPN, интернет=" + internet + ", проверена системой=" + validated)
                }

                override fun onLost(network: Network) {
                    note("Android: сеть VPN потеряна")
                }
            })
        } catch (e: Exception) {
            note("Android: не удалось следить за сетью: " + e.message)
        }
    }

    private fun startCore(config: String, excludeRu: Boolean, debug: Boolean) {
        val home = File(filesDir, "mihomo").apply { mkdirs() }
        File(home, "app.log").delete()
        copyGeoFiles(home)

        val builder = Builder()
            .setSession("Quiet VPN")
            .setMtu(9000)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("172.19.0.2")
            .addAddress("fdfe:dcba:9876::1", 126)
            .addRoute("::", 0)

        // В обычном режиме приложение и ядро в туннель не заворачиваем.
        // В режиме диагностики оставляем, чтобы самопроверки шли через туннель.
        if (!debug) {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {
            }
        }

        // Российские приложения работают вне VPN: так Android не сообщает им о VPN.
        val excluded = ArrayList<String>()
        if (excludeRu) {
            for (app in RuApps.detect(this)) {
                try {
                    builder.addDisallowedApplication(app.pkg)
                    excluded.add(app.label + " (" + app.pkg + ")")
                } catch (_: Exception) {
                }
            }
        }
        try {
            File(home, "excluded_apps.txt").writeText(excluded.joinToString("\n"))
        } catch (_: Exception) {
        }
        note("Приложений вне VPN: " + excluded.size)

        val pfd = builder.establish() ?: throw IllegalStateException("Не удалось создать туннель")
        tun = pfd
        watchNetwork()

        val protector = object : Protector {
            override fun protect(fd: Long): Boolean = this@QuietVpnService.protect(fd.toInt())
        }
        Quietcore.start(home.absolutePath, config, pfd.fd.toLong(), protector, debug)
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

    /** Закрывает туннель, сообщает итоговое состояние и завершает процесс службы. */
    private fun finish(finalState: String) {
        if (finishing) return
        finishing = true
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        report(finalState)
        stopSelf()
        Thread {
            try {
                Thread.sleep(400)
            } catch (_: InterruptedException) {
            }
            Process.killProcess(Process.myPid())
        }.start()
    }

    override fun onRevoke() {
        finish("off")
    }

    override fun onDestroy() {
        if (!finishing) finish("off")
        super.onDestroy()
    }
}
