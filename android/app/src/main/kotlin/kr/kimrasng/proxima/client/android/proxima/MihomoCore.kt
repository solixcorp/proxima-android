package kr.kimrasng.proxima.client.android.proxima

import android.content.Context
import io.github.oviron.libmihomo.Clash
import org.json.JSONObject
import java.util.UUID

object MihomoCore {
    @Synchronized
    fun ensureLoaded(context: Context) {
        if (!Clash.isLoaded()) Clash.load(context.applicationInfo.nativeLibraryDir)
        Clash.assertReady()
    }

    fun info(context: Context): Map<String, Any?> {
        val error = runCatching { ensureLoaded(context) }.exceptionOrNull()
        return mapOf(
            "loaded" to (error == null && Clash.isLoaded()),
            "bridgeAbi" to if (error == null) runCatching { Clash.bridgeABI() }.getOrNull() else null,
            "coreVersion" to "1.19.28",
            "error" to error?.message,
        )
    }

    fun invoke(method: String, data: String, callback: (String) -> Unit) {
        val action = JSONObject()
            .put("id", UUID.randomUUID().toString())
            .put("method", method)
            .put("data", data)
        Clash.invokeAction(action.toString()) { result -> callback(result ?: "") }
    }
}
