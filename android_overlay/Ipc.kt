package dev.quiet.quiet_vpn

import android.os.IBinder

/** Коды обращений между процессами: служба VPN (:vpn) и ядро (:core). */
object Ipc {
    const val DESCRIPTOR = "dev.quiet.quiet_vpn.IPC"

    // К ядру (CoreService)
    const val CORE_START = IBinder.FIRST_CALL_TRANSACTION
    const val CORE_STOP = IBinder.FIRST_CALL_TRANSACTION + 1

    // К службе VPN (защита сокета от попадания в туннель)
    const val PROTECT = IBinder.FIRST_CALL_TRANSACTION
}
