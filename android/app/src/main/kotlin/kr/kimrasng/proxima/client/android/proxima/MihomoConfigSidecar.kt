package kr.kimrasng.proxima.client.android.proxima

import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

/** App-private, bounded chunk upload. A ready snapshot is consumed exactly once.
 * Source/settings fingerprints prevent a delayed start using an obsolete config.
 * The random capability is passed in the service Intent, never configuration bytes.
 */
class MihomoConfigSidecar(private val directory: File) {
    init { check(directory.isDirectory || directory.mkdirs()) { "Mihomo 설정 디렉터리를 생성하지 못했습니다." } }

    fun begin(profileId: String, source: String, settingsKey: String, size: Int): String {
        require(size in 1..MihomoConfiguration.MAX_BYTES) { "Mihomo 실행 설정은 1바이트 이상 8MB 이하여야 합니다." }
        require(PROFILE.matches(profileId) && '\n' !in settingsKey) { "Invalid Mihomo profile/settings" }
        val token = UUID.randomUUID().toString()
        file(token, "meta").writeText(listOf(profileId, fingerprint(source), settingsKey, size.toString()).joinToString("\n"))
        file(token, "part").writeBytes(byteArrayOf())
        return token
    }

    fun append(token: String, offset: Int, bytes: ByteArray) {
        val expected = metadata(token).last().toInt()
        val part = file(token, "part")
        require(bytes.isNotEmpty() && bytes.size <= CHUNK_BYTES && offset >= 0 &&
            part.isFile && part.length() == offset.toLong() && offset.toLong() + bytes.size <= expected) {
            "Mihomo 설정 청크 순서/크기가 올바르지 않습니다."
        }
        part.appendBytes(bytes)
    }

    fun finish(token: String) {
        val expected = metadata(token).last().toInt()
        val part = file(token, "part")
        require(part.isFile && part.length() == expected.toLong()) { "Mihomo 설정 사이드카 전송이 완료되지 않았습니다." }
        RandomAccessFile(part, "rw").use { it.fd.sync() }
        check(part.renameTo(file(token, "yaml"))) { "Mihomo 설정 사이드카를 생성하지 못했습니다." }
    }

    fun requireReady(token: String) {
        val expected = metadata(token).last().toInt()
        require(file(token, "yaml").isFile && file(token, "yaml").length() == expected.toLong()) {
            "Mihomo 설정 사이드카가 없습니다. 앱에서 다시 연결해 주세요."
        }
    }

    fun consume(token: String?, profileId: String, source: String, settingsKey: String): ByteArray {
        require(!token.isNullOrBlank()) { "Mihomo 설정 사이드카가 없습니다. 앱에서 다시 연결해 주세요." }
        try {
            requireReady(token)
            val meta = metadata(token)
            require(meta[0] == profileId && meta[1] == fingerprint(source) && meta[2] == settingsKey) {
                "Mihomo 설정 사이드카가 오래되었습니다. 앱에서 다시 연결해 주세요."
            }
            return file(token, "yaml").inputStream().use {
                val bytes = it.readNBytesBounded(meta[3].toInt())
                require(bytes.size == meta[3].toInt()) { "Mihomo 설정 사이드카 크기가 다릅니다." }
                bytes
            }
        } finally {
            discard(token)
        }
    }

    fun discard(token: String) {
        for (suffix in listOf("meta", "part", "yaml")) file(token, suffix).delete()
    }

    private fun metadata(token: String): List<String> {
        val meta = file(token, "meta")
        require(meta.isFile && meta.length() <= 1024) { "Mihomo 설정 사이드카 메타데이터가 없습니다." }
        val rows = meta.readLines()
        require(rows.size == 4 && rows[3].toIntOrNull() in 1..MihomoConfiguration.MAX_BYTES) { "Invalid Mihomo sidecar metadata" }
        return rows
    }

    private fun file(token: String, suffix: String): File {
        require(PROFILE.matches(token)) { "Invalid Mihomo configuration token" }
        return File(directory, "$token.$suffix")
    }

    companion object {
        const val CHUNK_BYTES = 64 * 1024
        private val PROFILE = Regex("[a-fA-F0-9-]{36}")
        fun settingsKey(mtu: Int, ipv6: Boolean, mode: String) = "$mtu:$ipv6:$mode:mips"
        private fun fingerprint(source: String) = MihomoConfiguration.digest(source.toByteArray(Charsets.UTF_8))
    }
}

private fun java.io.InputStream.readNBytesBounded(size: Int): ByteArray {
    // Avoid java.io.InputStream.readNBytes (not available on older Android).
    val output = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(16 * 1024)
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        require(output.size().toLong() + count <= size) { "Mihomo 설정 사이드카가 8MB/선언 크기를 초과합니다." }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
