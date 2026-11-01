package dev.quiet.quiet_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Параметры подключения. Сохраняются в зашифрованном виде для автозапуска. */
data class Session(
    val config: String,
    val excludeRu: Boolean,
    val debug: Boolean,
    val killSwitch: Boolean
) {
    fun toJson(): String = JSONObject()
        .put("config", config)
        .put("excludeRu", excludeRu)
        .put("debug", debug)
        .put("killSwitch", killSwitch)
        .toString()

    companion object {
        fun fromJson(text: String): Session? = try {
            val o = JSONObject(text)
            Session(
                o.getString("config"),
                o.optBoolean("excludeRu", true),
                o.optBoolean("debug", false),
                o.optBoolean("killSwitch", true)
            )
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Служба VPN (процесс :vpn). Держит туннель и уведомление, ядро работает в процессе :core.
 * Состояния: "on", "off", "blocked", "error:<текст>".
 *
 * Kill switch: если ядро упало, туннель остаётся открытым и никто его не читает,
 * поэтому трафик блокируется, пока ядро перезапускается.
 */
class QuietVpnService : VpnService() {

    companion object {
        const val ACTION_START = "dev.quiet.quiet_vpn.START"
        const val ACTION_START_SAVED = "dev.quiet.quiet_vpn.START_SAVED"
        const val ACTION_STOP = "dev.quiet.quiet_vpn.STOP"
        const val ACTION_STATE = "dev.quiet.quiet_vpn.STATE"
        private const val CHANNEL = "vpn_state"
        private const val NOTIF_ID = 1

        /** Текущее состояние. Если процесс службы мёртв, «живым» состояниям не верим. */
        fun readState(ctx: Context): String {
            return try {
                val parts = File(ctx.filesDir, "vpn_state").readText().split("|")
                val state = parts[0]
                val pid = parts.getOrNull(1)?.toIntOrNull()
                val live = state == "on" || state == "blocked"
                if (live && (pid == null || !File("/proc/$pid").exists())) "off" else state
            } catch (_: Exception) {
                "off"
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var tun: ParcelFileDescriptor? = null
    private var session: Session? = null
    private var core: IBinder? = null
    private var coreConn: ServiceConnection? = null

    @Volatile
    private var finishing = false

    @Volatile
    private var everOn = false

    @Volatile
    private var started = false

    private var retryDelayMs = 3000L

    // Принимает от ядра запросы «защитить сокет», чтобы он шёл мимо туннеля.
    private val protectBinder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == Ipc.PROTECT) {
                data.enforceInterface(Ipc.DESCRIPTOR)
                val pfd = data.readFileDescriptor()
                val ok = try {
                    this@QuietVpnService.protect(pfd.fd)
                } catch (_: Exception) {
                    false
                } finally {
                    try {
                        pfd.close()
                    } catch (_: Exception) {
                    }
                }
                reply?.writeNoException()
                reply?.writeInt(if (ok) 1 else 0)
                return true
            }
            return super.onTransact(code, data, reply, flags)
        }
    }

    // ---------------------------------------------------------------- команды

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Служба запущена как foreground: уведомление нужно показать сразу.
        if (intent?.action != ACTION_STOP) startForegroundCompat("Подключаю…")
        when (intent?.action) {
            ACTION_STOP -> finish("off")
            ACTION_START -> {
                val config = intent.getStringExtra("config")
                if (config == null) {
                    finish("error:Нет конфига")
                } else {
                    val s = Session(
                        config,
                        intent.getBooleanExtra("excludeRu", true),
                        intent.getBooleanExtra("debug", false),
                        intent.getBooleanExtra("killSwitch", true)
                    )
                    startOnce(s, true)
                }
            }
            // Автозапуск, «Всегда включённый VPN» от системы или перезапуск после сбоя
            ACTION_START_SAVED, VpnService.SERVICE_INTERFACE, null -> {
                val s = SecureStore.read(this, "session")?.let { Session.fromJson(it) }
                if (s == null) {
                    startForegroundCompat("Нет сохранённого профиля")
                    finish("error:Нет сохранённого профиля")
                } else {
                    startOnce(s, false)
                }
            }
        }
        return START_STICKY
    }

    private fun startOnce(s: Session, fromUser: Boolean) {
        if (started) return
        started = true
        startForegroundCompat("Подключаю…")
        if (fromUser) {
            try {
                SecureStore.write(this, "session", s.toJson())
            } catch (_: Exception) {
            }
        }
        session = s
        Thread {
            try {
                val pfd = buildTunnel(s)
                startCoreProcess(s, pfd)
                everOn = true
                setState("on")
            } catch (t: Throwable) {
                val msg = t.message ?: t.toString()
                if (!fromUser && s.killSwitch && tun != null && !finishing) {
                    enterBlocked()
                } else {
                    finish("error:$msg")
                }
            }
        }.start()
    }

    // ---------------------------------------------------------------- туннель

    private fun buildTunnel(s: Session): ParcelFileDescriptor {
        val home = File(filesDir, "mihomo").apply { mkdirs() }
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
        if (!s.debug) {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {
            }
        }

        // Российские приложения работают вне VPN: так Android не сообщает им о VPN.
        val excluded = ArrayList<String>()
        if (s.excludeRu) {
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

        val pfd = builder.establish() ?: throw IllegalStateException("Не удалось создать туннель")
        tun = pfd
        try {
            val lockdown = Build.VERSION.SDK_INT >= 29 && isLockdownEnabled
            File(home, "lockdown").writeText(if (lockdown) "1" else "0")
        } catch (_: Exception) {
        }
        return pfd
    }

    // ---------------------------------------------------------------- ядро

    private fun startCoreProcess(s: Session, pfd: ParcelFileDescriptor) {
        val latch = CountDownLatch(1)
        var binder: IBinder? = null
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                binder = service
                latch.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                onCoreGone()
            }
        }
        coreConn = conn
        if (!bindService(Intent(this, CoreService::class.java), conn, Context.BIND_AUTO_CREATE)) {
            throw IllegalStateException("Не удалось запустить процесс ядра")
        }
        if (!latch.await(10, TimeUnit.SECONDS)) {
            throw IllegalStateException("Процесс ядра не ответил")
        }
        val b = binder ?: throw IllegalStateException("Процесс ядра не ответил")
        core = b

        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(Ipc.DESCRIPTOR)
            data.writeString(s.config)
            data.writeInt(if (s.debug) 1 else 0)
            data.writeFileDescriptor(pfd.fileDescriptor)
            data.writeStrongBinder(protectBinder)
            b.transact(Ipc.CORE_START, data, reply, 0)
            reply.readException() // бросит исключение с текстом ошибки ядра
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    /** Процесс ядра завершился. */
    private fun onCoreGone() {
        if (finishing || !everOn) return
        core = null
        val s = session ?: return
        if (s.killSwitch && tun != null) {
            enterBlocked()
        } else {
            finish("error:Ядро остановилось")
        }
    }

    /** Kill switch: туннель остаётся, ядро перезапускается, трафик пока заблокирован. */
    private fun enterBlocked() {
        if (finishing) return
        setState("blocked")
        handler.postDelayed({ retryCore() }, retryDelayMs)
        retryDelayMs = minOf(retryDelayMs * 2, 30000L)
    }

    private fun retryCore() {
        if (finishing) return
        val s = session ?: return
        val t = tun ?: return
        Thread {
            try {
                coreConn?.let {
                    try {
                        unbindService(it)
                    } catch (_: Exception) {
                    }
                }
                startCoreProcess(s, t)
                everOn = true
                retryDelayMs = 3000L
                setState("on")
            } catch (_: Throwable) {
                enterBlocked()
            }
        }.start()
    }

    // ---------------------------------------------------------------- завершение

    /** Закрывает туннель, сообщает итоговое состояние и завершает процессы службы и ядра. */
    private fun finish(finalState: String) {
        if (finishing) return
        finishing = true
        handler.removeCallbacksAndMessages(null)
        try {
            core?.let { b ->
                val d = Parcel.obtain()
                d.writeInterfaceToken(Ipc.DESCRIPTOR)
                b.transact(Ipc.CORE_STOP, d, null, IBinder.FLAG_ONEWAY)
                d.recycle()
            }
        } catch (_: Exception) {
        }
        try {
            coreConn?.let { unbindService(it) }
        } catch (_: Exception) {
        }
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        setState(finalState)
        try {
            @Suppress("DEPRECATION")
            stopForeground(true)
        } catch (_: Exception) {
        }
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

    // ---------------------------------------------------------------- состояние и уведомление

    private fun setState(state: String) {
        try {
            File(filesDir, "vpn_state").writeText(state + "|" + Process.myPid())
        } catch (_: Exception) {
        }
        sendBroadcast(Intent(ACTION_STATE).setPackage(packageName).putExtra("state", state))
        when (state) {
            "on" -> updateNotification("Подключено")
            "blocked" -> updateNotification("Связь потеряна: трафик заблокирован")
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Состояние VPN", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(text: String): Notification {
        ensureChannel()
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), flags)
        val stop = PendingIntent.getService(
            this, 1, Intent(this, QuietVpnService::class.java).setAction(ACTION_STOP), flags
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
        else Notification.Builder(this)
        b.setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Quiet VPN")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    "Отключить",
                    stop
                ).build()
            )
        return b.build()
    }

    private fun startForegroundCompat(text: String) {
        try {
            val n = buildNotification(text)
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIF_ID, n, 0x400) // тип systemExempted
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (_: Exception) {
        }
    }

    private fun updateNotification(text: String) {
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
        } catch (_: Exception) {
        }
    }
}
