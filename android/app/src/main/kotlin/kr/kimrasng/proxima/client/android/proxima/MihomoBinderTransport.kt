package kr.kimrasng.proxima.client.android.proxima

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileDescriptor
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

internal fun Context.mihomoProcessName(): String? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        Application.getProcessName()
    } else {
        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
            .runningAppProcesses?.firstOrNull { it.pid == android.os.Process.myPid() }?.processName
    }

/**
 * Explicit, versioned Binder wire format. AIDL is not enabled in this app.
 * Every descriptor on this wire is a ParcelFileDescriptor, never an fd number.
 */
internal object MihomoBinderTransport {
    const val WORKER = "kr.kimrasng.proxima.mihomo.Worker.v3"
    const val PROTECTOR = "kr.kimrasng.proxima.mihomo.Protector.v1"
    const val HANDSHAKE = "kr.kimrasng.proxima.mihomo.Handshake.v1"
    const val HELLO = IBinder.FIRST_CALL_TRANSACTION
    const val ACKNOWLEDGE = IBinder.FIRST_CALL_TRANSACTION
    const val STAGE = IBinder.FIRST_CALL_TRANSACTION + 1
    const val RETIRE = IBinder.FIRST_CALL_TRANSACTION + 2
    const val PROTECT = IBinder.FIRST_CALL_TRANSACTION
    const val TRAFFIC = IBinder.FIRST_CALL_TRANSACTION + 3
    const val DELAY = IBinder.FIRST_CALL_TRANSACTION + 4
    const val CONNECTIONS = IBinder.FIRST_CALL_TRANSACTION + 5

    fun <T> call(
        remote: IBinder,
        descriptor: String,
        code: Int,
        encode: (Parcel) -> Unit,
        decode: (Parcel) -> T,
    ): T {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(descriptor)
            encode(data)
            if (!remote.transact(code, data, reply, 0)) {
                throw RemoteException("Unsupported Mihomo Binder transaction")
            }
            reply.readException()
            return decode(reply)
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    fun retire(remote: IBinder) {
        val data = Parcel.obtain()
        try {
            data.writeInterfaceToken(WORKER)
            if (!remote.transact(RETIRE, data, null, IBinder.FLAG_ONEWAY)) {
                throw RemoteException("Mihomo worker rejected retirement")
            }
        } finally {
            data.recycle()
        }
    }

    /**
     * The only writer is closed before opening read-only. Unlink before
     * transfer, retaining no writable handle or pathname to the snapshot.
     * This is an ownership contract within our UID, not a hostile-UID sandbox.
     */
    fun <T> withConfiguration(
        directory: File,
        configuration: MihomoConfiguration,
        operation: (ParcelFileDescriptor) -> T,
    ): T {
        val file = File.createTempFile("mihomo-config-", ".snapshot", directory)
        try {
            file.outputStream().use(configuration::writeTo)
            Os.chmod(file.absolutePath, 0b100000000) // 0400
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use {
                check(file.delete()) { "Cannot unlink Mihomo configuration snapshot" }
                operation(it)
            }
        } finally {
            file.delete()
        }
    }

    fun verifyConfiguration(descriptor: ParcelFileDescriptor, size: Int, sha256: String) {
        require(size in 1..MihomoConfiguration.MAX_BYTES && sha256.matches(Regex("[0-9a-f]{64}"))) {
            "Invalid Mihomo configuration envelope"
        }
        val stat = Os.fstat(descriptor.fileDescriptor)
        require(OsConstants.S_ISREG(stat.st_mode) && stat.st_size == size.toLong()) {
            "Mihomo configuration must be a bounded regular snapshot"
        }
        require(stat.st_mode and 0b010010010 == 0) { "Mihomo snapshot must have no write permissions" }
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(16 * 1024)
        var offset = 0
        while (offset < size) {
            // pread does not move the open-file-description offset shared by dup.
            val count = Os.pread(descriptor.fileDescriptor, buffer, 0, minOf(buffer.size, size - offset), offset.toLong())
            check(count > 0) { "Truncated Mihomo configuration snapshot" }
            digest.update(buffer, 0, count)
            offset += count
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        require(actual == sha256) { "Mihomo configuration snapshot changed" }
    }
}

/**
 * The native callback captures this instance, never looks up a newer
 * process-global lease. The fd is borrowed only within this worker process.
 * No socket creation occurs in this class.
 */
internal class MihomoWorkerSocketProtector(
    private val generation: Long,
    private val workerIdentity: IBinder,
    private val owner: IBinder,
) {
    private val active = AtomicBoolean(true)

    fun revoke() {
        active.set(false)
    }

    fun protectBorrowedSocket(socket: FileDescriptor): Boolean {
        if (!active.get()) return false
        return try {
            ParcelFileDescriptor.dup(socket).use { duplicate ->
                val protected = MihomoBinderTransport.call(
                    owner, MihomoBinderTransport.PROTECTOR, MihomoBinderTransport.PROTECT,
                    encode = {
                        it.writeLong(generation)
                        it.writeStrongBinder(workerIdentity)
                        duplicate.writeToParcel(it, 0)
                    },
                    decode = { it.readInt() == 1 },
                )
                active.get() && protected
            }
        } catch (_: Exception) {
            revoke()
            false
        }
    }
}
