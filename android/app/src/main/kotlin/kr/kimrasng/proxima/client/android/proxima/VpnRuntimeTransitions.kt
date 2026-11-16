package kr.kimrasng.proxima.client.android.proxima

/** Serializes generation changes with publication, not with slow engine work. */
internal class VpnGenerationGate {
    private var generation = 0

    @Synchronized fun get(): Int = generation
    @Synchronized fun incrementAndGet(): Int = ++generation
    @Synchronized fun compareAndSet(expected: Int, next: Int): Boolean {
        if (generation != expected) return false
        generation = next
        return true
    }

    @Synchronized fun ifCurrent(expected: Int, action: () -> Unit): Boolean {
        if (generation != expected) return false
        action()
        return true
    }
}

/** A queued transition may no longer describe the runtime when it is delivered. */
internal fun currentVpnEvent(event: Map<String, Any?>, current: Map<String, Any?>): Boolean =
    event["requestId"] == current["requestId"] &&
        event["state"] == current["state"] &&
        event["profileId"] == current["profileId"]
