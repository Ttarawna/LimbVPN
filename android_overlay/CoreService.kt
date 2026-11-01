package dev.quiet.quiet_vpn

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import quietcore.Protector
import quietcore.Quietcore
import java.io.File

/**
 * Ядро Mihomo в отдельном процессе (:core). Если оно упадёт, служба VPN в другом процессе
 * сохранит туннель закрытым для трафика (kill switch) и перезапустит ядро.
 * Остановка ядра = завершение этого процесса (Mihomo не умеет чисто останавливаться).
 */
class CoreService : Service() {

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            when (code) {
                Ipc.CORE_START -> {
                    data.enforceInterface(Ipc.DESCRIPTOR)
                    val config = data.readString() ?: ""
                    val debug = data.readInt() == 1
                    val tun = data.readFileDescriptor()
                    val protect = data.readStrongBinder()
                    try {
                        startCore(config, debug, tun, protect)
                        reply?.writeNoException()
                    } catch (t: Throwable) {
                        reply?.writeException(IllegalStateException(t.message ?: t.toString()))
                    } finally {
                        try {
                            tun.close()
                        } catch (_: Exception) {
                        }
                    }
                    return true
                }
                Ipc.CORE_STOP -> {
                    Process.killProcess(Process.myPid())
                    return true
                }
            }
            return super.onTransact(code, data, reply, flags)
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    private fun startCore(config: String, debug: Boolean, tun: ParcelFileDescriptor, protect: IBinder) {
        val home = File(filesDir, "mihomo").apply { mkdirs() }
        copyGeoFiles(home)
        Quietcore.start(home.absolutePath, config, tun.fd.toLong(), IpcProtector(protect), debug)
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
}

/**
 * Защита сокета выполняется в процессе службы VPN. Go присылает копию дескриптора,
 * мы передаём её через Binder и закрываем.
 */
class IpcProtector(private val target: IBinder) : Protector {
    override fun protect(fd: Long): Boolean {
        val pfd = ParcelFileDescriptor.adoptFd(fd.toInt()) // владеем копией и закроем её
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(Ipc.DESCRIPTOR)
            data.writeFileDescriptor(pfd.fileDescriptor)
            target.transact(Ipc.PROTECT, data, reply, 0)
            reply.readException()
            reply.readInt() == 1
        } catch (_: Exception) {
            false
        } finally {
            try {
                pfd.close()
            } catch (_: Exception) {
            }
            data.recycle()
            reply.recycle()
        }
    }
}
