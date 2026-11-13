package kr.kimrasng.proxima.client.android.proxima

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import java.io.Closeable
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kr.kimrasng.proxima.mihomo.NativeEngine

/**
 * One native session in :mihomo. No foreground notification or VpnRuntime here.
 * Native unexpected packet exit closes management admission; a one-second
 * trafficStats health watch detects that condition and retires this process.
 * Java has no Done/Wait binding; do not mistake successful start for health.
 */
class MihomoWorkerService : Service() {
    private lateinit var worker: WorkerEndpoint

    override fun onCreate() {
        super.onCreate()
        // Never let a manifest mistake authorize termination of the main PID.
        check(mihomoProcessName() == "$packageName:mihomo") { "Mihomo service requires its dedicated process" }
        synchronized(processLock) {
            worker = processEndpoint ?: WorkerEndpoint(filesDir, cacheDir).also { processEndpoint = it }
        }
    }

    override fun onBind(intent: Intent): IBinder = worker

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf(startId)
        return START_NOT_STICKY
    }

    override fun onUnbind(intent: Intent): Boolean {
        worker.retire()
        return false
    }

    override fun onDestroy() {
        try {
            worker.retire()
        } finally {
            super.onDestroy()
        }
    }

    private class WorkerEndpoint(private val files: File, private val cache: File) : Binder() {
        private val slot = MihomoWorkerSlot<WorkerLease>()
        private val lifecycle = Any()
        @Volatile private var current: WorkerLease? = null
        private val health = Executors.newSingleThreadScheduledExecutor()

        init {
            attachInterface(null, MihomoBinderTransport.WORKER)
        }

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in MihomoBinderTransport.HELLO..MihomoBinderTransport.CONNECTIONS) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(MihomoBinderTransport.WORKER)
            check(Binder.getCallingUid() == Process.myUid()) { "Foreign Mihomo caller" }
            if (code == MihomoBinderTransport.RETIRE) {
                require(data.dataAvail() == 0)
                retire()
                return true
            }
            require(reply != null && flags and IBinder.FLAG_ONEWAY == 0)
            check(Binder.getCallingPid() > 0 && Binder.getCallingPid() != Process.myPid()) {
                "Mihomo transport requires a remote owner"
            }
            if (code == MihomoBinderTransport.HELLO) {
                val generation = data.readLong()
                val callback = data.readStrongBinder()
                require(data.dataAvail() == 0 && generation > 0 && callback != null && callback !is Binder)
                // Call directly from this service process. No PID is returned
                // in a Parcel; the owner reads the callback's Binder identity.
                MihomoBinderTransport.call(
                    callback, MihomoBinderTransport.HANDSHAKE, MihomoBinderTransport.ACKNOWLEDGE,
                    encode = {
                        it.writeLong(generation)
                        it.writeStrongBinder(this)
                    },
                    decode = {},
                )
                reply.writeNoException()
                return true
            }

            val generation = data.readLong()
            if (code >= MihomoBinderTransport.TRAFFIC) {
                val lease = checkNotNull(current) { "Mihomo is not running" }
                check(lease.generation == generation && lease.started) { "Mihomo lease is inactive" }
                when (code) {
                    MihomoBinderTransport.TRAFFIC -> {
                        require(data.dataAvail() == 0)
                        val counters = lease.engine.trafficStats()
                        reply.writeNoException()
                        reply.writeLong(counters[0]); reply.writeLong(counters[1])
                    }
                    MihomoBinderTransport.DELAY -> {
                        val name = checkNotNull(data.readString())
                        val url = checkNotNull(data.readString())
                        val timeout = data.readInt()
                        require(data.dataAvail() == 0)
                        val delay = lease.engine.delayTest(name, url, timeout)
                        reply.writeNoException(); reply.writeInt(delay)
                    }
                    MihomoBinderTransport.CONNECTIONS -> {
                        require(data.dataAvail() == 0)
                        val snapshot = MihomoConfiguration.copyOf(lease.engine.connectionsSnapshot())
                        MihomoBinderTransport.withConfiguration(cache, snapshot) { fd ->
                            reply.writeNoException()
                            reply.writeInt(snapshot.size); reply.writeString(snapshot.sha256)
                            fd.writeToParcel(reply, 0)
                        }
                    }
                }
                return true
            }
            // Start errors include LinkageError/UnsatisfiedLinkError: Binder's
            // exception codec cannot carry those. Return a bounded error string.
            val startupError = runCatching {
                synchronized(lifecycle) { start(data, generation) }
            }.exceptionOrNull()
            reply.writeNoException()
            reply.writeString(startupError?.let { (it.message ?: it.javaClass.simpleName).take(2048) })
            return true
        }

        private fun start(data: Parcel, generation: Long) {
            val owner = data.readStrongBinder()
            val size = data.readInt()
            val sha256 = data.readString()
            // Nested use closes all successfully decoded receiver duplicates,
            // including malformed envelopes and failure decoding the second fd.
            ParcelFileDescriptor.CREATOR.createFromParcel(data).use { tun ->
                ParcelFileDescriptor.CREATOR.createFromParcel(data).use { configuration ->
                    require(data.dataAvail() == 0 && generation > 0 && owner != null && sha256 != null)
                    require(owner !is Binder) { "Mihomo owner must be remote" }
                    Os.fstat(tun.fileDescriptor)
                    MihomoBinderTransport.verifyConfiguration(configuration, size, sha256)
                    val tunCopy = tun.dup()
                    val owned = try {
                        MihomoOwnedDescriptors(tunCopy, configuration.dup())
                    } catch (error: Exception) {
                        tunCopy.close()
                        throw error
                    }
                    val lease = WorkerLease(
                        generation,
                        owned,
                        owner,
                        IBinder.DeathRecipient { retire() },
                        MihomoWorkerSocketProtector(generation, this, owner),
                    )
                    var installed = false
                    try {
                        owner.linkToDeath(lease.death, 0)
                        lease.linked = true
                        slot.install(lease)
                        installed = true
                        current = lease // Retain even when NativeEngine.start throws.
                        val root = File(files, "mihomo-providers").apply {
                            check(isDirectory || mkdirs()) { "Cannot create Mihomo provider root" }
                        }
                        val bytes = ByteArray(size)
                        var offset = 0
                        while (offset < size) {
                            val read = Os.pread(configuration.fileDescriptor, bytes, offset, size - offset, offset.toLong())
                            check(read > 0)
                            offset += read
                        }
                        lease.engine.start(bytes, tunCopy.fd, { fd ->
                            // fromFd duplicates a borrowed worker-local socket;
                            // closing it never closes the engine's original.
                            ParcelFileDescriptor.fromFd(fd).use {
                                lease.protect(it)
                            }
                        }, root.absolutePath)
                        lease.started = true
                        health.scheduleAtFixedRate({
                            if (lease.started && runCatching { lease.engine.trafficStats() }.isFailure) retire()
                        }, 1, 1, TimeUnit.SECONDS)
                    } catch (error: Throwable) {
                        if (!installed) runCatching { lease.close() }
                        // Keep cleanup handles until RETIRE; Stop may need retry.
                        throw error
                    }
                }
            }
        }

        fun retire() {
            try {
                health.shutdownNow()
                synchronized(lifecycle) { slot.close() }
            } finally {
                // Stop acknowledgments cannot join upstream globals. Retire the
                // entire worker PID; the main owner waits for this Binder's death.
                Process.killProcess(Process.myPid())
            }
        }
    }

    private class WorkerLease(
        val generation: Long,
        private val descriptors: MihomoOwnedDescriptors<ParcelFileDescriptor>,
        private val owner: IBinder,
        val death: IBinder.DeathRecipient,
        private val socketProtector: MihomoWorkerSocketProtector,
    ) : Closeable {
        // Lazy so staging ownership is retained even if native loading fails.
        private val native = lazy { NativeEngine() }
        val engine: NativeEngine get() = native.value
        @Volatile var started = false
        var linked = false
        private var closed = false

        fun protect(fd: ParcelFileDescriptor): Boolean = socketProtector.protectBorrowedSocket(fd.fileDescriptor)

        @Synchronized
        override fun close() {
            if (closed) return
            closed = true
            started = false
            try {
                // Native Stop cancels/joins probes, packets and its own duplicate
                // TUNs before the borrowed worker descriptors can be closed.
                if (native.isInitialized()) engine.stop()
            } finally {
                socketProtector.revoke()
                try { descriptors.close() } finally {
                    if (linked) owner.unlinkToDeath(death, 0)
                }
            }
        }
    }

    companion object {
        private val processLock = Any()
        // Strongly retained for the process lifetime, never replaced on rebind
        // or Service recreation. Remote Binder death therefore fences this PID.
        private var processEndpoint: WorkerEndpoint? = null
    }
}
