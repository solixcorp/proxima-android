package kr.kimrasng.proxima.client.android.proxima

/**
 * One owner-initiated handshake with the explicitly bound worker service.
 * callingUid/callingPid must come from Binder's incoming transaction context,
 * never from the Parcel. The service binding authenticates the endpoint; this
 * handshake captures its process identity before exposing a protector.
 */
internal class MihomoWorkerHandshake<I : Any>(
    private val generation: Long,
    private val identity: I,
    private val expectedUid: Int,
    private val ownerPid: Int,
) {
    private var closed = false
    private var workerPid: Int? = null

    @Synchronized
    fun acknowledge(generation: Long, identity: I?, callingUid: Int, callingPid: Int): Boolean {
        if (closed || workerPid != null || generation != this.generation ||
            identity != this.identity || callingUid != expectedUid ||
            callingPid <= 0 || callingPid == ownerPid
        ) {
            return false
        }
        workerPid = callingPid
        return true
    }

    @Synchronized
    fun finish(): Int {
        check(!closed) { "Mihomo handshake already closed" }
        closed = true
        return checkNotNull(workerPid) { "Mihomo worker did not acknowledge its handshake" }
    }

    @Synchronized
    fun abort() {
        closed = true
    }
}
