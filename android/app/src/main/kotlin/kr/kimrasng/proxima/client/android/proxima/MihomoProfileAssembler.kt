package kr.kimrasng.proxima.client.android.proxima

import java.net.URI
import java.net.URLDecoder
import kotlin.io.encoding.Base64

/**
 * TEMPORARY Phase 2b projection, to move to Dart in Phase 3. This is not a
 * general Clash importer: only one selected stored VLESS link is instantiated.
 * Subscription rule metadata is deliberately NOT translated (rule = MATCH,PROXY).
 * No Xray parser, native library or Android API is needed for this projection.
 */
object MihomoProfileAssembler {
    data class Result(val yaml: String, val node: String, val proxy: Map<String, Any?>)

    fun build(
        profileName: String,
        content: String,
        mtu: Int,
        ipv6: Boolean,
        mode: String,
        selected: Map<String, String> = emptyMap(),
    ): Result {
        require(mode in setOf("global", "direct", "rule")) { "Invalid Mihomo mode" }
        require(mtu in setOf(1280, 1400, 1500, 9000)) { "Invalid Mihomo MTU" }
        require(content.toByteArray(Charsets.UTF_8).size <= MihomoConfiguration.MAX_BYTES) { "Mihomo profile exceeds 8 MiB" }
        val links = content.lineSequence().map(String::trim)
            .filter { it.startsWith(PREFIX) }.map { line ->
                val encoded = line.removePrefix(PREFIX).trim()
                // Never expose the credential-bearing source URI in an error.
                val uri = runCatching {
                    // Kotlin's codec also works on API 24/25 (java.util.Base64
                    // would require Android API 26 without core desugaring).
                    val padded = encoded.padEnd((encoded.length + 3) / 4 * 4, '=')
                    URI(String(Base64.UrlSafe.decode(padded), Charsets.UTF_8))
                }.getOrElse { error("Mihomo: invalid stored VLESS link encoding/URI") }
                uri.also { require(it.scheme == "vless") { "Mihomo requires a VLESS link" } }
            }.filterNot { uri ->
                val name = decode(uri.rawFragment.orEmpty())
                listOf("剩余流量", "距离下次重置", "套餐到期", "hello-ssone.com").any { name.contains(it, true) }
            }.toList()
        require(links.isNotEmpty()) { "Mihomo: 저장된 VLESS 링크를 찾을 수 없습니다." }
        val counts = mutableMapOf<String, Int>()
        val names = links.map { uri ->
            val base = if (links.size == 1 && profileName.isNotBlank()) profileName.trim()
                else decode(uri.rawFragment.orEmpty()).trim().ifBlank { uri.host ?: "VLESS REALITY" }
            val count = (counts[base] ?: 0) + 1
            counts[base] = count
            if (count == 1) base else "$base $count"
        }
        val requested = if (mode == "rule") selected["PROXY"]?.takeIf(names::contains)
            ?: selected["GLOBAL"] else selected["GLOBAL"]
        val index = names.indexOf(requested).takeIf { it >= 0 } ?: 0
        val name = names[index]
        require(name !in RESERVED) { "Mihomo: reserved proxy name: $name" }
        val proxy = proxy(links[index], name)
        // Engine admission forbids inet4-address and nonempty inet6-address:
        // app-owned raw TUN addresses/routes belong ONLY to VpnService.Builder.
        // Keep these comments in the snapshot so that the shared plan is explicit.
        val root = linkedMapOf<String, Any?>(
            "mode" to "rule", // MATCH encodes the app mode without GLOBAL defaults.
            "ipv6" to ipv6,
            "log-level" to "warning",
            "find-process-mode" to "off",
            "profile" to mapOf("store-selected" to false, "store-fake-ip" to false),
            "tun" to linkedMapOf(
                "enable" to true, "stack" to "mips", "mtu" to mtu,
                "auto-route" to false, "auto-detect-interface" to false,
                "dns-hijack" to listOf("172.19.0.2:53"), "inet6-address" to emptyList<String>(),
            ),
            "proxies" to listOf(proxy),
            "proxy-groups" to listOf(mapOf("name" to "PROXY", "type" to "select", "proxies" to listOf(name))),
            "rules" to listOf(if (mode == "direct") "MATCH,DIRECT" else "MATCH,PROXY"),
        )
        // JSON is the unambiguous flow-style subset of YAML accepted by yaml.v3.
        val yaml = "# TEMPORARY Phase 2b; rule subscriptions deferred to Phase 3\n" +
            "# Android TUN: 172.19.0.1/30; DNS 172.19.0.2; IPv6 " +
            (if (ipv6) "fdfe:dcba:9876::1/126" else "disabled") + "\n" + encode(root) + "\n"
        return Result(yaml, name, proxy)
    }

    private fun proxy(uri: URI, name: String): Map<String, Any?> {
        require(!uri.host.isNullOrEmpty() && uri.port in 1..65535) { "Mihomo: invalid VLESS server/port" }
        val uuid = decode(uri.rawUserInfo.orEmpty())
        require(UUID.matches(uuid)) { "Mihomo: invalid VLESS UUID" }
        val query = linkedMapOf<String, String>()
        uri.rawQuery?.split('&')?.filter(String::isNotEmpty)?.forEach { part ->
            val key = decodeQuery(part.substringBefore('='))
            require(key in QUERY_KEYS && key !in query) { "Mihomo: unsupported/duplicate VLESS option: $key" }
            query[key] = decodeQuery(part.substringAfter('=', ""))
        }
        fun q(key: String, fallback: String = "") = query[key]?.trim() ?: fallback
        require(q("encryption", "none") in setOf("", "none")) { "Mihomo: VLESS encryption not admitted" }
        require(q("allowInsecure", "false") in setOf("", "false", "0")) { "Mihomo: insecure TLS not admitted" }
        require(q("headerType", "none") in setOf("", "none")) { "Mihomo: TCP header transport not admitted" }
        val network = when (val type = q("type", "tcp").lowercase()) {
            "tcp", "raw" -> "tcp"
            "grpc" -> "grpc"
            "ws", "websocket", "httpupgrade" -> "ws"
            "xhttp", "splithttp" -> error("Mihomo: XHTTP is not admitted by the native engine (DIALERS.md)")
            else -> error("Mihomo: unsupported VLESS transport: $type")
        }
        val security = q("security", "none").ifBlank { "none" }.lowercase()
        require(security in setOf("none", "tls", "reality")) { "Mihomo: unsupported VLESS security" }
        require(security != "reality" || network != "ws") { "Mihomo: REALITY over WS/HTTPUpgrade is not admitted" }
        val flow = q("flow")
        require(flow in setOf("", "xtls-rprx-vision")) { "Mihomo: unsupported VLESS flow" }
        return linkedMapOf<String, Any?>(
            "name" to name, "type" to "vless", "server" to uri.host.removeSurrounding("[", "]"),
            "port" to uri.port, "uuid" to uuid, "udp" to true,
            "network" to network, "tls" to (security != "none"),
        ).apply {
            if (flow.isNotEmpty()) put("flow", flow)
            if (security != "none") {
                put("servername", q("sni", uri.host.removeSurrounding("[", "]")))
                put("client-fingerprint", q("fp", "chrome"))
                if (q("alpn").isNotEmpty()) put("alpn", q("alpn").split(','))
            }
            if (security == "reality") {
                require(Regex("[A-Za-z0-9_-]{43}").matches(q("pbk"))) { "Mihomo: invalid REALITY public key" }
                require(Regex("(?:[a-fA-F0-9]{2}){0,8}").matches(q("sid"))) { "Mihomo: invalid REALITY short ID" }
                put("reality-opts", mapOf("public-key" to q("pbk"), "short-id" to q("sid")))
            }
            when (network) {
                "grpc" -> put("grpc-opts", mapOf("grpc-service-name" to q("serviceName")))
                "ws" -> put("ws-opts", linkedMapOf<String, Any?>("path" to q("path", "/")).apply {
                    if (q("host").isNotEmpty()) put("headers", mapOf("Host" to q("host")))
                    if (q("type").lowercase() == "httpupgrade") put("v2ray-http-upgrade", true)
                })
            }
        }
    }

    private fun decode(value: String) = URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
    private fun decodeQuery(value: String) = URLDecoder.decode(value, "UTF-8")

    internal fun encode(value: Any?): String = when (value) {
        null -> "null"
        is String -> "\"" + buildString {
            value.forEach { c -> when (c) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                else -> if (c.code < 32 || c == '\u2028' || c == '\u2029') append("\\u%04x".format(c.code)) else append(c)
            } }
        } + "\""
        is Boolean, is Number -> value.toString()
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { encode(it.key.toString()) + ":" + encode(it.value) }
        is List<*> -> value.joinToString(",", "[", "]", transform = ::encode)
        else -> error("Unsupported YAML value")
    }

    private const val PREFIX = "# proxima-vless-reality-link:"
    private val UUID = Regex("[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}")
    private val RESERVED = setOf("DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE", "GLOBAL", "PROXY")
    private val QUERY_KEYS = setOf("type", "security", "encryption", "sni", "fp", "pbk", "sid", "flow", "alpn", "path", "host", "serviceName", "allowInsecure", "headerType")
}

/** Exact engine dispatch: no implicit fallback after a Mihomo failure. */
internal fun <T> dispatchVpnEngine(engine: String, xray: () -> T, mihomo: () -> T): T = when (engine) {
    "xray" -> xray()
    "mihomo" -> mihomo()
    else -> error("Unsupported VPN engine: $engine")
}
