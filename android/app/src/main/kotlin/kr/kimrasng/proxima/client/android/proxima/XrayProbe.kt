package kr.kimrasng.proxima.client.android.proxima

import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import org.json.JSONObject

/** Runs user-requested checks through Xray's loopback SOCKS inbound. */
object XrayProbe {
    private const val MAX_RESPONSE_BYTES = 64 * 1024

    fun delay(port: Int, target: String, timeoutMillis: Int): Int {
        val url = httpsUrl(target)
        val started = SystemClock.elapsedRealtime()
        val timeout = timeoutMillis.coerceIn(1_000, 8_000)
        val socket = Socket(
            Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", port)),
        )
        return try {
            // A SOCKS CONNECT completes only after this exact Xray outbound
            // reaches the target. It measures the node without waiting for an
            // HTTP response body or redirect chain.
            socket.connect(InetSocketAddress(url.host, if (url.port > 0) url.port else 443), timeout)
            (SystemClock.elapsedRealtime() - started).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        } finally {
            socket.close()
        }
    }

    fun publicIp(port: Int): JSONObject {
        var lastError: Throwable? = null
        val endpoints = listOf(
            "https://api.ipify.org?format=json",
            "https://api64.ipify.org?format=json",
            "https://ipapi.co/json/",
        )
        endpoints.forEach { endpoint ->
            runCatching { return readJson(URL(endpoint), port, 5_000) }
                .onFailure { lastError = it }
        }
        throw lastError ?: IllegalStateException("공인 IP를 확인하지 못했습니다.")
    }

    private fun readJson(url: URL, port: Int, timeoutMillis: Int): JSONObject {
        val connection = open(url, port, timeoutMillis)
        return try {
            require(connection.responseCode in 200..299) { "공인 IP 조회 서버가 ${connection.responseCode}을 반환했습니다." }
            val text = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= MAX_RESPONSE_BYTES) { "공인 IP 응답이 너무 큽니다." }
                    output.write(buffer, 0, count)
                }
                output.toString(Charsets.UTF_8.name())
            }
            JSONObject(text)
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: URL, port: Int, timeoutMillis: Int): HttpURLConnection {
        require(port in 1..65535) { "Xray 검사 포트를 찾을 수 없습니다." }
        return (url.openConnection(
            Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", port)),
        ) as HttpURLConnection).apply {
            connectTimeout = timeoutMillis.coerceIn(1_000, 20_000)
            readTimeout = timeoutMillis.coerceIn(1_000, 20_000)
            setRequestProperty("User-Agent", "Proxima-Xray/1.0")
        }
    }

    private fun httpsUrl(value: String): URL {
        val url = URL(value)
        require(url.protocol == "https") { "지연 시간 검사는 HTTPS 주소만 사용할 수 있습니다." }
        return url
    }
}
