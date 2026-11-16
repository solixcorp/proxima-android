package kr.kimrasng.proxima.client.android.proxima

import java.io.Closeable

/**
 * One occupied worker process at a time. Revocation never frees the slot:
 * only the death observer for the exact captured lease may do that.
 *
 * This class has no Android dependencies so its concurrency rules can be
 * tested on the host. Production owns one instance in MihomoWorkerBoundary.
 */
internal class MihomoLeaseGate<I : Any> {
    class Lease<I : Any> internal constructor(val generation: Long, val identity: I)

    private var sequence = 0L
    private var current: Lease<I>? = null
    private var active = false
    private var revoked = false

    @Synchronized
    fun isVacant(): Boolean = current == null

    @Synchronized
    fun reserve(identity: I): Lease<I> {
        check(current == null) { "Previous Mihomo worker has not died" }
        check(sequence < Long.MAX_VALUE) { "Mihomo generation exhausted" }
        return Lease(++sequence, identity).also {
            current = it
            active = false
            revoked = false
        }
    }

    @Synchronized
    fun activate(lease: Lease<I>): Boolean {
        if (current !== lease || revoked || active) return false
        active = true
        return true
    }

    @Synchronized
    fun isActive(lease: Lease<I>): Boolean = current === lease && active && !revoked

    @Synchronized
    fun revoke(lease: Lease<I>) {
        if (current === lease) {
            revoked = true
            active = false
        }
    }

    @Synchronized
    fun died(lease: Lease<I>): Boolean {
        if (current !== lease) return false
        current = null
        active = false
        revoked = true
        return true
    }

    /**
     * Owns [socket], even on denial or exception. The operation must be only
     * local socket protection; it must not call back into this gate or make
     * a worker RPC. Revocation waits for already-admitted protection.
     */
    fun <D : Closeable> protect(
        lease: Lease<I>,
        generation: Long,
        identity: I?,
        socket: D,
        peerAlive: () -> Boolean,
        operation: (D) -> Boolean,
    ): Boolean = synchronized(this) {
        try {
            socket.use {
                if (!isActive(lease) || generation != lease.generation ||
                    identity != lease.identity || !peerAlive()
                ) {
                    false
                } else {
                    operation(it)
                }
            }
        } catch (_: Exception) {
            revoke(lease)
            false
        }
    }
}

/**
 * Register observation BEFORE reserving or sending any RPC/capability. A
 * registration failure has granted nothing and cannot strand an occupied gate.
 * After reservation, only the registered death callback may free the lease.
 */
internal class MihomoDeathWatch<I : Any>(
    private val gate: MihomoLeaseGate<I>,
    private val identity: I,
    private val onDeath: (Long) -> Unit,
) {
    private var dead = false
    private var lease: MihomoLeaseGate.Lease<I>? = null

    fun reserveAfterRegistration(register: (() -> Unit) -> Unit): MihomoLeaseGate.Lease<I> {
        register(::died)
        return synchronized(this) {
            check(!dead) { "Mihomo worker died before reservation" }
            check(lease == null) { "Mihomo death watch already reserved" }
            gate.reserve(identity).also { lease = it }
        }
    }

    fun died() {
        val observed = synchronized(this) {
            dead = true
            lease
        }
        if (observed != null && gate.died(observed)) onDeath(observed.generation)
    }
}

/** Owns both duplicates; close attempts both exactly once, even on failure. */
internal class MihomoOwnedDescriptors<D : Closeable>(
    private val tun: D,
    private val configuration: D,
) : Closeable {
    private var closed = false

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        // use closes configuration if closing tun throws, preserving both errors.
        configuration.use { tun.close() }
    }
}

/** A worker process may stage once, including across service recreation. */
internal class MihomoWorkerSlot<R : Closeable> : Closeable {
    private var claimed = false
    private var retired = false
    private var resource: R? = null

    @Synchronized
    fun install(value: R) {
        if (claimed || retired) {
            value.use { error("Mihomo worker process cannot be reused") }
        }
        claimed = true
        resource = value
    }

    @Synchronized
    override fun close() {
        retired = true
        val owned = resource
        resource = null
        owned?.close()
    }
}
