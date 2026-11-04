package dev.quiet.quiet_vpn

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.Settings
import android.service.quicksettings.TileService
import android.util.AtomicFile
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

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

        /** Состояние службы и время подключения. */
        fun readStatus(ctx: Context): Map<String, Any?> {
            val parts = try {
                AtomicFile(File(ctx.filesDir, "vpn_state")).openRead().bufferedReader().use {
                    it.readText().split("|")
                }
            } catch (_: Exception) {
                emptyList()
            }
            val storedState = parts.firstOrNull() ?: "off"
            val savedPid = parts.getOrNull(1)?.toIntOrNull()
            val savedBootCount = parts.getOrNull(3)?.toIntOrNull()
            val storedRevision = parts.getOrNull(4)?.toLongOrNull() ?: 0L
            val currentBootCount = try {
                Settings.Global.getInt(ctx.contentResolver, Settings.Global.BOOT_COUNT, -1)
            } catch (_: Exception) {
                -1
            }
            // /proc can be inaccessible even while the VPN process is alive.
            val sameBoot = currentBootCount < 0 ||
                (savedBootCount != null && savedBootCount >= 0 &&
                    savedBootCount == currentBootCount)
            val serviceAlive = savedPid?.let { isVpnServiceRunning(ctx, it) }
            val staleActiveState = storedState in listOf("on", "connecting", "blocked") &&
                (!sameBoot || serviceAlive == false)
            val state = if (staleActiveState) "off" else storedState
            val revision = storedRevision + if (staleActiveState) 1L else 0L
            val since = if (state == "on") parts.getOrNull(2)?.toLongOrNull() else null
            return mapOf("state" to state, "since" to since, "revision" to revision)
        }

        @Suppress("DEPRECATION")
        private fun isVpnServiceRunning(ctx: Context, pid: Int): Boolean? = try {
            val manager = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            manager.getRunningServices(Int.MAX_VALUE).any {
                it.service == ComponentName(ctx, QuietVpnService::class.java) && it.pid == pid
            }
        } catch (_: Exception) {
            null
        }

        fun readState(ctx: Context): String = readStatus(ctx)["state"] as? String ?: "off"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val stateLock = Any()
    @Volatile
    private var networkCallbackRegistered = false
    @Volatile
    private var underlyingNetwork: Network? = null
    @Volatile
    private var networkLost = false
    @Volatile
    private var configuredLocalDns: List<String> = emptyList()
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
    private val retryScheduled = AtomicBoolean(false)
    private val retrying = AtomicBoolean(false)
    private val rebuildInProgress = AtomicBoolean(false)

    @Volatile
    private var connectedSinceMillis = 0L
    private var stateRevision = 0L

    @Volatile
    private var rebuilding = false

    private var packageReceiverRegistered = false

    // Новое российское приложение появилось, пока VPN работает: его нужно добавить в
    // исключения. Список исключений задаётся при создании туннеля, поэтому туннель
    // пересоздаётся (на пару секунд трафик блокируется).
    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val i = intent ?: return
            if (i.action != Intent.ACTION_PACKAGE_ADDED) return
            if (i.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return
            val pkg = i.data?.schemeSpecificPart ?: return
            val s = session ?: return
            if (!s.excludeRu || !everOn || finishing) return
            if (RuApps.isRussian(this@QuietVpnService, pkg)) {
                handler.removeCallbacks(rebuildRunnable)
                handler.postDelayed(rebuildRunnable, 2500)
            }
        }
    }

    private val rebuildRunnable = Runnable { rebuildTunnel() }
    private val networkRefreshRunnable = Runnable { refreshCoreAfterNetworkChange() }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val changed = networkLost || (underlyingNetwork != null && underlyingNetwork != network)
            underlyingNetwork = network
            networkLost = false
            if (changed) scheduleNetworkRefresh()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            if (finishing || !everOn) return
            try {
                if (localDnsServers(this@QuietVpnService) != configuredLocalDns) {
                    scheduleNetworkRefresh()
                }
            } catch (e: Exception) {
                BootReceiver.log(
                    this@QuietVpnService,
                    "не удалось проверить DNS после смены сети: " + (e.message ?: e.toString())
                )
            }
        }

        override fun onLost(network: Network) {
            if (underlyingNetwork == network) {
                underlyingNetwork = null
                networkLost = true
            }
        }
    }

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
        val prefs = getSharedPreferences("native", Context.MODE_PRIVATE)
        if (intent?.action == ACTION_STOP && prefs.getBoolean("updatePending", false)) {
            prefs.edit()
                .putBoolean("resume", false)
                .putBoolean("resumeAfterUpdate", false)
                .apply()
        }
        val updatePending = prefs.getBoolean("updatePending", false)
        if (updatePending &&
            (intent == null || intent.action == VpnService.SERVICE_INTERFACE ||
                intent.action == ACTION_START_SAVED)
        ) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // Служба запущена как foreground: уведомление нужно показать сразу.
        if (intent?.action != ACTION_STOP) {
            try {
                startForegroundCompat("Подключаю…")
            } catch (e: Exception) {
                BootReceiver.log(this, "не удалось запустить foreground-службу: " + (e.message ?: e.toString()))
                finish("error:Не удалось запустить службу VPN")
                return START_NOT_STICKY
            }
        }
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
                BootReceiver.log(this, "служба VPN: запуск с сохранёнными параметрами")
                val s = SecureStore.read(this, "session")?.let { Session.fromJson(it) }
                if (s == null) {
                    BootReceiver.log(this, "нет сохранённых параметров подключения")
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
        if (fromUser) {
            try {
                SecureStore.write(this, "session", s.toJson())
            } catch (_: Exception) {
            }
        }
        session = s
        setState("connecting")
        handler.postDelayed(startupTimeout, 30_000L)
        Thread {
            try {
                val pfd = buildTunnel(s)
                startCoreProcess(s, pfd)
                synchronized(stateLock) {
                    if (finishing) return@Thread
                    handler.removeCallbacks(startupTimeout)
                    everOn = true
                    setState("on")
                    registerPackageReceiver(s)
                    registerNetworkCallback()
                }
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

    private val startupTimeout = Runnable {
        if (!everOn && !finishing) finish("error:Тайм-аут запуска VPN")
    }

    // ---------------------------------------------------------------- туннель

    private fun buildTunnel(s: Session): ParcelFileDescriptor {
        val home = File(filesDir, "mihomo").apply { mkdirs() }
        val builder = Builder()
            .setSession("Limb VPN")
            .setMtu(1400)
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
        val localDns = localDnsServers(this)
        val latch = CountDownLatch(1)
        var binder: IBinder? = null
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                binder = service
                latch.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                if (coreConn === this) onCoreGone()
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
            data.writeStringList(localDns)
            b.transact(Ipc.CORE_START, data, reply, 0)
            reply.readException() // бросит исключение с текстом ошибки ядра
            configuredLocalDns = localDns
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    /** Процесс ядра завершился. */
    private fun onCoreGone() {
        if (finishing || !everOn || rebuilding) return
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
        handler.removeCallbacks(startupTimeout)
        setState("blocked")
        if (retryScheduled.compareAndSet(false, true)) {
            handler.postDelayed({
                retryScheduled.set(false)
                retryCore()
            }, retryDelayMs)
        }
        retryDelayMs = minOf(retryDelayMs * 2, 30000L)
    }

    private fun retryCore() {
        if (finishing) return
        val s = session ?: return
        val t = tun ?: return
        if (!retrying.compareAndSet(false, true)) return
        Thread {
            try {
                coreConn?.let {
                    try {
                        unbindService(it)
                    } catch (_: Exception) {
                    }
                }
                startCoreProcess(s, t)
                if (finishing) return@Thread
                everOn = true
                retryDelayMs = 3000L
                setState("on")
            } catch (_: Throwable) {
                enterBlocked()
            } finally {
                retrying.set(false)
            }
        }.start()
    }

    private fun registerPackageReceiver(s: Session) {
        if (!s.excludeRu || packageReceiverRegistered) return
        try {
            val filter = IntentFilter(Intent.ACTION_PACKAGE_ADDED).apply { addDataScheme("package") }
            ContextCompat.registerReceiver(this, packageReceiver, filter, ContextCompat.RECEIVER_EXPORTED)
            packageReceiverRegistered = true
        } catch (_: Exception) {
        }
    }

    private fun unregisterPackageReceiver() {
        if (!packageReceiverRegistered) return
        try {
            unregisterReceiver(packageReceiver)
        } catch (_: Exception) {
        }
        packageReceiverRegistered = false
    }

    private fun registerNetworkCallback() {
        synchronized(stateLock) {
            if (finishing || networkCallbackRegistered) return
            val manager = getSystemService(ConnectivityManager::class.java)
            try {
                manager.registerDefaultNetworkCallback(networkCallback)
                networkCallbackRegistered = true
            } catch (e: Exception) {
                BootReceiver.log(this, "не удалось отслеживать смену сети: " + (e.message ?: e.toString()))
            }
        }
    }

    private fun scheduleNetworkRefresh() {
        if (finishing) return
        handler.removeCallbacks(networkRefreshRunnable)
        handler.postDelayed(networkRefreshRunnable, 1500)
    }

    private fun unregisterNetworkCallback() {
        if (!networkCallbackRegistered) return
        try {
            getSystemService(ConnectivityManager::class.java)
                .unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {
        }
        networkCallbackRegistered = false
        underlyingNetwork = null
        networkLost = false
    }

    /** Перезапускает исходящие соединения Mihomo после смены Wi-Fi/мобильной сети. */
    private fun refreshCoreAfterNetworkChange() {
        if (finishing || !everOn || rebuilding || readState(this) != "on") return
        val s = session ?: return
        val t = tun ?: return
        Thread {
            if (!rebuildInProgress.compareAndSet(false, true)) return@Thread
            rebuilding = true
            try {
                setState("blocked")
                core?.let { b ->
                    val data = Parcel.obtain()
                    try {
                        data.writeInterfaceToken(Ipc.DESCRIPTOR)
                        b.transact(Ipc.CORE_STOP, data, null, IBinder.FLAG_ONEWAY)
                    } finally {
                        data.recycle()
                    }
                }
                core = null
                coreConn?.let {
                    try {
                        unbindService(it)
                    } catch (_: Exception) {
                    }
                }
                Thread.sleep(700)
                if (finishing) return@Thread
                startCoreProcess(s, t)
                if (finishing) return@Thread
                retryDelayMs = 3000L
                setState("on")
            } catch (e: Throwable) {
                if (s.killSwitch && tun != null) enterBlocked()
                else finish("error:" + (e.message ?: e.toString()))
            } finally {
                rebuilding = false
                rebuildInProgress.set(false)
            }
        }.start()
    }

    /** Пересоздаёт туннель с обновлённым списком приложений вне VPN и перезапускает ядро. */
    private fun rebuildTunnel() {
        if (finishing) return
        val s = session ?: return
        Thread {
            if (!rebuildInProgress.compareAndSet(false, true)) return@Thread
            rebuilding = true
            try {
                updateNotification("Обновляю список приложений…")
                val old = tun
                buildTunnel(s) // новый туннель заменяет прежний
                try {
                    old?.close()
                } catch (_: Exception) {
                }
                try {
                    core?.let { b ->
                        val d = Parcel.obtain()
                        d.writeInterfaceToken(Ipc.DESCRIPTOR)
                        b.transact(Ipc.CORE_STOP, d, null, IBinder.FLAG_ONEWAY)
                        d.recycle()
                    }
                } catch (_: Exception) {
                }
                core = null
                Thread.sleep(700)
                coreConn?.let {
                    try {
                        unbindService(it)
                    } catch (_: Exception) {
                    }
                }
                startCoreProcess(s, tun ?: throw IllegalStateException("Нет туннеля"))
                everOn = true
                setState("on")
            } catch (t: Throwable) {
                if (s.killSwitch && tun != null) enterBlocked() else finish("error:" + (t.message ?: t.toString()))
            } finally {
                rebuilding = false
                rebuildInProgress.set(false)
            }
        }.start()
    }

    // ---------------------------------------------------------------- завершение

    /** Закрывает туннель, сообщает итоговое состояние и завершает процессы службы и ядра. */
    private fun finish(finalState: String) {
        synchronized(stateLock) {
            if (finishing) return
            finishing = true
        }
        val prefs = getSharedPreferences("native", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("updatePending", false)) {
            prefs.edit().putBoolean("resume", false).apply()
        }
        handler.removeCallbacksAndMessages(null)
        retryScheduled.set(false)
        unregisterPackageReceiver()
        handler.removeCallbacks(networkRefreshRunnable)
        unregisterNetworkCallback()
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
            // После обычного отключения не храним журнал: в нём могут быть адреса сайтов.
            if (finalState == "off" && session?.debug != true) {
                try {
                    File(filesDir, "mihomo/core.log").delete()
                } catch (_: Exception) {
                }
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
        synchronized(stateLock) {
            if (finishing && state != "off" && !state.startsWith("error:")) return
            when {
                state == "on" && connectedSinceMillis == 0L ->
                    connectedSinceMillis = System.currentTimeMillis()
                state == "connecting" || state == "off" || state.startsWith("error:") ->
                    connectedSinceMillis = 0L
            }
            try {
                val stateFile = File(filesDir, "vpn_state")
                val atomicFile = AtomicFile(stateFile)
                val storedRevision = try {
                    atomicFile.openRead().bufferedReader().use { reader ->
                        reader.readText().split("|").getOrNull(4)?.toLongOrNull() ?: 0L
                    }
                } catch (_: Exception) {
                    0L
                }
                // Leave odd revisions for readStatus's synthetic "off" state.
                stateRevision = maxOf(stateRevision, storedRevision) + 2
                val output = atomicFile.startWrite()
                try {
                    val bootCount = try {
                        Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT, -1)
                    } catch (_: Exception) {
                        -1
                    }
                    output.write(
                        "$state|${Process.myPid()}|$connectedSinceMillis|$bootCount|$stateRevision"
                            .toByteArray()
                    )
                    atomicFile.finishWrite(output)
                } catch (e: Exception) {
                    atomicFile.failWrite(output)
                    throw e
                }
            } catch (_: Exception) {
            }
            sendBroadcast(
                Intent(ACTION_STATE)
                    .setPackage(packageName)
                    .putExtra("state", state)
                    .putExtra("since", connectedSinceMillis)
                    .putExtra("revision", stateRevision)
            )
            try {
                TileService.requestListeningState(
                    this,
                    ComponentName(this, VpnQuickSettingsTile::class.java)
                )
            } catch (_: Exception) {
            }
            when (state) {
                "on" -> {
                    // Запоминаем, что VPN работал: после обновления приложения он включится снова.
                    getSharedPreferences("native", Context.MODE_PRIVATE).edit().putBoolean("resume", true).apply()
                    updateNotification("Подключено")
                }
                "blocked" -> updateNotification("Связь потеряна: трафик заблокирован")
            }
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
        b.setSmallIcon(R.drawable.ic_stat_limb)
            .setColor(0xFF7B2FF7.toInt())
            .setContentTitle("Limb VPN")
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
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun updateNotification(text: String) {
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
        } catch (_: Exception) {
        }
    }
}
