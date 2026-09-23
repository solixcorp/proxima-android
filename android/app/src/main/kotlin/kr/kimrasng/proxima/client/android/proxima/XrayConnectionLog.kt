package kr.kimrasng.proxima.client.android.proxima

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets

/**
 * Xray's Android binding has no public equivalent of Mihomo's `/connections`
 * endpoint.  Its access log is the source of truth exposed by the core, so we
 * return the recently observed destinations from that log instead of inventing
 * active sockets or per-connection byte counters.
 */
object XrayConnectionLog {
    private const val MAX_BYTES = 256 * 1024
    private const val MAX_ENTRIES = 80
    private val destination = Regex("(?:accepted\\s+)?(tcp|udp):([^\\s\\[\\]]+)", RegexOption.IGNORE_CASE)
    private val routeChain = Regex("\\[([^\\[\\]]+)]")

    fun recent(path: String?): JSONArray = JSONArray().apply {
        if (path.isNullOrBlank()) return@apply
        val file = File(path)
        if (!file.isFile) return@apply
        val content = runCatching {
            val bytes = file.readBytes()
            val tail = if (bytes.size > MAX_BYTES) bytes.copyOfRange(bytes.size - MAX_BYTES, bytes.size) else bytes
            tail.toString(StandardCharsets.UTF_8)
        }.getOrDefault("")
        val seen = linkedSetOf<String>()
        content.lineSequence().toList().asReversed().forEach { line ->
            if (seen.size >= MAX_ENTRIES) return@forEach
            val match = destination.find(line) ?: return@forEach
            val network = match.groupValues[1].uppercase()
            val address = match.groupValues[2].trimEnd('.', ',', ';')
            val host = address.substringBeforeLast(':', address)
            val port = address.substringAfterLast(':', "").toIntOrNull() ?: 0
            val key = "$network:$address"
            if (!seen.add(key)) return@forEach
            val chain = routeChain.findAll(line).lastOrNull()?.groupValues?.get(1)
                // Xray writes `->` for ordinary dispatches and `>>` when a
                // sniffed destination is used for routing. Treat both as the
                // same route boundary so the connections screen stays useful
                // after domain-rule sniffing is enabled.
                ?.split(Regex("\\s*(?:->|>>)+\\s*"))
                ?.map(String::trim)
                ?.filter { value ->
                    value.isNotBlank() && value != "proxima-tun" && value != "proxima-rule-probe" &&
                        !value.startsWith("proxima-probe-")
                }
                ?.map(::displayRoute)
                .orEmpty()
            val finalRoute = chain.lastOrNull().orEmpty()
            val rule = when (finalRoute) {
                "DIRECT" -> "직접 연결"
                "BLOCK" -> "차단"
                else -> if (finalRoute.isEmpty()) "Xray" else "프록시"
            }
            put(
                JSONObject()
                    .put("id", key)
                    .put(
                        "metadata",
                        JSONObject()
                            .put("host", host)
                            .put("destinationIP", host)
                            .put("destinationPort", port)
                            .put("network", network)
                            .put("type", "Xray access log"),
                    )
                    .put("rule", rule)
                    .put("rulePayload", "Xray 라우팅 로그")
                    .put("chains", JSONArray(chain))
                    .put("upload", 0)
                    .put("download", 0),
            )
        }
    }

    private fun displayRoute(value: String): String = when (value) {
        "proxima-direct" -> "DIRECT"
        "proxima-block" -> "BLOCK"
        "proxima-auto" -> "AUTO"
        else -> value
    }
}
