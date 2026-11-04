package dev.quiet.quiet_vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/** DNS-серверы активной физической сети; VPN-сеть и loopback намеренно исключены. */
fun localDnsServers(context: Context): List<String> {
    val manager = context.getSystemService(ConnectivityManager::class.java)
    val active = manager.activeNetwork
    val networks = buildList {
        if (active != null) add(active)
        addAll(manager.allNetworks.filter { it != active })
    }

    for (network in networks) {
        val capabilities = manager.getNetworkCapabilities(network) ?: continue
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        ) continue

        val servers = manager.getLinkProperties(network)?.dnsServers
            ?.filterNot {
                it.isAnyLocalAddress ||
                    it.isLoopbackAddress ||
                    it.isMulticastAddress ||
                    it.isLinkLocalAddress
            }
            ?.map { it.hostAddress?.substringBefore('%') ?: "" }
            ?.filter { it.isNotEmpty() }
            ?.distinct()
            .orEmpty()
        if (servers.isNotEmpty()) return servers
    }
    throw IllegalStateException("В активной сети не найден локальный DNS-резолвер")
}
