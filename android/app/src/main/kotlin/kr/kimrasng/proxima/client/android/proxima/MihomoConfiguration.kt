package kr.kimrasng.proxima.client.android.proxima

import java.io.OutputStream
import java.security.MessageDigest

/**
 * Immutable transport snapshot, not a parsed or validated Mihomo profile.
 * No configuration bytes are placed in a Binder transaction.
 */
class MihomoConfiguration private constructor(private val content: ByteArray) {
    val size: Int get() = content.size
    internal val sha256: String = digest(content)

    internal fun writeTo(output: OutputStream) {
        output.write(content)
    }

    companion object {
        const val MAX_BYTES = 8 * 1024 * 1024

        /** Caller must not mutate input concurrently with this snapshot copy. */
        fun copyOf(content: ByteArray): MihomoConfiguration {
            require(content.isNotEmpty() && content.size <= MAX_BYTES) {
                "Configuration must contain 1..$MAX_BYTES bytes"
            }
            return MihomoConfiguration(content.copyOf())
        }

        internal fun digest(content: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(content).joinToString("") {
                "%02x".format(it.toInt() and 0xff)
            }
    }
}
