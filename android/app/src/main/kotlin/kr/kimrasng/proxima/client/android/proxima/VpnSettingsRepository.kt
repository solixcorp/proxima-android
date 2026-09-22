package kr.kimrasng.proxima.client.android.proxima

import android.content.Context
import org.json.JSONObject

data class NativeVpnSettings(
    val stack: String,
    val ipv6: Boolean,
    val mtu: Int,
    val mode: String,
) {
    fun asMap(): Map<String, Any> = mapOf("stack" to stack, "ipv6" to ipv6, "mtu" to mtu, "mode" to mode)
}

class VpnSettingsRepository(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("proxima_settings", Context.MODE_PRIVATE)

    fun load(): NativeVpnSettings = NativeVpnSettings(
        stack = preferences.getString("stack", "mixed")?.takeIf { it in ALLOWED_STACKS } ?: "mixed",
        ipv6 = preferences.getBoolean("ipv6", true),
        mtu = preferences.getInt("mtu", 1400).takeIf { it in ALLOWED_MTUS } ?: 1400,
        mode = preferences.getString("mode", "rule")?.takeIf { it in ALLOWED_MODES } ?: "rule",
    )

    fun save(stack: String?, ipv6: Boolean?, mtu: Int?, mode: String?) {
        val current = load()
        preferences.edit()
            .putString("stack", stack?.takeIf { it in ALLOWED_STACKS } ?: current.stack)
            .putBoolean("ipv6", ipv6 ?: current.ipv6)
            .putInt("mtu", mtu?.takeIf { it in ALLOWED_MTUS } ?: current.mtu)
            .putString("mode", mode?.takeIf { it in ALLOWED_MODES } ?: current.mode)
            .apply()
    }

    fun selectedProxies(profileId: String): Map<String, String> {
        val json = runCatching {
            JSONObject(preferences.getString(selectedProxiesKey(profileId), "{}") ?: "{}")
        }.getOrElse { JSONObject() }
        return buildMap {
            for (key in json.keys()) {
                val value = json.optString(key)
                if (key.isNotBlank() && value.isNotBlank()) put(key, value)
            }
        }
    }

    fun saveSelectedProxy(profileId: String, group: String, proxy: String) {
        if (profileId.isBlank() || group.isBlank() || proxy.isBlank()) return
        val selected = JSONObject(selectedProxies(profileId)).put(group, proxy)
        preferences.edit().putString(selectedProxiesKey(profileId), selected.toString()).apply()
    }

    private fun selectedProxiesKey(profileId: String) = "selected_proxies_$profileId"

    companion object {
        private val ALLOWED_STACKS = setOf("system", "gvisor", "mixed")
        private val ALLOWED_MTUS = setOf(1280, 1400, 1500, 9000)
        private val ALLOWED_MODES = setOf("rule", "global", "direct")
    }
}
