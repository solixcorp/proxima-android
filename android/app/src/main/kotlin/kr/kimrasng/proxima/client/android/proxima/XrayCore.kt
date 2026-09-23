package kr.kimrasng.proxima.client.android.proxima

import android.content.Context
import libXray.DialerController
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject

/** Narrow, app-owned adapter around the libXray v3 JSON API. */
object XrayCore {
    @Synchronized
    fun ensureLoaded() {
        // Forces gomobile to load libgojni before the first Invoke call.
        LibXray.touch()
    }

    fun info(context: Context): Map<String, Any?> {
        val error = runCatching { ensureLoaded() }.exceptionOrNull()
        val version = if (error == null) runCatching { invoke("xrayVersion", JSONObject()) }.getOrNull() else null
        return mapOf(
            "loaded" to (error == null),
            "coreVersion" to versionLabel(version),
            "bridgeAbi" to "libXray-v3",
            "error" to error?.message,
        )
    }

    private fun versionLabel(response: JSONObject?): String? {
        val data = response?.opt("data") ?: return null
        val raw = when (data) {
            is JSONObject -> data.optString("version")
            is String -> runCatching {
                JSONObject(data).optString("version").ifBlank { data }
            }.getOrDefault(data)
            else -> data.toString()
        }.trim()
        if (raw.isEmpty()) return null
        return Regex("""\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?""")
            .find(raw)
            ?.value
            ?: raw.trimStart { it.isWhitespace() || it == 'v' || it == 'V' || it == '*' }
    }

    fun configureVpn(controller: DialerController, dnsServer: String?) {
        ensureLoaded()
        LibXray.registerDialerController(controller)
        LibXray.registerListenerController(controller)
        if (!dnsServer.isNullOrBlank()) LibXray.setDNS(controller, dnsServer)
    }

    fun run(config: JSONObject): JSONObject = invoke("runXray", JSONObject().put("xrayJson", config.toString()))

    fun validate(config: JSONObject): JSONObject = invoke("testXray", JSONObject().put("xrayJson", config.toString()))

    /**
     * Lets the bundled libXray parser project share links into buildable Xray
     * outbounds. Unlike testXray, this is safe while the managed core is running.
     */
    fun convertShareLinks(links: List<String>): JSONArray {
        require(links.isNotEmpty()) { "VLESS + REALITY 노드를 찾을 수 없습니다." }
        val response = invoke(
            "convertShareLinksToXrayJson",
            JSONObject().put("text", links.joinToString("\n")),
        )
        return response.optJSONObject("data")
            ?.optJSONArray("outbounds")
            ?: error("libXray가 노드 구성을 반환하지 않았습니다.")
    }

    fun freePorts(count: Int): List<Int> {
        require(count > 0) { "포트 수는 1 이상이어야 합니다." }
        val response = invoke("getFreePorts", JSONObject().put("count", count))
        val ports = response.optJSONObject("data")?.optJSONArray("ports")
            ?: error("Xray 로컬 포트를 할당하지 못했습니다.")
        return buildList {
            for (index in 0 until ports.length()) {
                ports.optInt(index).takeIf { it in 1..65535 }?.let(::add)
            }
        }.also { allocated ->
            require(allocated.size == count) { "Xray 로컬 포트를 모두 할당하지 못했습니다." }
        }
    }

    fun freePort(): Int = freePorts(1).single()

    fun isRunning(): Boolean =
        invoke("getXrayState", JSONObject())
            .optJSONObject("data")
            ?.optBoolean("running", false) == true

    fun stop() {
        runCatching { invoke("stopXray", JSONObject()) }
        runCatching { LibXray.resetDNS() }
    }

    fun invoke(method: String, payload: JSONObject): JSONObject {
        ensureLoaded()
        val request = JSONObject()
            .put("apiVersion", 3)
            .put("method", method)
            .put("payload", payload)
        val response = JSONObject(LibXray.invoke(request.toString()))
        check(response.optBoolean("success", false)) {
            response.optString("error").ifBlank { "Xray 요청을 처리하지 못했습니다." }
        }
        return response
    }
}
