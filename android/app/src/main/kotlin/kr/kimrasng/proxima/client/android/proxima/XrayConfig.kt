package kr.kimrasng.proxima.client.android.proxima

import android.net.Uri
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

data class XrayRuntimeConfig(
    val json: JSONObject,
    val activeNode: String?,
    val probePorts: Map<String, Int>,
)

/** Converts Proxima's VLESS+REALITY-only stored links to an Xray configuration. */
object XrayConfig {
    private const val METADATA_PREFIX = "# proxima-vless-reality-link:"

    fun build(
        profile: StoredProfile,
        content: String,
        settings: NativeVpnSettings,
        tunFd: Int? = null,
        metricsPort: Int? = null,
        probePorts: Map<String, Int> = emptyMap(),
        accessLogPath: String? = null,
    ): XrayRuntimeConfig {
        val sourceLinks = links(content)
        val names = uniqueNodeNames(sourceLinks, profile.name)
        val nodes = convertedNodes(sourceLinks, names)
        val selected = VpnSettingsRepositoryHolder.selected(profile.id)
        val requestedName = when (settings.mode) {
            "global" -> selected["GLOBAL"]
            "rule" -> selected["PROXY"] ?: selected["GLOBAL"]
            else -> null
        }
        val activeIndex = names.indexOf(requestedName).takeIf { it >= 0 } ?: 0
        val activeTag = names[activeIndex]
        val directTag = "proxima-direct"
        val outbounds = JSONArray()
        for (index in 0 until nodes.length()) outbounds.put(nodes.getJSONObject(index))
        outbounds.put(JSONObject().put("tag", directTag).put("protocol", "freedom"))
        val rules = JSONArray().put(
            JSONObject()
                .put("type", "field")
                .put("inboundTag", JSONArray().put("proxima-tun"))
                .put("outboundTag", if (settings.mode == "direct") directTag else activeTag),
        )
        val inbounds = JSONArray()
        val config = JSONObject()
            .put(
                "log",
                JSONObject().put("loglevel", "warning").apply {
                    accessLogPath?.takeIf { it.isNotBlank() }?.let { put("access", it) }
                },
            )
            .put("outbounds", outbounds)
            .put("routing", JSONObject().put("domainStrategy", "AsIs").put("rules", rules))
        if (metricsPort != null) {
            config
                .put("metrics", JSONObject().put("listen", "127.0.0.1:$metricsPort"))
                .put(
                    "policy",
                    JSONObject().put(
                        "system",
                        JSONObject()
                            .put("statsInboundUplink", true)
                            .put("statsInboundDownlink", true)
                            .put("statsOutboundUplink", true)
                            .put("statsOutboundDownlink", true),
                    ),
                )
                .put("stats", JSONObject())
        }
        if (tunFd != null) {
            config.put("env", JSONObject().put("xray.tun.fd", tunFd.toString()))
            inbounds.put(
                JSONObject()
                    .put("tag", "proxima-tun")
                    .put("protocol", "tun")
                    .put("settings", JSONObject().put("name", "proxima").put("mtu", settings.mtu)),
            )
        }
        names.forEachIndexed { index, name ->
            val port = probePorts[name] ?: return@forEachIndexed
            require(port in 1..65535) { "Xray 노드 검사 포트가 올바르지 않습니다." }
            val tag = "proxima-probe-$index"
            inbounds.put(
                JSONObject()
                    .put("tag", tag)
                    .put("listen", "127.0.0.1")
                    .put("port", port)
                    .put("protocol", "socks")
                    .put("settings", JSONObject().put("auth", "noauth").put("udp", true)),
            )
            rules.put(
                JSONObject()
                    .put("type", "field")
                    .put("inboundTag", JSONArray().put(tag))
                    .put("outboundTag", name),
            )
        }
        if (inbounds.length() > 0) config.put("inbounds", inbounds)
        return XrayRuntimeConfig(
            json = config,
            activeNode = activeTag.takeUnless { settings.mode == "direct" },
            probePorts = probePorts.filterKeys(names::contains),
        )
    }

    /** Validates every saved link without creating a second managed Xray instance. */
    fun validate(content: String) {
        val sourceLinks = links(content)
        val names = uniqueNodeNames(sourceLinks, "")
        convertedNodes(sourceLinks, names)
    }

    fun proxyState(
        profile: StoredProfile,
        content: String,
        selected: Map<String, String>,
        activeNode: String? = null,
        activeMode: String? = null,
    ): JSONObject {
        val names = nodeNames(profile, content)
        require(names.isNotEmpty()) { "VLESS + REALITY 노드를 찾을 수 없습니다." }
        val all = JSONArray(names)
        val proxies = JSONObject()
            .put(
                "GLOBAL",
                JSONObject()
                    .put("type", "Selector")
                    .put(
                        "now",
                        activeNode?.takeIf { activeMode == "global" && it in names }
                            ?: selected["GLOBAL"]?.takeIf(names::contains)
                            ?: names.first(),
                    )
                    .put("all", all),
            )
            .put(
                "PROXY",
                JSONObject()
                    .put("type", "Selector")
                    .put(
                        "now",
                        activeNode?.takeIf { activeMode == "rule" && it in names }
                            ?: selected["PROXY"]?.takeIf(names::contains)
                            ?: selected["GLOBAL"]?.takeIf(names::contains)
                            ?: names.first(),
                    )
                    .put("all", JSONArray(names)),
            )
        names.forEach { name ->
            proxies.put(name, JSONObject().put("type", "Vless"))
        }
        return JSONObject().put("proxies", proxies)
    }

    fun nodeNames(profile: StoredProfile, content: String): List<String> =
        uniqueNodeNames(links(content), profile.name)

    fun links(content: String): List<String> = content.lineSequence().mapNotNull { line ->
        val encoded = line.trim().takeIf { it.startsWith(METADATA_PREFIX) }
            ?.removePrefix(METADATA_PREFIX)?.trim() ?: return@mapNotNull null
        runCatching {
            val padded = encoded.padEnd((encoded.length + 3) / 4 * 4, '=')
            String(Base64.decode(padded, Base64.URL_SAFE or Base64.NO_WRAP), Charsets.UTF_8)
        }.getOrNull()
    }.toList()

    // Set by the service immediately before construction; this keeps profile parsing pure.
    object VpnSettingsRepositoryHolder { var selected: (String) -> Map<String, String> = { emptyMap() } }

    private fun convertedNodes(sourceLinks: List<String>, names: List<String>): JSONArray {
        require(sourceLinks.isNotEmpty()) { "VLESS + REALITY 노드를 찾을 수 없습니다." }
        val converted = XrayCore.convertShareLinks(sourceLinks)
        require(converted.length() == sourceLinks.size) {
            "libXray가 일부 VLESS + REALITY 노드를 지원하지 않습니다."
        }
        for (index in names.indices) {
            converted.getJSONObject(index).put("tag", names[index])
        }
        return converted
    }

    private fun uniqueNodeNames(sourceLinks: List<String>, profileName: String): List<String> {
        if (sourceLinks.size == 1 && profileName.isNotBlank()) return listOf(profileName.trim())
        val counts = mutableMapOf<String, Int>()
        return sourceLinks.map { link ->
            val uri = Uri.parse(link)
            val fragment = runCatching {
                Uri.decode(uri.encodedFragment.orEmpty()).trim()
            }.getOrDefault("")
            val base = fragment.ifBlank { uri.host ?: "VLESS REALITY" }
            val count = (counts[base] ?: 0) + 1
            counts[base] = count
            if (count == 1) base else "$base $count"
        }
    }

}
