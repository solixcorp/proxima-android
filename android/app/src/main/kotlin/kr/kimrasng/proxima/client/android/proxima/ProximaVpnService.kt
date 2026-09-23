package kr.kimrasng.proxima.client.android.proxima

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import java.io.File
import java.net.InetAddress
import java.net.Inet4Address
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import libXray.DialerController
import org.json.JSONObject
import android.net.VpnService as AndroidVpnService

class ProximaVpnService : AndroidVpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val trafficScheduler = Executors.newSingleThreadScheduledExecutor()
    private val generation = AtomicInteger(0)
    private var trafficTask: ScheduledFuture<*>? = null
    private var runningProfile: StoredProfile? = null
    private var stopping = false
    private val tunnelLock = Any()

    // `ParcelFileDescriptor.detachFd()` transfers ownership to us. Keep that
    // ownership explicitly: an Xray stop alone does not guarantee Android
    // tears down the VPN interface and its system-level VPN indicator.
    @Volatile
    private var tunnelFd: Int? = null

    private val socketController = object : DialerController {
        override fun protectFd(fd: Long): Boolean = this@ProximaVpnService.protect(fd.toInt())
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        runCatching { XrayCore.ensureLoaded() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> intent.getStringExtra(EXTRA_PROFILE_ID)?.let(::beginConnection) ?: stopSelf()
            ACTION_STOP -> disconnectAndStop()
            else -> if (VpnRuntime.snapshot()["state"] == "disconnected") stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun beginConnection(profileId: String) {
        val repository = ProfileRepository(this)
        val profile = repository.profile(profileId) ?: run {
            fail(null, "선택한 프로필을 찾을 수 없습니다.")
            return
        }
        val current = VpnRuntime.snapshot()
        val preserveSession = current["profileId"] == profile.id &&
            current["state"] in setOf("connected", "connecting") &&
            (current["startedAt"] as? Long ?: 0L) > 0L
        val token = generation.incrementAndGet()
        stopping = false
        runningProfile = profile
        trafficTask?.cancel(false)
        trafficTask = null
        if (preserveSession) VpnRuntime.reconnecting(profile) else VpnRuntime.connecting(profile)
        startForeground(NOTIFICATION_ID, notification("${profile.name} · 연결 중"))
        worker.execute {
            runCatching {
                closeTunnel()
                XrayCore.stop()
                establishTunnel(profile, repository.readContent(profileId), token, preserveSession)
            }.onFailure {
                if (token == generation.get() && !stopping) {
                    fail(profile, readableError(it), token)
                }
            }
        }
    }

    private fun establishTunnel(
        profile: StoredProfile,
        content: String,
        token: Int,
        preserveSession: Boolean,
    ) {
        val settings = VpnSettingsRepository(this).load()
        // Capture the resolver before establishing the VPN. Afterwards Android
        // may report this VPN's own DNS server as the active network resolver.
        val underlying = currentUnderlyingNetwork()
        val systemDns = underlying.linkProperties?.dnsServers
            ?.mapNotNull(InetAddress::getHostAddress)
            .orEmpty()
        val upstreamDns = systemDns.firstOrNull { '.' in it }
            ?: systemDns.firstOrNull()
            ?: IPV4_DNS
        val descriptor = Builder()
            .setSession("Proxima")
            .setMtu(settings.mtu)
            .addAddress(IPV4_ADDRESS, IPV4_PREFIX)
            .addRoute("0.0.0.0", 0)
            // Use the resolver from the physical network. Some mobile/Wi-Fi
            // networks block public UDP DNS such as 1.1.1.1 even though their
            // own resolver works. Xray routes this DNS traffic through the
            // protected direct outbound before proxying application traffic.
            .addDnsServer(upstreamDns)
            .apply {
                if (settings.ipv6) {
                    addAddress(IPV6_ADDRESS, IPV6_PREFIX)
                    addRoute("::", 0)
                }
                setBlocking(false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) setMetered(false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    LOCAL_BYPASS_ROUTES
                        .filter { settings.ipv6 || ':' !in it }
                        .forEach { route ->
                            excludeRoute(ipPrefix(route))
                        }
                    underlying.linkProperties?.linkAddresses
                        ?.filter { settings.ipv6 || it.address is Inet4Address }
                        ?.forEach { address ->
                            excludeRoute(IpPrefix(address.address, address.prefixLength))
                        }
                }
            }.establish() ?: error("Android가 VPN 인터페이스 생성을 거부했습니다.")
        if (token != generation.get() || stopping) {
            descriptor.close()
            return
        }
        val fd = descriptor.detachFd()
        synchronized(tunnelLock) { tunnelFd = fd }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            setUnderlyingNetworks(underlying.network?.let { arrayOf(it) })
        }
        XrayConfig.VpnSettingsRepositoryHolder.selected = { id -> VpnSettingsRepository(this).selectedProxies(id) }
        XrayCore.configureVpn(socketController, dnsEndpoint(upstreamDns))
        val nodeNames = XrayConfig.nodeNames(profile, content)
        val ports = XrayCore.freePorts(nodeNames.size + 1)
        val metricsPort = ports.first()
        val probePorts = nodeNames.zip(ports.drop(1)).toMap()
        val accessLog = File(filesDir, "xray-access.log").apply { writeText("") }
        val runtimeConfig = XrayConfig.build(
            profile = profile,
            content = content,
            settings = settings,
            tunFd = fd,
            metricsPort = metricsPort,
            probePorts = probePorts,
            accessLogPath = accessLog.absolutePath,
        )
        XrayCore.run(runtimeConfig.json)
        check(XrayCore.isRunning()) { "Xray 코어가 시작되지 않았습니다." }
        if (token != generation.get() || stopping) {
            XrayCore.stop()
            closeTunnel()
            return
        }
        VpnRuntime.setProbePorts(runtimeConfig.probePorts)
        VpnRuntime.setAccessLogPath(accessLog.absolutePath)
        VpnRuntime.connected(
            profile = profile,
            activeNode = runtimeConfig.activeNode,
            activeMode = settings.mode,
            preserveSession = preserveSession,
        )
        updateNotification("${profile.name} · 보호됨")
        startTrafficUpdates(token, preserveSession, metricsPort)
    }

    private fun startTrafficUpdates(token: Int, preserveSession: Boolean, metricsPort: Int) {
        trafficTask?.cancel(false)
        val current = VpnRuntime.snapshot()
        val uploadOffset = if (preserveSession) (current["totalUpload"] as? Number)?.toLong() ?: 0L else 0L
        val downloadOffset = if (preserveSession) (current["totalDownload"] as? Number)?.toLong() ?: 0L else 0L
        var previousUpload = 0L
        var previousDownload = 0L
        var samples = 0
        trafficTask = trafficScheduler.scheduleAtFixedRate({
            if (token != generation.get() || stopping) return@scheduleAtFixedRate
            runCatching { readXrayTraffic(metricsPort) }.onSuccess { counters ->
                val uploadSpeed = (counters.upload - previousUpload).coerceAtLeast(0)
                val downloadSpeed = (counters.download - previousDownload).coerceAtLeast(0)
                previousUpload = counters.upload
                previousDownload = counters.download
                VpnRuntime.traffic(
                    up = uploadSpeed,
                    down = downloadSpeed,
                    totalUp = uploadOffset + counters.upload,
                    totalDown = downloadOffset + counters.download,
                )
            }
            samples++
            if (samples % 5 == 0 && !runCatching { XrayCore.isRunning() }.getOrDefault(false)) {
                worker.execute {
                    if (token == generation.get() && !stopping) {
                        fail(runningProfile, "Xray 코어가 예기치 않게 종료되었습니다.", token)
                    }
                }
            }
        }, 1, 1, TimeUnit.SECONDS)
    }

    private data class TrafficCounters(val upload: Long, val download: Long)

    private fun readXrayTraffic(port: Int): TrafficCounters {
        val connection = URL("http://127.0.0.1:$port/debug/vars").openConnection() as HttpURLConnection
        connection.connectTimeout = 750
        connection.readTimeout = 750
        return try {
            val payload = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val inbound = JSONObject(payload)
                .optJSONObject("stats")
                ?.optJSONObject("inbound")
                ?.optJSONObject("proxima-tun")
            TrafficCounters(
                upload = inbound?.optLong("uplink", 0L) ?: 0L,
                download = inbound?.optLong("downlink", 0L) ?: 0L,
            )
        } finally {
            connection.disconnect()
        }
    }

    private data class UnderlyingNetwork(
        val network: Network?,
        val linkProperties: LinkProperties?,
    )

    private fun currentUnderlyingNetwork(): UnderlyingNetwork {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val candidates = buildList {
            connectivity.activeNetwork?.let(::add)
            connectivity.allNetworks.forEach { network ->
                if (network !in this) add(network)
            }
        }
        val network = candidates.firstOrNull { candidate ->
            val capabilities = connectivity.getNetworkCapabilities(candidate)
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) != true &&
                capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        }
        return UnderlyingNetwork(network, network?.let(connectivity::getLinkProperties))
    }

    private fun disconnectAndStop() {
        if (stopping) return
        stopping = true
        generation.incrementAndGet()
        VpnRuntime.disconnecting()
        updateNotification("연결 해제 중")
        trafficTask?.cancel(false)
        trafficTask = null
        worker.execute {
            // Closing the TUN descriptor first is what tells Android that this
            // VPN has ended. Do it even if the native core shutdown is slow.
            closeTunnel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                setUnderlyingNetworks(null)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
            else @Suppress("DEPRECATION") stopForeground(true)
            XrayCore.stop()
            VpnRuntime.disconnected()
            runningProfile = null
            stopSelf()
        }
    }

    private fun fail(profile: StoredProfile?, message: String, token: Int? = null) {
        if (token != null && !generation.compareAndSet(token, token + 1)) return
        if (token == null) generation.incrementAndGet()
        trafficTask?.cancel(false)
        trafficTask = null
        closeTunnel()
        XrayCore.stop()
        VpnRuntime.failed(profile, message)
        updateNotification("연결 오류")
        runningProfile = profile
        stopping = false
    }

    override fun onRevoke() { disconnectAndStop(); super.onRevoke() }
    override fun onLowMemory() { super.onLowMemory() }
    override fun onDestroy() {
        generation.incrementAndGet()
        trafficTask?.cancel(false)
        trafficTask = null
        trafficScheduler.shutdownNow()
        closeTunnel()
        XrayCore.stop()
        worker.shutdownNow()
        if (VpnRuntime.snapshot()["state"] != "error") VpnRuntime.disconnected()
        super.onDestroy()
    }
    override fun onBind(intent: Intent): IBinder? = super.onBind(intent)

    private fun closeTunnel() {
        val fd = synchronized(tunnelLock) {
            val current = tunnelFd
            tunnelFd = null
            current
        } ?: return
        runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "VPN 연결", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
        )
    }
    private fun updateNotification(text: String) { (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification(text)) }
    private fun notification(text: String): Notification {
        val openIntent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stopIntent = PendingIntent.getService(this, 1, Intent(this, ProximaVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder.setSmallIcon(R.drawable.ic_stat_proxima).setContentTitle("Proxima VPN").setContentText(text)
            .setContentIntent(openIntent).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "연결 해제", stopIntent).build()).build()
    }
    private fun readableError(error: Throwable): String = if (error is PackageManager.NameNotFoundException) "앱 정보를 확인하지 못했습니다." else error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
    private fun dnsEndpoint(address: String): String = if (':' in address) "[$address]:53" else "$address:53"
    private fun ipPrefix(value: String): IpPrefix {
        val address = value.substringBefore('/')
        val prefixLength = value.substringAfter('/').toInt()
        return IpPrefix(InetAddress.getByName(address), prefixLength)
    }

    companion object {
        const val ACTION_START = "kr.kimrasng.proxima.action.START"
        const val ACTION_STOP = "kr.kimrasng.proxima.action.STOP"
        const val EXTRA_PROFILE_ID = "profile_id"
        private const val CHANNEL_ID = "proxima_vpn"
        private const val NOTIFICATION_ID = 4301
        private const val IPV4_ADDRESS = "172.19.0.1"
        private const val IPV4_PREFIX = 30
        private const val IPV4_DNS = "1.1.1.1"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1"
        private const val IPV6_PREFIX = 126
        private val LOCAL_BYPASS_ROUTES = listOf(
            "169.254.0.0/16",
            "224.0.0.0/4",
            "fe80::/10",
            "ff00::/8",
        )
    }
}
