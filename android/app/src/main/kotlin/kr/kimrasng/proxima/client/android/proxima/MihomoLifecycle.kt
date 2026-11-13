package kr.kimrasng.proxima.client.android.proxima

import java.util.concurrent.CountDownLatch

/** Signaled only by registered Binder death (or a binding that granted no lease). */
internal class MihomoRetirementFence {
    private val death = CountDownLatch(1)
    fun observedDeath() = death.countDown()
    fun awaitRetired() = death.await()
}

/** Never use finally here: an unjoined/failed retirement must retain the original fd. */
internal fun closeMihomoTunnel(stopAndJoin: () -> Unit, closeOriginal: () -> Unit) {
    stopAndJoin()
    closeOriginal()
}
