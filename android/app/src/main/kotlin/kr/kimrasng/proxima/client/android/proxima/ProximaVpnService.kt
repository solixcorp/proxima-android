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
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import android.net.VpnService as AndroidVpnService

class ProximaVpnService : AndroidVpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val trafficScheduler = Executors.newSingleThreadScheduledExecutor()
    private val generation = AtomicInteger(0)
    private var trafficTask: ScheduledFuture<*>? = null
    private var stopping = false
    private val tunnelLock = Any()
    @Volatile private var mihomoSession: MihomoVpnSession? = null
    @Volatile private var destroyed = false

    // `ParcelFileDescriptor.detachFd()` transfers ownership to us. Keep that
    // ownership explicitly so cleanup tears down the Android VPN interface.
    @Volatile
    private var tunnelFd: Int? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> intent.getStringExtra(EXTRA_PROFILE_ID)?.let {
                beginConnection(it, intent.getStringExtra(EXTRA_MIHOMO_CONFIG))
            } ?: stopSelf()
            ACTION_STOP -> disconnectAndStop()
            else -> if (VpnRuntime.snapshot()["state"] == "disconnected") stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun beginConnection(profileId: String, mihomoConfigToken: String?) {
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
        trafficTask?.cancel(false)
        trafficTask = null
        if (preserveSession) VpnRuntime.reconnecting(profile) else VpnRuntime.connecting(profile)
        startForeground(NOTIFICATION_ID, notification("연결 중"))
        worker.execute {
            runCatching {
                stopCurrentEngine()
                if (token != generation.get() || stopping || destroyed) return@runCatching
                establishTunnel(profile, repository.readContent(profileId), token, preserveSession, mihomoConfigToken)
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
        mihomoConfigToken: String?,
    ) {
        val settings = VpnSettingsRepository(this).load()
        // One-use Dart snapshot only; no Kotlin projection or stale sidecar
        // fallback, including non-Flutter tile/widget/service entry points.
        val mihomoConfig = run {
            val bytes = MihomoConfigSidecar(File(filesDir, "mihomo-configs")).consume(
                mihomoConfigToken, profile.id, content,
                MihomoConfigSidecar.settingsKey(settings.mtu, settings.ipv6, settings.mode))
            MihomoRuntimeConfig(bytes, settings.mtu, settings.ipv6)
        }
        synchronized(tunnelLock) { if (destroyed) return }
        // Capture the underlying network before Android reports the VPN as active.
        val underlying = currentUnderlyingNetwork()
        val descriptor = Builder()
            .setSession(profile.name)
            .setMtu(settings.mtu)
            .addAddress(IPV4_ADDRESS, IPV4_PREFIX)
            .addRoute("0.0.0.0", 0)
            // Keep app DNS routed inside the shared TUN interface.
            .addDnsServer(VPN_DNS)
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
                // More specific than the private LAN exclusions: app DNS must
                // still reach the tunnel resolver, not the Wi-Fi router.
                addRoute(VPN_DNS, 32)
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
        establishMihomo(profile, mihomoConfig, settings, fd, token, preserveSession)
    }

    private fun establishMihomo(
        profile: StoredProfile, config: MihomoRuntimeConfig, settings: NativeVpnSettings,
        fd: Int, token: Int, preserveSession: Boolean,
    ) {
        val session = MihomoVpnSession(this) {
            // No auto-rebind/retry: only a new ACTION_START may create a worker.
            // Death can already be queued on main when onDestroy shuts down
            // this executor; destruction has its own joined cleanup task.
            if (!destroyed) worker.execute {
                if (token == generation.get() && !stopping && !destroyed) {
                    val retiredToken = generation.incrementAndGet()
                    trafficTask?.cancel(false)
                    trafficTask = null
                    stopCurrentEngine()
                    if (retiredToken != generation.get() || stopping || destroyed) return@execute
                    VpnRuntime.disconnected()
                    updateNotification("Mihomo 프로세스 종료 — 다시 연결해 주세요")
                }
            }
        }
        synchronized(tunnelLock) {
            if (destroyed || token != generation.get() || stopping) {
                closeTunnel()
                return
            }
            mihomoSession = session
        }
        // fromFd duplicates our original; Binder/worker/native own further
        // duplicates. The service's detached original is never transferred.
        ParcelFileDescriptor.fromFd(fd).use { session.start(it, config) }
        if (token != generation.get() || stopping || destroyed) {
            stopCurrentEngine()
            return
        }
        VpnRuntime.setMihomoSession(session)
        VpnRuntime.connected(profile, config.selected.takeUnless { settings.mode == "direct" }, settings.mode, preserveSession)
        updateNotification("보호됨")
        startMihomoTrafficUpdates(token, preserveSession, session)
    }

    private fun startMihomoTrafficUpdates(token: Int, preserveSession: Boolean, session: MihomoVpnSession) {
        val snapshot = VpnRuntime.snapshot()
        val offsetUp = if (preserveSession) (snapshot["totalUpload"] as? Number)?.toLong() ?: 0L else 0L
        val offsetDown = if (preserveSession) (snapshot["totalDownload"] as? Number)?.toLong() ?: 0L else 0L
        var up = 0L
        var down = 0L
        trafficTask = trafficScheduler.scheduleAtFixedRate({
            if (token != generation.get() || stopping || destroyed) return@scheduleAtFixedRate
            val counters = runCatching { session.trafficStats() }.getOrNull()
            if (token != generation.get() || stopping || destroyed) return@scheduleAtFixedRate
            val nextUp = counters?.get(0) ?: up
            val nextDown = counters?.get(1) ?: down
            VpnRuntime.traffic((nextUp - up).coerceAtLeast(0), (nextDown - down).coerceAtLeast(0),
                offsetUp + nextUp, offsetDown + nextDown)
            up = nextUp
            down = nextDown
            updateNotificationWithCurrentSnapshot()
            // Native worker independently supervises management admission; its
            // death event, not a transient RPC error, disconnects this session.
        }, 1, 1, TimeUnit.SECONDS)
    }

    private fun stopCurrentEngine() {
        VpnRuntime.setMihomoSession(null)
        // Request stop -> native join -> PID exit/Binder death -> original fd.
        closeMihomoTunnel(stopAndJoin = { mihomoSession?.close() }, closeOriginal = {
            mihomoSession = null
            closeTunnel()
        })
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
        val token = generation.incrementAndGet()
        VpnRuntime.disconnecting()
        updateNotification("연결 해제 중")
        trafficTask?.cancel(false)
        trafficTask = null
        worker.execute {
            stopCurrentEngine()
            if (token != generation.get()) return@execute
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                setUnderlyingNetworks(null)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
            else @Suppress("DEPRECATION") stopForeground(true)
            VpnRuntime.disconnected()
            stopSelf()
        }
    }

    private fun fail(profile: StoredProfile?, message: String, token: Int? = null) {
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            worker.execute { fail(profile, message, token) }
            return
        }
        if (token != null && !generation.compareAndSet(token, token + 1)) return
        val failedToken = if (token == null) generation.incrementAndGet() else token + 1
        trafficTask?.cancel(false)
        trafficTask = null
        stopCurrentEngine()
        if (failedToken != generation.get() || destroyed) return
        VpnRuntime.failed(profile, message)
        updateNotification("연결 오류")
        stopping = false
    }

    override fun onRevoke() { disconnectAndStop(); super.onRevoke() }
    override fun onLowMemory() { super.onLowMemory() }
    override fun onDestroy() {
        synchronized(tunnelLock) { destroyed = true }
        generation.incrementAndGet()
        trafficTask?.cancel(false)
        trafficTask = null
        trafficScheduler.shutdownNow()
        // Never block main: Binding.close must run there while this worker
        // joins process death. Do not interrupt the retirement fence.
        mihomoSession?.requestRetirementOnMain()
        worker.execute { stopCurrentEngine() }
        worker.shutdown()
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
    private fun updateNotification(text: String) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(
            NOTIFICATION_ID,
            notification(text)
        )
    }

    private fun updateNotificationWithCurrentSnapshot() {
        val snapshot = VpnRuntime.snapshot()
        val state = snapshot["state"]?.toString()
        if (state != "connected") return

        val startedAt = (snapshot["startedAt"] as? Number)?.toLong() ?: 0L
        val uploadSpeed = (snapshot["uploadSpeed"] as? Number)?.toLong() ?: 0L
        val downloadSpeed = (snapshot["downloadSpeed"] as? Number)?.toLong() ?: 0L

        val text = "↑ ${formatBytes(uploadSpeed)}  ↓ ${formatBytes(downloadSpeed)}  ·  ⏱ ${formatUptime(startedAt)}"

        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(
            NOTIFICATION_ID,
            notification(text)
        )
    }

    private fun notification(text: String): Notification {
        val title = VpnRuntime.snapshot()["profileName"]?.toString()?.takeIf { it.isNotEmpty() } ?: "VPN"
        val openIntent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stopIntent = PendingIntent.getService(this, 1, Intent(this, ProximaVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder.setSmallIcon(R.drawable.ic_stat_proxima)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "연결 해제", stopIntent).build())
            .build()
    }

    private fun formatBytes(bytesPerSec: Long): String {
        if (bytesPerSec <= 0) return "0 B/s"
        val k = 1024.0
        val sizes = arrayOf("B/s", "KB/s", "MB/s", "GB/s")
        val i = (Math.log(bytesPerSec.toDouble()) / Math.log(k)).toInt().coerceIn(0, 3)
        val value = bytesPerSec / Math.pow(k, i.toDouble())
        return String.format(java.util.Locale.US, "%.1f %s", value, sizes[i])
    }

    private fun formatUptime(startedAt: Long): String {
        if (startedAt <= 0) return "00:00:00"
        val elapsedSec = ((System.currentTimeMillis() - startedAt) / 1000).coerceAtLeast(0)
        val hours = elapsedSec / 3600
        val minutes = (elapsedSec % 3600) / 60
        val seconds = elapsedSec % 60
        return String.format(java.util.Locale.US, "%02d:%02d:%02d", hours, minutes, seconds)
    }
    private fun readableError(error: Throwable): String = if (error is PackageManager.NameNotFoundException) "앱 정보를 확인하지 못했습니다." else error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
    private fun ipPrefix(value: String): IpPrefix {
        val address = value.substringBefore('/')
        val prefixLength = value.substringAfter('/').toInt()
        return IpPrefix(InetAddress.getByName(address), prefixLength)
    }

    companion object {
        const val ACTION_START = "kr.kimrasng.proxima.action.START"
        const val ACTION_STOP = "kr.kimrasng.proxima.action.STOP"
        const val EXTRA_PROFILE_ID = "profile_id"
        const val EXTRA_MIHOMO_CONFIG = "mihomo_config_token"
        private const val CHANNEL_ID = "proxima_vpn"
        private const val NOTIFICATION_ID = 4301
        private const val IPV4_ADDRESS = "172.19.0.1"
        private const val IPV4_PREFIX = 30
        private const val VPN_DNS = "172.19.0.2"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1"
        private const val IPV6_PREFIX = 126
        private val LOCAL_BYPASS_ROUTES = listOf(
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "169.254.0.0/16",
            "fc00::/7",
            "fe80::/10",
            "224.0.0.0/4",
            "ff00::/8",
        )
    }
}
