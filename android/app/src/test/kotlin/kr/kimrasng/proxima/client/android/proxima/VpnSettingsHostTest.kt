package kr.kimrasng.proxima.client.android.proxima

import android.content.Context
import android.content.SharedPreferences

private class MemoryPreferences : SharedPreferences, SharedPreferences.Editor {
    val values = mutableMapOf<String, Any?>()
    override fun getString(key: String, default: String?) = values[key] as? String ?: default
    override fun getBoolean(key: String, default: Boolean) = values[key] as? Boolean ?: default
    override fun getInt(key: String, default: Int) = values[key] as? Int ?: default
    override fun edit(): SharedPreferences.Editor = this
    override fun putString(key: String, value: String?) = apply { values[key] = value }
    override fun putBoolean(key: String, value: Boolean) = apply { values[key] = value }
    override fun putInt(key: String, value: Int) = apply { values[key] = value }
    override fun apply() {}
}

private class MemoryContext(val prefs: MemoryPreferences) : Context() {
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = prefs
}

object VpnSettingsHostTest {
    @JvmStatic fun main(args: Array<String>) {
        val prefs = MemoryPreferences()
        val repository = VpnSettingsRepository(MemoryContext(prefs))
        check(repository.load().engine == "xray")
        check(repository.load().asMap()["engine"] == "xray")
        repository.save(null, null, 1500, null, engine = "mihomo")
        val reloaded = VpnSettingsRepository(MemoryContext(prefs))
        check(reloaded.load().engine == "mihomo")
        check(reloaded.load().mtu == 1500)
        reloaded.save(null, false, null, null, engine = "invalid")
        check(reloaded.load().engine == "mihomo")
        reloaded.save(null, null, null, null, engine = "xray")
        check(reloaded.load().engine == "xray")
        prefs.values["engine"] = "invalid"
        check(reloaded.load().engine == "xray")
        println("PASS VpnSettings engine persistence and defaults")
    }
}
