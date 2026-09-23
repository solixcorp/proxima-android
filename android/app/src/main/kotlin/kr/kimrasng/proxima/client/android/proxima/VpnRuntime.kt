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
    val activeNode: String? = null,
    val activeMode: String? = null,
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
        "activeNode" to activeNode,
        "activeMode" to activeMode,
        "error" to error,
    )
}

object VpnRuntime {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()

    @Volatile
    private var current = NativeVpnSnapshot()

    @Volatile
    private var probePorts: Map<String, Int> = emptyMap()

    @Volatile
    private var accessLogPath: String? = null

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

    fun reconnecting(profile: StoredProfile) = publish(
        current.copy(
            state = "connecting",
            profileId = profile.id,
            profileName = profile.name,
            uploadSpeed = 0,
            downloadSpeed = 0,
            error = null,
        ),
    )

    fun connected(
        profile: StoredProfile,
        activeNode: String?,
        activeMode: String,
        preserveSession: Boolean = false,
    ) = publish(
        if (preserveSession && current.startedAt > 0) {
            current.copy(
                state = "connected",
                profileId = profile.id,
                profileName = profile.name,
                uploadSpeed = 0,
                downloadSpeed = 0,
                activeNode = activeNode,
                activeMode = activeMode,
                error = null,
            )
        } else {
            NativeVpnSnapshot(
                state = "connected",
                profileId = profile.id,
                profileName = profile.name,
                startedAt = System.currentTimeMillis(),
                activeNode = activeNode,
                activeMode = activeMode,
            )
        },
    )

    fun setProbePorts(value: Map<String, Int>) {
        probePorts = value.toMap()
    }

    fun probePort(node: String): Int? = probePorts[node]

    fun clearProbePorts() {
        probePorts = emptyMap()
    }

    fun setAccessLogPath(path: String?) {
        accessLogPath = path
    }

    fun accessLogPath(): String? = accessLogPath

    fun disconnecting() = publish(current.copy(state = "disconnecting", error = null))

    fun disconnected() {
        clearProbePorts()
        setAccessLogPath(null)
        publish(NativeVpnSnapshot())
    }

    fun failed(profile: StoredProfile?, message: String) {
        clearProbePorts()
        setAccessLogPath(null)
        publish(NativeVpnSnapshot(
            state = "error",
            profileId = profile?.id,
            profileName = profile?.name,
            error = message,
        ))
    }

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
