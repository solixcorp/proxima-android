package kr.kimrasng.proxima.client.android.proxima

import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.io.Closeable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/** Off-main lifecycle coordinator; only Binding itself touches Android binding. */
class MihomoVpnSession(private val vpn: VpnService, private val onDeath: () -> Unit) : Closeable {
    private val main = Handler(Looper.getMainLooper())
    private val closing = AtomicBoolean(false)
    private val attached = CompletableFuture<MihomoWorkerBoundary.Connection>()
    private val requested = CompletableFuture<MihomoWorkerBoundary.Binding?>()
    @Volatile private var connection: MihomoWorkerBoundary.Connection? = null
    @Volatile var node: String? = null
        private set

    fun start(tun: ParcelFileDescriptor, config: MihomoProfileAssembler.Result) {
        check(Looper.myLooper() != Looper.getMainLooper())
        main.post {
            if (closing.get()) {
                requested.complete(null)
            } else {
                runCatching {
                    MihomoWorkerBoundary.bind(vpn,
                        onConnected = { remote ->
                            connection = remote
                            attached.complete(remote)
                        },
                        onWorkerDeath = {
                            attached.completeExceptionally(IllegalStateException("Mihomo worker died"))
                            if (!closing.get()) onDeath()
                        },
                        onFailure = { error ->
                            attached.completeExceptionally(error)
                            if (!closing.get()) onDeath()
                        },
                    )
                }.onSuccess { requested.complete(it) }
                    .onFailure { requested.complete(null); attached.completeExceptionally(it) }
            }
        }
        val remote = try {
            attached.get(10, TimeUnit.SECONDS)
        } catch (error: Exception) {
            throw IllegalStateException("Mihomo worker bind/handshake failed: ${error.cause?.message ?: error.message}", error)
        }
        check(!closing.get()) { "Mihomo startup cancelled" }
        remote.start(tun, MihomoConfiguration.copyOf(config.yaml.toByteArray(Charsets.UTF_8)))
        node = config.node
    }

    private fun active(): MihomoWorkerBoundary.Connection {
        check(!closing.get()) { "Mihomo session is stopping" }
        return checkNotNull(connection) { "Mihomo session is not connected" }
    }

    fun trafficStats(): LongArray = active().trafficStats()
    fun delayTest(name: String, url: String, timeout: Int): Int = active().delayTest(name, url, timeout)

    fun connections(): JSONObject {
        val source = JSONArray(String(active().connectionsSnapshot(), Charsets.UTF_8))
        val rows = JSONArray()
        for (i in 0 until source.length()) {
            val row = source.getJSONObject(i)
            rows.put(JSONObject(row.toString()).put("metadata", JSONObject()
                .put("host", row.optString("host"))
                .put("network", row.optString("network"))
                .put("type", "Mihomo tracker")))
        }
        val snapshot = VpnRuntime.snapshot()
        return JSONObject().put("uploadTotal", snapshot["totalUpload"] ?: 0)
            .put("downloadTotal", snapshot["totalDownload"] ?: 0).put("connections", rows)
    }

    fun proxyState(): JSONObject {
        val name = checkNotNull(node)
        val proxies = JSONObject().put(name, JSONObject().put("type", "Vless"))
        for (group in listOf("GLOBAL", "PROXY")) proxies.put(group,
            JSONObject().put("type", "Selector").put("now", name).put("all", JSONArray(listOf(name))))
        return JSONObject().put("proxies", proxies)
    }

    /** Revoke/unbind before Service.onDestroy returns; joining stays off-main. */
    fun requestRetirementOnMain() {
        check(Looper.myLooper() == Looper.getMainLooper())
        closing.set(true)
        val binding = requested.getNow(null)
        if (binding != null) binding.close() else requested.complete(null)
        attached.completeExceptionally(IllegalStateException("Mihomo startup cancelled"))
    }

    /** No timeout can certify lease release. Caller closes original TUN AFTER this returns. */
    override fun close() {
        check(Looper.myLooper() != Looper.getMainLooper())
        closing.set(true)
        val binding = requested.get() ?: return
        val revoked = CompletableFuture<Unit>()
        main.post {
            runCatching { binding.close() }
                .onSuccess { revoked.complete(Unit) }.onFailure { revoked.completeExceptionally(it) }
        }
        revoked.get()
        binding.awaitRetired()
    }
}
