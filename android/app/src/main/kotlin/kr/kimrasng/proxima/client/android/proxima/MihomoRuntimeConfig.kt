package kr.kimrasng.proxima.client.android.proxima

import org.json.JSONObject

/** Parse only the Dart JSON-subset YAML envelope needed for Android consistency
 * and UI. Do not translate proxies/rules; native admission is authoritative.
 */
internal class MihomoRuntimeConfig(val bytes: ByteArray, mtu: Int, ipv6: Boolean) {
    private val root = JSONObject(String(bytes, Charsets.UTF_8))
    val nodes: List<Pair<String, String>>
    val selected: String

    init {
        require(bytes.isNotEmpty() && bytes.size <= MihomoConfiguration.MAX_BYTES) { "Mihomo 실행 설정이 8MB를 초과합니다." }
        val tun = root.getJSONObject("tun")
        MihomoProfileAssembler.verify(tun.opt("mtu"), tun.opt("stack"), root.opt("ipv6"), mtu, ipv6)
        require(!tun.has("inet4-address") && !tun.has("inet6-address")) { "Mihomo TUN 주소는 Android 빌더가 소유합니다." }
        val proxies = root.getJSONArray("proxies")
        nodes = (0 until proxies.length()).map {
            val proxy = proxies.getJSONObject(it)
            proxy.getString("name") to proxy.getString("type")
        }
        val groups = root.getJSONArray("proxy-groups")
        val selector = (0 until groups.length()).map(groups::getJSONObject).single { it.getString("name") == "PROXY" }
        selected = selector.getJSONArray("proxies").getString(0)
        require(nodes.any { it.first == selected }) { "Mihomo 선택 노드가 실행 설정에 없습니다." }
    }
}
