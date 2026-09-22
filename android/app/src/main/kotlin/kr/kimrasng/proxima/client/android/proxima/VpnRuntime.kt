package kr.kimrasng.proxima.client.android.proxima

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArraySet

data class NativeVpnSnapshot(
    val state: String = "disconnected",
    val profileId: String? = null,
    val profileName: String? = null,
    val startedAt: Long = 0,
    val uploadSpeed: Long = 0,
    val downloadSpeed: Long = 0,
    val totalUpload: Long = 0,
    val totalDownload: Long = 0,
    val error: String? = null,
) {
    fun asMap(): Map<String, Any?> = mapOf(
        "state" to state,
        "profileId" to profileId,
        "profileName" to profileName,
        "startedAt" to startedAt,
        "uploadSpeed" to uploadSpeed,
        "downloadSpeed" to downloadSpeed,
        "totalUpload" to totalUpload,
        "totalDownload" to totalDownload,
        "error" to error,
    )
}

object VpnRuntime {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()

    @Volatile
    private var current = NativeVpnSnapshot()

    fun snapshot(): Map<String, Any?> = current.asMap()

    fun addListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.add(listener)
        mainHandler.post { listener(current.asMap()) }
    }

    fun removeListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    fun connecting(profile: StoredProfile) = publish(
        NativeVpnSnapshot(state = "connecting", profileId = profile.id, profileName = profile.name),
    )

    fun connected(profile: StoredProfile) = publish(
        NativeVpnSnapshot(
            state = "connected",
            profileId = profile.id,
            profileName = profile.name,
            startedAt = System.currentTimeMillis(),
        ),
    )

    fun disconnecting() = publish(current.copy(state = "disconnecting", error = null))

    fun disconnected() = publish(NativeVpnSnapshot())

    fun failed(profile: StoredProfile?, message: String) = publish(
        NativeVpnSnapshot(
            state = "error",
            profileId = profile?.id,
            profileName = profile?.name,
            error = message,
        ),
    )

    fun traffic(up: Long, down: Long, totalUp: Long, totalDown: Long) {
        if (current.state != "connected") return
        publish(
            current.copy(
                uploadSpeed = up.coerceAtLeast(0),
                downloadSpeed = down.coerceAtLeast(0),
                totalUpload = totalUp.coerceAtLeast(0),
                totalDownload = totalDown.coerceAtLeast(0),
            ),
        )
    }

    private fun publish(snapshot: NativeVpnSnapshot) {
        current = snapshot
        val value = snapshot.asMap()
        mainHandler.post { listeners.forEach { listener -> listener(value) } }
    }
}
