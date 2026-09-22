package kr.kimrasng.proxima.client.android.proxima

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import android.os.IBinder
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import libXray.DialerController
import android.net.VpnService as AndroidVpnService

class ProximaVpnService : AndroidVpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger(0)
    private var runningProfile: StoredProfile? = null
    private var stopping = false

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
        val token = generation.incrementAndGet()
        stopping = false
        runningProfile = profile
        VpnRuntime.connecting(profile)
        startForeground(NOTIFICATION_ID, notification("${profile.name} · 연결 중"))
        worker.execute {
            runCatching {
                XrayCore.stop()
                establishTunnel(profile, repository.readContent(profileId), token)
            }.onFailure { fail(profile, readableError(it)) }
        }
    }

    private fun establishTunnel(profile: StoredProfile, content: String, token: Int) {
        val settings = VpnSettingsRepository(this).load()
        val descriptor = Builder()
            .setSession("Proxima")
            .setMtu(settings.mtu)
            .addAddress(IPV4_ADDRESS, IPV4_PREFIX)
            .addRoute("0.0.0.0", 0)
            .addDnsServer(IPV4_DNS)
            .apply {
                if (settings.ipv6) {
                    addAddress(IPV6_ADDRESS, IPV6_PREFIX)
                    addRoute("::", 0)
                    addDnsServer(IPV6_DNS)
                }
                setBlocking(false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) setMetered(false)
            }.establish() ?: error("Android가 VPN 인터페이스 생성을 거부했습니다.")
        if (token != generation.get() || stopping) {
            descriptor.close()
            return
        }
        val fd = descriptor.detachFd()
        descriptor.close()
        XrayConfig.VpnSettingsRepositoryHolder.selected = { id -> VpnSettingsRepository(this).selectedProxies(id) }
        val dns = currentSystemDns().firstOrNull()?.let { "$it:53" }
        XrayCore.configureVpn(socketController, dns)
        XrayCore.run(XrayConfig.build(profile, content, settings, fd))
        if (token != generation.get() || stopping) {
            XrayCore.stop()
            return
        }
        VpnRuntime.connected(profile)
        updateNotification("${profile.name} · 보호됨")
    }

    private fun currentSystemDns(): List<String> {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return connectivity.activeNetwork?.let(connectivity::getLinkProperties)?.dnsServers
            ?.mapNotNull(InetAddress::getHostAddress).orEmpty()
    }

    private fun disconnectAndStop() {
        if (stopping) return
        stopping = true
        generation.incrementAndGet()
        VpnRuntime.disconnecting()
        updateNotification("연결 해제 중")
        worker.execute {
            XrayCore.stop()
            VpnRuntime.disconnected()
            runningProfile = null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
            else @Suppress("DEPRECATION") stopForeground(true)
            stopSelf()
        }
    }

    private fun fail(profile: StoredProfile?, message: String) {
        generation.incrementAndGet()
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
        XrayCore.stop()
        worker.shutdownNow()
        if (VpnRuntime.snapshot()["state"] != "error") VpnRuntime.disconnected()
        super.onDestroy()
    }
    override fun onBind(intent: Intent): IBinder? = super.onBind(intent)

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

    companion object {
        const val ACTION_START = "kr.kimrasng.proxima.action.START"
        const val ACTION_STOP = "kr.kimrasng.proxima.action.STOP"
        const val EXTRA_PROFILE_ID = "profile_id"
        private const val CHANNEL_ID = "proxima_vpn"
        private const val NOTIFICATION_ID = 4301
        private const val IPV4_ADDRESS = "172.19.0.1"
        private const val IPV4_PREFIX = 30
        private const val IPV4_DNS = "172.19.0.2"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1"
        private const val IPV6_PREFIX = 126
        private const val IPV6_DNS = "fdfe:dcba:9876::2"
    }
}
