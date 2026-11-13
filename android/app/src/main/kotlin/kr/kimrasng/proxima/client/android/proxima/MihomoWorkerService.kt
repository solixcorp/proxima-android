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

/**
 * Bound-only descriptor staging in :mihomo. No JNI load, native engine,
 * packet consumer, foreground notification, or VpnRuntime access.
 *
 * Future runtime integration must supervise ReadDone()/ReadError() from the
 * raw-device packet loop. Unexpected exit requires generation-checked failure
 * reporting, protection revocation, and worker teardown. Successful startup
 * alone must never be treated as continued runtime health. There is no engine
 * or placeholder watcher here.
 */
class MihomoWorkerService : Service() {
    private lateinit var worker: WorkerEndpoint

    override fun onCreate() {
        super.onCreate()
        // Never let a manifest mistake authorize termination of the main PID.
        check(mihomoProcessName() == "$packageName:mihomo") { "Mihomo service requires its dedicated process" }
        synchronized(processLock) {
            worker = processEndpoint ?: WorkerEndpoint().also { processEndpoint = it }
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

    private class WorkerEndpoint : Binder() {
        private val slot = MihomoWorkerSlot<WorkerLease>()

        init {
            attachInterface(null, MihomoBinderTransport.WORKER)
        }

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in MihomoBinderTransport.HELLO..MihomoBinderTransport.RETIRE) {
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
                        owned,
                        owner,
                        IBinder.DeathRecipient { retire() },
                        MihomoWorkerSocketProtector(generation, this, owner),
                    )
                    try {
                        owner.linkToDeath(lease.death, 0)
                        lease.linked = true
                        slot.install(lease)
                    } catch (error: Exception) {
                        lease.close()
                        throw error
                    }
                }
            }
            reply.writeNoException() // Descriptor ownership only; no engine startup.
            return true
        }

        fun retire() {
            try {
                slot.close()
            } finally {
                // Stop acknowledgments cannot join upstream globals. Retire the
                // entire worker PID; the main owner waits for this Binder's death.
                Process.killProcess(Process.myPid())
            }
        }
    }

    private class WorkerLease(
        private val descriptors: MihomoOwnedDescriptors<ParcelFileDescriptor>,
        private val owner: IBinder,
        val death: IBinder.DeathRecipient,
        // A future native callback must capture this immutable instance.
        private val socketProtector: MihomoWorkerSocketProtector,
    ) : Closeable {
        var linked = false
        private var closed = false

        @Synchronized
        override fun close() {
            if (closed) return
            closed = true
            socketProtector.revoke()
            try {
                descriptors.close()
            } finally {
                if (linked) owner.unlinkToDeath(death, 0)
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
