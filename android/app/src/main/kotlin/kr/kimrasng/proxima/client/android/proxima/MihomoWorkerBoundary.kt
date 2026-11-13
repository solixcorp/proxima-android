package kr.kimrasng.proxima.client.android.proxima

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Main-process transport owner. Only the selected Mihomo VPN path binds it.
 * bind() owns an explicit platform binding to MihomoWorkerService. Arbitrary
 * remote Binders cannot be supplied by callers.
 * Start acknowledgment means NativeEngine.start returned successfully. Only
 * ProximaVpnService may publish Android connected state.
 *
 * Protection covers only sockets explicitly sent through this endpoint.
 * In particular, it does not fix upstream fakeTCP/default-hook bypasses.
 */
object MihomoWorkerBoundary {
    private val gate = MihomoLeaseGate<IBinder>()
    private val main = Handler(Looper.getMainLooper())
    private var binding: Binding? = null

    /**
     * Call on the main thread. All callbacks also run there. Return means a
     * binding was requested, not that the worker is attached or initialized.
     * Binding.close() revokes/unbinds; a granted lease remains occupied until
     * death. No service binding or native work happens before this explicit call.
     */
    fun bind(
        vpn: VpnService,
        onConnected: (Connection) -> Unit,
        onWorkerDeath: (generation: Long) -> Unit,
        onFailure: (Exception) -> Unit,
    ): Binding {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Bind Mihomo on the main thread" }
        require(vpn.mihomoProcessName() == vpn.applicationInfo.processName) {
            "Mihomo protector must belong to the main application process"
        }
        check(binding == null && gate.isVacant()) { "Previous Mihomo binding has not retired" }
        val owner = Binding(vpn, onConnected, onWorkerDeath, onFailure)
        binding = owner
        try {
            owner.start()
        } catch (error: Exception) {
            owner.close()
            throw error
        }
        return owner
    }

    /**
     * Owns the private ServiceConnection so callers cannot inject a Binder into
     * onServiceConnected. Component identity comes from the platform binding.
     */
    class Binding internal constructor(
        private val vpn: VpnService,
        private val onConnected: (Connection) -> Unit,
        private val onWorkerDeath: (Long) -> Unit,
        private val onFailure: (Exception) -> Unit,
    ) : Closeable {
        private val component = ComponentName(vpn, MihomoWorkerService::class.java)
        private var registered = false
        private var closed = false
        private var connection: Connection? = null
        private val retired = MihomoRetirementFence()

        /** Off-main only. Process death, never an RPC error, is the final fence. */
        fun awaitRetired() {
            check(Looper.myLooper() != Looper.getMainLooper())
            retired.awaitRetired()
        }

        private val dispatcher = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                if (closed) return
                val attached = try {
                    check(name == component && connection == null) { "Unexpected Mihomo service binding" }
                    attach(vpn, service) { generation ->
                        retired.observedDeath()
                        main.post {
                            close()
                            if (binding === this@Binding) binding = null
                            onWorkerDeath(generation)
                        }
                    }
                } catch (error: Exception) {
                    fail(error)
                    return
                }
                connection = attached
                onConnected(attached)
            }

            override fun onServiceDisconnected(name: ComponentName) {
                // Disconnection is not proof of death. close() retains any
                // granted gate lease until the registered DeathRecipient fires.
                fail(IllegalStateException("Mihomo service disconnected"))
            }

            override fun onBindingDied(name: ComponentName) {
                fail(IllegalStateException("Mihomo service binding died"))
            }

            override fun onNullBinding(name: ComponentName) {
                fail(IllegalStateException("Mihomo service returned no Binder"))
            }
        }

        internal fun start() {
            registered = true
            check(vpn.bindService(Intent().setComponent(component), dispatcher, Context.BIND_AUTO_CREATE)) {
                "Mihomo service binding was rejected"
            }
        }

        private fun fail(error: Exception) {
            if (closed) return
            close()
            onFailure(error)
        }

        override fun close() {
            check(Looper.myLooper() == Looper.getMainLooper()) { "Unbind Mihomo on the main thread" }
            if (closed) return
            closed = true
            connection?.close()
            if (registered) {
                registered = false
                try {
                    vpn.unbindService(dispatcher)
                } catch (_: IllegalArgumentException) {
                    // bindService may have failed before registering.
                }
            }
            if (gate.isVacant()) {
                retired.observedDeath()
                if (binding === this) binding = null
            }
        }
    }

    private fun attach(
        vpn: VpnService,
        worker: IBinder,
        onWorkerDeath: (Long) -> Unit,
    ): Connection {
        require(worker !is Binder) { "Mihomo worker must be in a remote process" }
        val watch = MihomoDeathWatch(gate, worker, onWorkerDeath)
        var death: IBinder.DeathRecipient? = null
        var reserved: MihomoLeaseGate.Lease<IBinder>? = null
        try {
            val lease = watch.reserveAfterRegistration { observedDeath ->
                val recipient = IBinder.DeathRecipient { observedDeath() }
                death = recipient
                worker.linkToDeath(recipient, 0)
            }
            reserved = lease
            val handshake = MihomoWorkerHandshake(
                lease.generation, worker, Process.myUid(), Process.myPid(),
            )
            val callback = object : Binder() {
                init {
                    attachInterface(null, MihomoBinderTransport.HANDSHAKE)
                }

                override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                    if (code != MihomoBinderTransport.ACKNOWLEDGE) return super.onTransact(code, data, reply, flags)
                    data.enforceInterface(MihomoBinderTransport.HANDSHAKE)
                    require(reply != null && flags and IBinder.FLAG_ONEWAY == 0)
                    val generation = data.readLong()
                    val identity = data.readStrongBinder()
                    check(data.dataAvail() == 0 && handshake.acknowledge(
                        generation, identity, Binder.getCallingUid(), Binder.getCallingPid(),
                    )) { "Invalid Mihomo handshake caller" }
                    reply.writeNoException()
                    return true
                }
            }
            val pid = try {
                MihomoBinderTransport.call(
                    worker, MihomoBinderTransport.WORKER, MihomoBinderTransport.HELLO,
                    encode = {
                        it.writeLong(lease.generation)
                        it.writeStrongBinder(callback)
                    },
                    decode = {},
                )
                handshake.finish()
            } finally {
                handshake.abort()
            }
            check(gate.activate(lease)) { "Mihomo worker died during attachment" }
            return Connection(vpn, lease, pid, checkNotNull(death))
        } catch (error: Exception) {
            val lease = reserved
            if (lease == null) {
                // No RPC, protector, descriptor, or lease was granted. Failed
                // observation is safe to retry, without inventing a death event.
                death?.let { runCatching { worker.unlinkToDeath(it, 0) } }
            } else {
                gate.revoke(lease)
                runCatching { MihomoBinderTransport.retire(worker) }
                // Keep the death observer and occupied slot even on DeadObject-
                // shaped RPC errors: an error is not the registered death event.
            }
            throw error
        }
    }

    class Connection internal constructor(
        private val vpn: VpnService,
        private val lease: MihomoLeaseGate.Lease<IBinder>,
        private val workerPid: Int,
        // Retain the recipient and worker Binder until actual process death.
        private val death: IBinder.DeathRecipient,
    ) : Closeable {
        val generation: Long get() = lease.generation
        private val staged = AtomicBoolean(false)
        private val retirementSent = AtomicBoolean(false)

        private val protector = object : Binder() {
            init {
                attachInterface(null, MihomoBinderTransport.PROTECTOR)
            }

            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code != MihomoBinderTransport.PROTECT) return super.onTransact(code, data, reply, flags)
                data.enforceInterface(MihomoBinderTransport.PROTECTOR)
                require(reply != null && flags and IBinder.FLAG_ONEWAY == 0)
                val requestedGeneration = data.readLong()
                val identity = data.readStrongBinder()
                val socket = ParcelFileDescriptor.CREATOR.createFromParcel(data)
                // Once unmarshalled, the gate owns and always closes this copy.
                val allowed = gate.protect(
                    lease, requestedGeneration, identity, socket,
                    peerAlive = {
                        data.dataAvail() == 0 &&
                            Binder.getCallingUid() == Process.myUid() &&
                            Binder.getCallingPid() == workerPid &&
                            lease.identity.isBinderAlive
                    },
                    operation = {
                        val caller = Binder.clearCallingIdentity()
                        try {
                            vpn.protect(it.fd)
                        } finally {
                            Binder.restoreCallingIdentity(caller)
                        }
                    },
                )
                reply.writeNoException()
                reply.writeInt(if (allowed) 1 else 0)
                return true
            }
        }

        /**
         * Transfer duplicates and start the native engine. Caller retains its original TUN.
         * The configuration travels as an unlinked, read-only file, not an 8 MB
         * Binder payload. A native start error is returned without fallback.
         */
        fun start(tun: ParcelFileDescriptor, configuration: MihomoConfiguration) {
            check(gate.isActive(lease)) { "Mihomo lease is inactive" }
            check(staged.compareAndSet(false, true)) { "Mihomo lease already staged" }
            try {
                MihomoBinderTransport.withConfiguration(vpn.cacheDir, configuration) { config ->
                    tun.dup().use { duplicate ->
                        MihomoBinderTransport.call(
                            lease.identity, MihomoBinderTransport.WORKER, MihomoBinderTransport.STAGE,
                            encode = {
                                it.writeLong(generation)
                                it.writeStrongBinder(protector)
                                it.writeInt(configuration.size)
                                it.writeString(configuration.sha256)
                                duplicate.writeToParcel(it, 0)
                                config.writeToParcel(it, 0)
                            },
                            decode = { reply -> reply.readString()?.let { error("Mihomo start: $it") } },
                        )
                    }
                }
                check(gate.isActive(lease)) { "Mihomo lease retired during staging" }
            } catch (error: Exception) {
                close()
                throw error
            }
        }

        private fun <T> query(code: Int, encode: (Parcel) -> Unit = {}, decode: (Parcel) -> T): T {
            check(gate.isActive(lease)) { "Mihomo lease is inactive" }
            return MihomoBinderTransport.call(
                lease.identity, MihomoBinderTransport.WORKER, code,
                encode = { it.writeLong(generation); encode(it) }, decode = decode,
            )
        }

        fun trafficStats(): LongArray = query(MihomoBinderTransport.TRAFFIC) {
            longArrayOf(it.readLong(), it.readLong())
        }

        fun delayTest(name: String, url: String, timeoutMs: Int): Int = query(
            MihomoBinderTransport.DELAY,
            encode = { it.writeString(name); it.writeString(url); it.writeInt(timeoutMs) },
            decode = { it.readInt() },
        )

        fun select(group: String, proxy: String) = query(
            MihomoBinderTransport.SELECT,
            encode = { it.writeString(group); it.writeString(proxy) },
            decode = {},
        )

        fun connectionsSnapshot(): ByteArray = query(MihomoBinderTransport.CONNECTIONS) { reply ->
            val size = reply.readInt()
            val sha256 = checkNotNull(reply.readString())
            // Connection JSON is also up to 8 MiB: never return it inline in Binder.
            ParcelFileDescriptor.CREATOR.createFromParcel(reply).use { snapshot ->
                MihomoBinderTransport.verifyConfiguration(snapshot, size, sha256)
                ByteArray(size).also { bytes ->
                    var offset = 0
                    while (offset < size) {
                        val read = android.system.Os.pread(snapshot.fileDescriptor, bytes, offset, size - offset, offset.toLong())
                        check(read > 0) { "Truncated Mihomo connections snapshot" }
                        offset += read
                    }
                }
            }
        }

        /**
         * Deny new protection, then request process exit. This is NOT a joined
         * stop acknowledgment. Replacement stays blocked until Binder death.
         */
        override fun close() {
            gate.revoke(lease)
            if (retirementSent.compareAndSet(false, true)) {
                // A failed RPC cannot authorize a new generation.
                runCatching { MihomoBinderTransport.retire(lease.identity) }
            }
        }
    }
}
