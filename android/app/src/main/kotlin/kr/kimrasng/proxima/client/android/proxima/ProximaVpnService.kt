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
import android.os.ParcelFileDescriptor
import io.github.oviron.libmihomo.Clash
import io.github.oviron.libmihomo.TunInterface
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import android.net.VpnService as AndroidVpnService

class ProximaVpnService : AndroidVpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private val trafficScheduler = Executors.newSingleThreadScheduledExecutor()
    private val generation = AtomicInteger(0)
    private val packageCache = mutableMapOf<Int, String>()
    private var trafficTask: ScheduledFuture<*>? = null
    private var runningProfile: StoredProfile? = null
    private var stopping = false

    private val tunBridge = object : TunInterface {
        override fun protect(fd: Int) {
            this@ProximaVpnService.protect(fd)
        }

        override fun resolverProcess(protocol: Int, source: String, target: String, uid: Int): String =
            resolveProcess(protocol, source, target, uid)
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        runCatching { MihomoCore.ensureLoaded(this) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val profileId = intent.getStringExtra(EXTRA_PROFILE_ID)
                if (profileId == null) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForeground(NOTIFICATION_ID, notification("보안 터널 준비 중"))
                beginConnection(profileId)
            }
            ACTION_STOP -> disconnectAndStop()
            else -> if (VpnRuntime.snapshot()["state"] == "disconnected") stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun beginConnection(profileId: String) {
        val repository = ProfileRepository(this)
        val profile = repository.profile(profileId)
        if (profile == null) {
            fail(null, "선택한 프로필을 찾을 수 없습니다.")
            return
        }
        val token = generation.incrementAndGet()
        stopping = false
        runningProfile = profile
        VpnRuntime.connecting(profile)
        updateNotification("${profile.name} · 연결 중")
        worker.execute {
            runCatching {
                disconnectCore()
                prepareCore(repository.readContent(profileId))
            }.onFailure { error -> fail(profile, readableError(error)) }
                .onSuccess { quickSetup(profile, token) }
        }
    }

    private fun prepareCore(profileContent: String) {
        MihomoCore.ensureLoaded(this)
        val home = File(filesDir, "mihomo").apply { mkdirs() }
        val destination = File(home, "config.yaml")
        val temporary = File(home, ".config.yaml.tmp")
        temporary.writeText(ProfileNormalizer.forAndroidVpn(profileContent), Charsets.UTF_8)
        if (!temporary.renameTo(destination)) {
            temporary.copyTo(destination, overwrite = true)
            temporary.delete()
        }
    }

    private fun quickSetup(profile: StoredProfile, token: Int) {
        val home = File(filesDir, "mihomo")
        val init = JSONObject()
            .put("home-dir", home.absolutePath)
            .put("version", Build.VERSION.SDK_INT)
        val setup = JSONObject().put("selected-map", JSONObject())
        Clash.quickSetup(init.toString(), setup.toString()) { error ->
            worker.execute {
                if (token != generation.get() || stopping) return@execute
                if (!error.isNullOrEmpty()) {
                    fail(profile, error)
                    return@execute
                }
                applyOutboundMode(profile, token)
            }
        }
    }

    private fun applyOutboundMode(profile: StoredProfile, token: Int) {
        val settings = VpnSettingsRepository(this).load()
        MihomoCore.invoke("updateConfig", JSONObject().put("mode", settings.mode).toString()) { payload ->
            worker.execute {
                if (token != generation.get() || stopping) return@execute
                runCatching {
                    val response = JSONObject(payload)
                    require(response.optInt("code", -1) == 0) {
                        response.opt("data")?.toString().orEmpty().ifBlank { "작동 모드를 적용하지 못했습니다." }
                    }
                    establishTunnel(profile, token, settings)
                }.onFailure { failure -> fail(profile, readableError(failure)) }
            }
        }
    }

    private fun establishTunnel(profile: StoredProfile, token: Int, settings: NativeVpnSettings) {
        val systemDns = currentSystemDns()
        if (systemDns.isNotEmpty()) Clash.updateDNS(systemDns.joinToString(","))

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
            }
            .establish()
            ?: error("Android가 VPN 인터페이스 생성을 거부했습니다.")

        if (token != generation.get() || stopping) {
            descriptor.close()
            return
        }
        val fd = descriptor.detachFd()
        descriptor.close()
        Clash.startTUN(
            fd = fd,
            cb = tunBridge,
            device = "proxima",
            stack = settings.stack,
            address = if (settings.ipv6) "$IPV4_CIDR,$IPV6_CIDR" else IPV4_CIDR,
            dns = if (settings.ipv6) "0.0.0.0,::" else "0.0.0.0",
            mtu = settings.mtu,
        )
        if (token != generation.get() || stopping) {
            Clash.stopTun()
            return
        }
        VpnRuntime.connected(profile)
        updateNotification("${profile.name} · 보호됨")
        startTrafficUpdates(token)
    }

    private fun currentSystemDns(): List<String> {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivity.activeNetwork ?: return emptyList()
        return connectivity.getLinkProperties(network)?.dnsServers?.map(InetAddress::getHostAddress) ?: emptyList()
    }

    private fun startTrafficUpdates(token: Int) {
        trafficTask?.cancel(false)
        trafficTask = trafficScheduler.scheduleAtFixedRate({
            if (token != generation.get() || !Clash.isLoaded()) return@scheduleAtFixedRate
            runCatching {
                val speed = JSONObject(Clash.getTraffic())
                val total = JSONObject(Clash.getTotalTraffic())
                VpnRuntime.traffic(
                    speed.optLong("up"),
                    speed.optLong("down"),
                    total.optLong("up"),
                    total.optLong("down"),
                )
            }
        }, 0, 1, TimeUnit.SECONDS)
    }

    private fun disconnectAndStop() {
        if (stopping) return
        stopping = true
        generation.incrementAndGet()
        VpnRuntime.disconnecting()
        updateNotification("연결 해제 중")
        worker.execute {
            disconnectCore()
            VpnRuntime.disconnected()
            runningProfile = null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
        }
    }

    private fun disconnectCore() {
        trafficTask?.cancel(false)
        trafficTask = null
        if (Clash.isLoaded()) runCatching { Clash.stopTun() }
    }

    private fun fail(profile: StoredProfile?, message: String) {
        generation.incrementAndGet()
        disconnectCore()
        VpnRuntime.failed(profile, message)
        updateNotification("연결 오류")
        runningProfile = profile
        stopping = false
    }

    private fun resolveProcess(protocol: Int, source: String, target: String, uid: Int): String {
        val resolvedUid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching {
                val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                connectivity.getConnectionOwnerUid(protocol, parseSocketAddress(source), parseSocketAddress(target))
            }.getOrDefault(-1)
        } else {
            uid
        }
        if (resolvedUid < 0) return ""
        val packageName = synchronized(packageCache) {
            packageCache.getOrPut(resolvedUid) {
                runCatching { packageManager.getPackagesForUid(resolvedUid)?.firstOrNull().orEmpty() }.getOrDefault("")
            }
        }
        return "$resolvedUid\n$packageName"
    }

    private fun parseSocketAddress(value: String): InetSocketAddress {
        val url = URL("https://$value")
        return InetSocketAddress(InetAddress.getByName(url.host), url.port)
    }

    override fun onRevoke() {
        disconnectAndStop()
        super.onRevoke()
    }

    override fun onLowMemory() {
        if (Clash.isLoaded()) Clash.forceGC()
        super.onLowMemory()
    }

    override fun onDestroy() {
        generation.incrementAndGet()
        trafficTask?.cancel(false)
        trafficScheduler.shutdownNow()
        disconnectCore()
        worker.shutdownNow()
        if (VpnRuntime.snapshot()["state"] != "error") VpnRuntime.disconnected()
        super.onDestroy()
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent)

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "VPN 연결", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Proxima 보안 터널 상태"
                setShowBadge(false)
            },
        )
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ProximaVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_proxima)
            .setContentTitle("Proxima VPN")
            .setContentText(text)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "연결 해제", stopIntent).build())
            .build()
    }

    private fun readableError(error: Throwable): String {
        if (error is PackageManager.NameNotFoundException) return "앱 정보를 확인하지 못했습니다."
        return error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
    }

    companion object {
        const val ACTION_START = "kr.kimrasng.proxima.action.START"
        const val ACTION_STOP = "kr.kimrasng.proxima.action.STOP"
        const val EXTRA_PROFILE_ID = "profile_id"
        private const val CHANNEL_ID = "proxima_vpn"
        private const val NOTIFICATION_ID = 4301
        private const val IPV4_ADDRESS = "172.19.0.1"
        private const val IPV4_PREFIX = 30
        private const val IPV4_CIDR = "$IPV4_ADDRESS/$IPV4_PREFIX"
        private const val IPV4_DNS = "172.19.0.2"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1"
        private const val IPV6_PREFIX = 126
        private const val IPV6_CIDR = "$IPV6_ADDRESS/$IPV6_PREFIX"
        private const val IPV6_DNS = "fdfe:dcba:9876::2"
    }
}
