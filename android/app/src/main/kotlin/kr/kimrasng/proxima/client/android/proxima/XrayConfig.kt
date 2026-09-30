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

/** Converts Proxima's VLESS stored links to an Xray configuration. */
object XrayConfig {
    private const val METADATA_PREFIX = "# proxima-vless-reality-link:"
    private const val ROUTING_PREFIX = "# proxima-routing-rules:"
    const val RULE_PROBE_KEY = "__PROXIMA_RULE__"
    private const val RULE_PROBE_TAG = "proxima-rule-probe"
    private const val AUTO_BALANCER_TAG = "proxima-auto"
    private const val DNS_OUTBOUND_TAG = "proxima-dns"
    private const val DNS_UPSTREAM_TAG = "proxima-dns-upstream"

    fun build(
        profile: StoredProfile,
        content: String,
        settings: NativeVpnSettings,
        tunFd: Int? = null,
        metricsPort: Int? = null,
        probePorts: Map<String, Int> = emptyMap(),
        accessLogPath: String? = null,
        upstreamDns: String = "1.1.1.1",
    ): XrayRuntimeConfig {
        val sourceLinks = links(content)
        val names = uniqueNodeNames(sourceLinks, profile.name)
        val tags = names.indices.map { index -> "proxima-node-$index-${names[index]}" }
        val nodes = convertedNodes(sourceLinks, tags)
        val serverDomains = nodeServerDomains(nodes, sourceLinks)
        val selected = VpnSettingsRepositoryHolder.selected(profile.id)
        val requestedName = when (settings.mode) {
            "global" -> selected["GLOBAL"]
            "rule" -> selected["PROXY"] ?: selected["GLOBAL"]
            else -> null
        }
        val activeIndex = names.indexOf(requestedName).takeIf { it >= 0 } ?: 0
        val activeTag = tags[activeIndex]
        val directTag = "proxima-direct"
        val blockTag = "proxima-block"
        val storedRouting = routing(content)
        val useSubscriptionRules = settings.mode == "rule" && storedRouting != null
        val outbounds = JSONArray()
        for (index in 0 until nodes.length()) outbounds.put(nodes.getJSONObject(index))
        outbounds.put(JSONObject().put("tag", directTag).put("protocol", "freedom"))
        outbounds.put(
            JSONObject()
                .put("tag", DNS_OUTBOUND_TAG)
                .put("protocol", "dns")
                .apply {
                    if (settings.mode != "direct") {
                        put(
                            "streamSettings",
                            JSONObject().put(
                                "sockopt",
                                JSONObject().put("dialerProxy", activeTag),
                            ),
                        )
                    }
                }
                .put(
                    "settings",
                    JSONObject()
                        .put("rewriteNetwork", "tcp")
                        .put("rewriteAddress", if (settings.mode == "direct") upstreamDns else "1.1.1.1")
                        .put("rewritePort", 53)
                        // The built-in DNS handles A/AAAA through DoH. Forward
                        // other record types over TCP instead of leaking UDP.
                        .put(
                            "rules",
                            JSONArray()
                                .put(JSONObject().put("action", "hijack").put("qType", 1))
                                .put(JSONObject().put("action", "hijack").put("qType", 28))
                                .put(JSONObject().put("action", "direct")),
                        ),
                ),
        )
        if (useSubscriptionRules) {
            outbounds.put(JSONObject().put("tag", blockTag).put("protocol", "blackhole"))
        }
        val rules = JSONArray()
        val policyBalancers = if (useSubscriptionRules) {
            policyBalancers(storedRouting.rules, names, tags)
        } else emptyMap()
        // DNS packets from the TUN are plain DNS, not DoH. The DNS outbound
        // hands A/AAAA to the built-in resolver; its DoH connection is then
        // routed through VLESS as a regular TCP request.
        rules.put(
            JSONObject()
                .put("type", "field")
                .put("inboundTag", JSONArray().put("proxima-tun"))
                .put("network", "tcp,udp")
                .put("port", "53")
                .put("outboundTag", DNS_OUTBOUND_TAG),
        )
        rules.put(
            JSONObject()
                .put("type", "field")
                .put("inboundTag", JSONArray().put(DNS_UPSTREAM_TAG))
                .put("outboundTag", if (settings.mode == "direct") directTag else activeTag),
        )
        if (useSubscriptionRules) {
            storedRouting.rules.forEach { storedRule ->
                val rule = convertRule(storedRule, directTag, blockTag, activeTag, policyBalancers)
                    ?: return@forEach
                if (storedRule.optString("target") == "direct" && rule.optString("network") != "tcp") {
                    // A DIRECT UDP rule would still use the blocked physical
                    // transport. Keep its position and conditions, but send
                    // only its UDP half through the selected VLESS node.
                    rules.put(
                        JSONObject(rule.toString())
                            .put("network", "udp")
                            .put("outboundTag", activeTag),
                    )
                    if (rule.optString("network") == "udp") return@forEach
                    rule.put("network", "tcp")
                }
                rules.put(rule)
            }
        } else {
            rules.put(
                JSONObject()
                    .put("type", "field")
                    .put("inboundTag", JSONArray().put("proxima-tun"))
                    .put("outboundTag", if (settings.mode == "direct") directTag else activeTag),
            )
        }
        val inbounds = JSONArray()
        val routingConfig = JSONObject()
            .put("domainStrategy", if (useSubscriptionRules) "IPIfNonMatch" else "AsIs")
            .put("rules", rules)
        if (useSubscriptionRules) {
            val balancers = JSONArray().put(
                JSONObject()
                    .put("tag", AUTO_BALANCER_TAG)
                    .put("selector", JSONArray(tags))
                    .put("fallbackTag", activeTag)
                    .put("strategy", JSONObject().put("type", "leastPing")),
            )
            policyBalancers.forEach { (_, value) ->
                balancers.put(
                    JSONObject()
                        .put("tag", value.first)
                        .put("selector", JSONArray(value.second))
                        .put(
                            "fallbackTag",
                            activeTag.takeIf(value.second::contains) ?: value.second.first(),
                        )
                        .put("strategy", JSONObject().put("type", "leastPing")),
                )
            }
            routingConfig.put(
                "balancers",
                balancers,
            )
        }
        val config = JSONObject()
            .put(
                "log",
                JSONObject().put("loglevel", "warning").apply {
                    accessLogPath?.takeIf { it.isNotBlank() }?.let { put("access", it) }
                },
            )
            .put("outbounds", outbounds)
            .put("routing", routingConfig)
            .put("dns", dnsConfig(serverDomains, upstreamDns))
        if (useSubscriptionRules) {
            config.put(
                "observatory",
                JSONObject()
                    .put("subjectSelector", JSONArray(tags))
                    .put("probeURL", storedRouting.testUrl)
                    .put("probeInterval", "10m")
                    .put("enableConcurrency", true),
            )
        }
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
                    .put("settings", JSONObject().put("name", "proxima").put("mtu", settings.mtu))
                    // Android apps send the TUN inbound an IP address, not a
                    // hostname. Without sniffing every DOMAIN-SUFFIX rule
                    // misses and Xray falls through to one fastest node.
                    // routeOnly preserves the original IP for the connection
                    // while exposing TLS/HTTP/QUIC hostnames to routing.
                    .put(
                        "sniffing",
                        JSONObject()
                            .put("enabled", true)
                            .put("destOverride", JSONArray().put("http").put("tls").put("quic"))
                            .put("routeOnly", true),
                    ),
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
                    .put("outboundTag", tags[index]),
            )
        }
        if (useSubscriptionRules) {
            probePorts[RULE_PROBE_KEY]?.let { port ->
                require(port in 1..65535) { "Xray 규칙 검사 포트가 올바르지 않습니다." }
                inbounds.put(
                    JSONObject()
                        .put("tag", RULE_PROBE_TAG)
                        .put("listen", "127.0.0.1")
                        .put("port", port)
                        .put("protocol", "socks")
                        .put("settings", JSONObject().put("auth", "noauth").put("udp", true)),
                )
            }
        }
        if (inbounds.length() > 0) config.put("inbounds", inbounds)
        return XrayRuntimeConfig(
            json = config,
            activeNode = names[activeIndex].takeUnless { settings.mode == "direct" || useSubscriptionRules },
            probePorts = probePorts.filterKeys { it in names || (useSubscriptionRules && it == RULE_PROBE_KEY) },
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
        require(names.isNotEmpty()) { "VLESS 노드를 찾을 수 없습니다." }
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
    }.filterNot(::isInformationLink).toList()

    // Set by the service immediately before construction; this keeps profile parsing pure.
    object VpnSettingsRepositoryHolder { var selected: (String) -> Map<String, String> = { emptyMap() } }

    private fun convertedNodes(sourceLinks: List<String>, names: List<String>): JSONArray {
        require(sourceLinks.isNotEmpty()) { "VLESS 노드를 찾을 수 없습니다." }
        val converted = XrayCore.convertShareLinks(sourceLinks)
        require(converted.length() == sourceLinks.size) {
            "libXray가 일부 VLESS 노드를 지원하지 않습니다."
        }
        for (index in names.indices) {
            converted.getJSONObject(index).put("tag", names[index])
        }
        return converted
    }

    private fun nodeServerDomains(nodes: JSONArray, sourceLinks: List<String>): List<String> = buildList {
        for (index in 0 until nodes.length()) {
            val outbound = nodes.getJSONObject(index)
            val convertedAddress = outbound.optJSONObject("settings")
                ?.optJSONArray("vnext")?.optJSONObject(0)?.optString("address")
            val address = (convertedAddress?.takeIf { it.isNotBlank() }
                ?: Uri.parse(sourceLinks[index]).host.orEmpty())
                .trim().trimEnd('.').lowercase()
            if (address.isEmpty() || ':' in address || address.all { it.isDigit() || it == '.' }) {
                continue
            }
            if (address !in this) add(address)
            // Resolve the proxy server through Xray's built-in DNS, which has
            // a separate physical TCP bootstrap path for these hostnames.
            val stream = outbound.optJSONObject("streamSettings") ?: JSONObject().also {
                outbound.put("streamSettings", it)
            }
            val sockopt = stream.optJSONObject("sockopt") ?: JSONObject().also {
                stream.put("sockopt", it)
            }
            sockopt.put("domainStrategy", "UseIP")
        }
    }

    private fun dnsConfig(serverDomains: List<String>, upstreamDns: String): JSONObject {
        val servers = JSONArray()
        if (serverDomains.isNotEmpty()) {
            val domains = JSONArray(serverDomains.map { "full:$it" })
            val tcpAddress = if (':' in upstreamDns) "[$upstreamDns]" else upstreamDns
            servers.put(
                JSONObject()
                    .put("address", "tcp+local://$tcpAddress:53")
                    .put("domains", domains)
                    .put("skipFallback", true),
            )
            servers.put(
                JSONObject()
                    .put("address", "https+local://1.1.1.1/dns-query")
                    .put("domains", domains)
                    .put("skipFallback", true),
            )
            servers.put(
                JSONObject()
                    .put("address", "https+local://8.8.8.8/dns-query")
                    .put("domains", domains)
                    .put("skipFallback", true),
            )
        }
        servers.put("https://1.1.1.1/dns-query")
        servers.put("https://8.8.8.8/dns-query")
        return JSONObject()
            .put("servers", servers)
            .put("tag", DNS_UPSTREAM_TAG)
            .put("disableFallbackIfMatch", true)
    }

    private data class StoredRouting(val rules: List<JSONObject>, val testUrl: String)

    private fun routing(content: String): StoredRouting? {
        val encoded = content.lineSequence().map { it.trim() }
            .firstOrNull { it.startsWith(ROUTING_PREFIX) }
            ?.removePrefix(ROUTING_PREFIX)?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return null
        return runCatching {
            val padded = encoded.padEnd((encoded.length + 3) / 4 * 4, '=')
            val root = JSONObject(
                String(Base64.decode(padded, Base64.URL_SAFE or Base64.NO_WRAP), Charsets.UTF_8),
            )
            require(root.optInt("version") in 1..2) { "지원하지 않는 라우팅 메타데이터입니다." }
            val sourceRules = root.optJSONArray("rules") ?: JSONArray()
            val parsed = buildList {
                for (index in 0 until sourceRules.length()) {
                    sourceRules.optJSONObject(index)?.let(::add)
                }
            }
            require(parsed.isNotEmpty()) { "구독 라우팅 규칙이 비어 있습니다." }
            StoredRouting(
                rules = parsed,
                testUrl = root.optString("autoTestUrl")
                    .takeIf { it.startsWith("https://") }
                    ?: "https://www.gstatic.com/generate_204",
            )
        }.getOrElse { throw IllegalArgumentException("구독 라우팅 규칙을 읽지 못했습니다.", it) }
    }

    private fun convertRule(
        source: JSONObject,
        directTag: String,
        blockTag: String,
        activeTag: String,
        policyBalancers: Map<String, Pair<String, List<String>>>,
    ): JSONObject? {
        val target = source.optString("target")
        if (target !in setOf("direct", "block", "proxy")) return null
        val rule = JSONObject()
            .put("type", "field")
            .put("inboundTag", JSONArray().put("proxima-tun").put(RULE_PROBE_TAG))
        copyArray(source, rule, "domain")
        copyArray(source, rule, "ip", transform = ::expandGeoIp)
        source.optString("network").takeIf { it in setOf("tcp", "udp", "tcp,udp") }
            ?.let { rule.put("network", it) }
        source.optString("port").takeIf { it.matches(Regex("^[0-9,:-]+$")) }
            ?.let { rule.put("port", it) }

        // The AAR intentionally contains no external geosite/geoip data files.
        // Keep private-network semantics locally and skip data-file-dependent
        // entries. geolocation-!cn is followed by MATCH to the same proxy path.
        val domains = rule.optJSONArray("domain")
        if (domains != null) {
            val normalized = JSONArray()
            for (index in 0 until domains.length()) {
                when (val value = domains.optString(index)) {
                    "geosite:private" -> listOf(
                        "domain:lan", "domain:local", "full:localhost", "domain:home.arpa",
                    ).forEach(normalized::put)
                    else -> if (!value.startsWith("geosite:")) normalized.put(value)
                }
            }
            rule.put("domain", normalized)
        }
        val hasCondition = listOf("domain", "ip", "network", "port").any { key ->
            when (val value = rule.opt(key)) {
                is JSONArray -> value.length() > 0
                is String -> value.isNotBlank()
                else -> false
            }
        }
        if (source.optBoolean("match", false).not() && !hasCondition) return null
        when (target) {
            "direct" -> rule.put("outboundTag", directTag)
            "block" -> rule.put("outboundTag", blockTag)
            "proxy" -> {
                val policy = policyBalancers[source.optString("policy")]
                // A successful global selection is a better default than a
                // latency probe that may choose a node unable to carry app
                // traffic. Keep restricted policy pools when it is excluded.
                if (policy == null || activeTag in policy.second) {
                    rule.put("outboundTag", activeTag)
                } else {
                    rule.put("balancerTag", policy.first)
                }
            }
        }
        return rule
    }

    private fun policyBalancers(
        rules: List<JSONObject>,
        names: List<String>,
        tags: List<String>,
    ): Map<String, Pair<String, List<String>>> {
        val result = linkedMapOf<String, Pair<String, List<String>>>()
        rules.forEach { rule ->
            if (rule.optString("target") != "proxy") return@forEach
            val policy = rule.optString("policy").trim()
            if (policy.isEmpty() || policy in result) return@forEach
            // Version 2 metadata carries the actual node candidates behind a
            // Clash group. Prefer that set; the old policy-name country hint
            // remains as a compatibility fallback for existing profiles.
            val configuredCandidates = rule.optJSONArray("candidates")
                ?.let { candidates ->
                    buildList {
                        for (index in 0 until candidates.length()) {
                            candidates.optString(index)
                                .takeIf(names::contains)
                                ?.let(::add)
                        }
                    }.distinct()
                }
                .orEmpty()
            val selected = configuredCandidates.ifEmpty {
                countryMarker(policy)
                    ?.let { marker -> names.filter { it.contains(marker, ignoreCase = true) } }
                    .orEmpty()
            }
            if (selected.isEmpty()) return@forEach
            result[policy] = "proxima-policy-${result.size}" to
                selected.map { name -> tags[names.indexOf(name)] }
        }
        return result
    }

    private fun countryMarker(policy: String): String? = when {
        policy.contains("🧲 AI") || policy.equals("AI", ignoreCase = true) -> "美国"
        policy.contains("日本媒体") -> "日本"
        policy.contains("韩国媒体") -> "韩国"
        policy.contains("巴哈姆特") || policy.contains("KKTV", ignoreCase = true) ||
            policy.contains("B站港澳台") -> "台湾"
        policy.contains("viuTV", ignoreCase = true) -> "香港"
        policy.contains("B站东南亚") -> "新加坡"
        else -> null
    }

    private fun copyArray(
        source: JSONObject,
        destination: JSONObject,
        key: String,
        transform: (String) -> List<String> = { listOf(it) },
    ) {
        val values = source.optJSONArray(key) ?: return
        val copied = JSONArray()
        for (index in 0 until values.length()) {
            transform(values.optString(index)).filter(String::isNotBlank).forEach(copied::put)
        }
        if (copied.length() > 0) destination.put(key, copied)
    }

    private fun expandGeoIp(value: String): List<String> = when (value) {
        "geoip:private", "geoip:lan" -> listOf(
            "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
            "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4",
            "::1/128", "fc00::/7", "fe80::/10",
        )
        else -> if (value.startsWith("geoip:")) emptyList() else listOf(value)
    }

    private fun isInformationLink(link: String): Boolean {
        val name = runCatching { Uri.decode(Uri.parse(link).encodedFragment.orEmpty()) }
            .getOrDefault("")
        return name.contains("剩余流量") || name.contains("距离下次重置") ||
            name.contains("套餐到期") || name.contains("hello-ssone.com", ignoreCase = true)
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
