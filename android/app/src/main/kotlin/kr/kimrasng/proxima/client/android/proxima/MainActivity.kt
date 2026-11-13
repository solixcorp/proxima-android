package kr.kimrasng.proxima.client.android.proxima

import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Debug
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var profiles: ProfileRepository
    private lateinit var settings: VpnSettingsRepository
    private lateinit var mihomoSidecars: MihomoConfigSidecar
    private val mihomoUploads = mutableMapOf<String, String>() // profile -> one-use capability
    private var eventSink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private var importResult: MethodChannel.Result? = null
    private var exportResult: MethodChannel.Result? = null
    private var exportContent: String? = null
    // Run independent node probes concurrently instead of serializing timeouts.
    private val coreWorker = Executors.newFixedThreadPool(8)
    private val runtimeListener: (Map<String, Any?>) -> Unit = { value -> eventSink?.success(value) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VpnRuntime.initialize(this)
        profiles = ProfileRepository(this)
        settings = VpnSettingsRepository(this)
        mihomoSidecars = MihomoConfigSidecar(File(filesDir, "mihomo-configs"))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getState" -> result.success(VpnRuntime.snapshot())
                "listProfiles" -> result.success(profiles.list())
                "readProfile" -> result.success(profiles.readContent(requiredString(call, "id")))
                "saveProfile" -> {
                    val content = requiredString(call, "content")
                    result.success(
                        profiles.save(
                            id = call.argument("id"),
                            name = requiredString(call, "name"),
                            sourceUrl = call.argument("sourceUrl"),
                            content = content,
                            subscriptionInfo = call.argument<Map<*, *>>("subscriptionInfo")?.let(
                                StoredSubscriptionInfo::fromMap,
                            ),
                            admissionSummary = call.argument<Map<*, *>>("admissionSummary")?.let(StoredAdmissionSummary::fromMap),
                        ),
                    )
                }
                "deleteProfile" -> {
                    val id = requiredString(call, "id")
                    val state = VpnRuntime.snapshot()
                    val inUse = state["profileId"] == id &&
                        state["state"] in setOf("connecting", "connected", "disconnecting")
                    require(!inUse) {
                        "연결 중인 프로필은 삭제할 수 없습니다."
                    }
                    profiles.delete(id)
                    result.success(null)
                }
                "selectProfile" -> {
                    profiles.select(requiredString(call, "id"))
                    result.success(null)
                }
                "loadProxySelections" -> result.success(
                    settings.selectedProxies(requiredString(call, "profileId")),
                )
                "saveProxySelection" -> {
                    val profileId = requiredString(call, "profileId")
                    require(profiles.profile(profileId) != null) { "Profile not found" }
                    settings.saveSelectedProxy(
                        profileId = profileId,
                        group = requiredString(call, "group"),
                        proxy = requiredString(call, "proxy"),
                    )
                    result.success(null)
                }
                "validateProfile" -> validateProfile(requiredString(call, "content"), result)
                "clearProxySelection" -> {
                    settings.clearSelectedProxy(requiredString(call, "profileId"), requiredString(call, "group"))
                    result.success(null)
                }
                "beginMihomoConfiguration" -> {
                    val id = requiredString(call, "profileId")
                    require(profiles.profile(id) != null) { "Profile not found" }
                    // Any previous upload (including a cancelled preparation)
                    // loses its capability before a fresh start is prepared.
                    mihomoUploads.values.forEach(mihomoSidecars::discard)
                    mihomoUploads.clear()
                    val value = settings.load()
                    val source = profiles.readContent(id)
                    val settingsKey = MihomoConfigSidecar.settingsKey(value.mtu, value.ipv6, value.mode)
                    require(MihomoConfiguration.digest(source.toByteArray(Charsets.UTF_8)) == requiredString(call, "sourceSha256") &&
                        settingsKey == requiredString(call, "settingsKey")) { "Mihomo 조립 중 프로필/설정이 변경되었습니다. 다시 연결해 주세요." }
                    val token = mihomoSidecars.begin(id, source, settingsKey,
                        call.argument<Int>("size") ?: 0)
                    mihomoUploads[id] = token
                    result.success(token)
                }
                "appendMihomoConfiguration" -> {
                    val token = requiredString(call, "token")
                    require(token in mihomoUploads.values) { "Mihomo 설정 전송이 취소되었습니다." }
                    mihomoSidecars.append(token, call.argument<Int>("offset") ?: -1,
                        call.argument<ByteArray>("bytes") ?: byteArrayOf())
                    result.success(null)
                }
                "finishMihomoConfiguration" -> {
                    val token = requiredString(call, "token")
                    require(token in mihomoUploads.values) { "Mihomo 설정 전송이 취소되었습니다." }
                    mihomoSidecars.finish(token)
                    result.success(null)
                }
                "discardMihomoConfiguration" -> {
                    val token = requiredString(call, "token")
                    mihomoSidecars.discard(token)
                    mihomoUploads.entries.removeAll { it.value == token }
                    result.success(null)
                }
                "discardPreparedMihomoConfiguration" -> {
                    mihomoUploads.remove(requiredString(call, "profileId"))?.let(mihomoSidecars::discard)
                    result.success(null)
                }
                "requestVpnPermission" -> requestVpnPermission(result)
                "startVpn" -> startVpn(requiredString(call, "profileId"), result)
                "stopVpn" -> {
                    startService(Intent(this, ProximaVpnService::class.java).setAction(ProximaVpnService.ACTION_STOP))
                    result.success(null)
                }
                "loadSettings" -> result.success(settings.load().asMap())
                "saveSettings" -> {
                    settings.save(
                        stack = call.argument("stack"),
                        ipv6 = call.argument("ipv6"),
                        mtu = call.argument("mtu"),
                        mode = call.argument("mode"),
                        themeMode = call.argument("themeMode"),
                    )
                    result.success(null)
                }
                "pickProfileFile" -> pickProfileFile(result)
                "exportProfileFile" -> exportProfileFile(
                    name = requiredString(call, "name"),
                    content = requiredString(call, "content"),
                    result = result,
                )
                "getNetworkInfo" -> result.success(networkInfo())
                "requestQuickSettingsTile" -> requestQuickSettingsTile(result)
                "requestPinAppWidget" -> requestPinAppWidget(result)
                "coreInfo" -> result.success(mapOf(
                    "loaded" to (VpnRuntime.mihomoSession() != null),
                    "coreVersion" to "Mihomo v1.19.33 (bundled)", "bridgeAbi" to "mihomo-worker-v3", "error" to null,
                ))
                "coreAction" -> invokeCore(
                    method = requiredString(call, "method"),
                    data = call.argument<String>("data") ?: "",
                    result = result,
                )
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("proxima_error", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun validateProfile(content: String, result: MethodChannel.Result) {
        require(content.toByteArray(Charsets.UTF_8).size <= MAX_PROFILE_BYTES) { "프로필은 8MB보다 작아야 합니다." }
        runCatching {
            val value = settings.load()
            MihomoRuntimeConfig(content.toByteArray(Charsets.UTF_8), value.mtu, value.ipv6)
        }.onSuccess { result.success(null) }
            .onFailure { result.success(it.message ?: "프로필을 검증하지 못했습니다.") }
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        if (permissionResult != null) {
            result.error("permission_pending", "VPN 권한 요청이 이미 진행 중입니다.", null)
            return
        }
        permissionResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, VPN_PERMISSION_REQUEST)
    }

    private fun startVpn(profileId: String, result: MethodChannel.Result) {
        require(VpnService.prepare(this) == null) { "VPN permission is required" }
        val profile = profiles.profile(profileId) ?: error("Profile not found")
        val configToken = checkNotNull(mihomoUploads.remove(profileId)) { "Mihomo 설정 사이드카가 없습니다. 앱에서 다시 연결해 주세요." }
            .also(mihomoSidecars::requireReady)
        profiles.select(profileId)
        val state = VpnRuntime.snapshot()
        val preserveSession = state["state"] in setOf("connected", "connecting") &&
            (state["startedAt"] as? Long ?: 0L) > 0L
        if (preserveSession) VpnRuntime.reconnecting(profile) else VpnRuntime.connecting(profile)
        val intent = Intent(this, ProximaVpnService::class.java)
            .setAction(ProximaVpnService.ACTION_START)
            .putExtra(ProximaVpnService.EXTRA_PROFILE_ID, profileId)
            .putExtra(ProximaVpnService.EXTRA_MIHOMO_CONFIG, configToken)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        }.onFailure {
            VpnRuntime.failed(profile, it.message ?: "VPN을 시작하지 못했습니다.")
        }.getOrThrow()
        result.success(null)
    }

    private fun invokeCore(method: String, data: String, result: MethodChannel.Result) {
        require(VpnRuntime.snapshot()["state"] == "connected") { "VPN is not connected" }
        // Capture the running capability before queueing. A delayed Mihomo
        // request must never borrow a replacement session.
        val mihomo = checkNotNull(VpnRuntime.mihomoSession()) { "Mihomo session is not running" }
        val operation = {
            val payload: Any = invokeMihomo(mihomo, method, data)
            JSONObject().put("code", 0).put("data", payload).toString()
        }
        coreWorker.execute {
            runCatching(operation)
                .onSuccess { payload -> runOnUiThread { result.success(payload) } }
                .onFailure { error -> runOnUiThread { result.error("core_action_error", error.message, null) } }
        }
    }

    private fun invokeMihomo(session: MihomoVpnSession, method: String, data: String): Any {
        check(VpnRuntime.mihomoSession() === session) { "Mihomo session was replaced" }
        return when (method) {
            "getProxies" -> session.proxyState()
            "getConnections" -> session.connections()
            "testDelay" -> {
                val request = JSONObject(data)
                session.delayTest(request.optString("proxy-name"),
                    request.optString("test-url", "https://www.gstatic.com/generate_204"),
                    request.optInt("timeout", 3_000))
            }
            "updateConfig" -> {
                error("Mihomo 설정 변경은 앱의 Dart 조립 후 다시 연결해야 합니다.")
            }
            "changeProxy" -> {
                val request = JSONObject(data)
                require(request.optString("group-name") == "GLOBAL") { "지원하지 않는 선택 그룹입니다." }
                session.select(request.getString("proxy-name"))
                JSONObject()
            }
            "getMemory" -> Debug.getPss().toLong() * 1024L
            "queryExternalProviders" -> JSONArray() // JNI has no provider inventory surface yet.
            "probeCurrentProxyIp" -> error("Mihomo 공인 IP 검사는 Phase 3에서 지원합니다.")
            "closeConnection", "closeAllConnections", "updateExternalProvider" -> error("Mihomo JNI가 지원하지 않는 작업입니다: $method")
            else -> error("지원하지 않는 Mihomo 작업입니다: $method")
        }
    }

    private fun pickProfileFile(result: MethodChannel.Result) {
        require(importResult == null) { "파일 선택이 이미 진행 중입니다." }
        importResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
        @Suppress("DEPRECATION")
        startActivityForResult(intent, IMPORT_PROFILE_REQUEST)
    }

    private fun exportProfileFile(name: String, content: String, result: MethodChannel.Result) {
        require(exportResult == null) { "파일 저장이 이미 진행 중입니다." }
        require(content.toByteArray(Charsets.UTF_8).size <= MAX_PROFILE_BYTES) { "프로필은 8MB보다 작아야 합니다." }
        exportResult = result
        exportContent = content
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TITLE, name)
        @Suppress("DEPRECATION")
        startActivityForResult(intent, EXPORT_PROFILE_REQUEST)
    }

    private fun importProfile(data: Intent?) {
        val result = importResult ?: return
        importResult = null
        val uri = data?.data
        if (uri == null) {
            result.success(null)
            return
        }
        runCatching {
            val bytes = ByteArrayOutputStream()
            contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "선택한 파일을 열 수 없습니다." }
                val buffer = ByteArray(8192)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    bytes.write(buffer, 0, read)
                    require(bytes.size() <= MAX_PROFILE_BYTES) { "프로필은 8MB보다 작아야 합니다." }
                }
            }
            mapOf(
                "name" to displayName(uri).substringBeforeLast('.').ifBlank { "가져온 프로필" },
                "content" to bytes.toString(Charsets.UTF_8.name()),
            )
        }.onSuccess(result::success).onFailure { result.error("import_error", it.message, null) }
    }

    private fun saveExport(data: Intent?) {
        val result = exportResult ?: return
        exportResult = null
        val content = exportContent
        exportContent = null
        val uri = data?.data
        if (uri == null || content == null) {
            result.success(false)
            return
        }
        runCatching {
            contentResolver.openOutputStream(uri, "wt").use { output ->
                requireNotNull(output) { "선택한 위치에 저장할 수 없습니다." }
                output.write(content.toByteArray(Charsets.UTF_8))
            }
        }.onSuccess { result.success(true) }
            .onFailure { result.error("export_error", it.message, null) }
    }

    private fun displayName(uri: android.net.Uri): String {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            if (cursor?.moveToFirst() == true) cursor.getString(0) else "가져온 프로필.yaml"
        } finally {
            cursor?.close()
        }
    }

    private fun networkInfo(): Map<String, Any> {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivity.activeNetwork
        val capabilities = network?.let(connectivity::getNetworkCapabilities)
        val properties = network?.let(connectivity::getLinkProperties)
        val transport = when {
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "Wi-Fi"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "모바일 데이터"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "이더넷"
            capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true -> "VPN"
            else -> "연결 없음"
        }
        return mapOf(
            "transport" to transport,
            "dnsServers" to (properties?.dnsServers?.map { it.hostAddress ?: it.toString() } ?: emptyList()),
            "metered" to connectivity.isActiveNetworkMetered,
            "validated" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
        )
    }

    private fun requestQuickSettingsTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("unsupported")
            return
        }
        val manager = getSystemService(StatusBarManager::class.java)
        manager.requestAddTileService(
            ComponentName(this, ProximaTileService::class.java),
            getString(R.string.quick_settings_tile_label),
            Icon.createWithResource(this, R.drawable.ic_stat_proxima),
            mainExecutor,
        ) { status ->
            result.success(
                when (status) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "already_added"
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "not_added"
                    StatusBarManager.TILE_ADD_REQUEST_ERROR_REQUEST_IN_PROGRESS -> "request_in_progress"
                    StatusBarManager.TILE_ADD_REQUEST_ERROR_APP_NOT_IN_FOREGROUND -> "not_foreground"
                    StatusBarManager.TILE_ADD_REQUEST_ERROR_BAD_COMPONENT -> "invalid_service"
                    else -> "unavailable"
                },
            )
        }
    }

    private fun requestPinAppWidget(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(android.appwidget.AppWidgetManager::class.java)
            val provider = ComponentName(this, ProximaWidgetProvider::class.java)
            if (manager != null && manager.isRequestPinAppWidgetSupported) {
                val success = manager.requestPinAppWidget(provider, null, null)
                result.success(success)
                return
            }
        }
        result.success(false)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST) {
            permissionResult?.success(resultCode == Activity.RESULT_OK)
            permissionResult = null
        } else if (requestCode == IMPORT_PROFILE_REQUEST) {
            if (resultCode == Activity.RESULT_OK) importProfile(data) else {
                importResult?.success(null)
                importResult = null
            }
        } else if (requestCode == EXPORT_PROFILE_REQUEST) {
            if (resultCode == Activity.RESULT_OK) saveExport(data) else {
                exportResult?.success(false)
                exportResult = null
                exportContent = null
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        VpnRuntime.addListener(runtimeListener)
    }

    override fun onCancel(arguments: Any?) {
        VpnRuntime.removeListener(runtimeListener)
        eventSink = null
    }

    override fun onDestroy() {
        VpnRuntime.removeListener(runtimeListener)
        eventSink = null
        permissionResult?.error("activity_destroyed", "Activity was destroyed", null)
        permissionResult = null
        importResult?.error("activity_destroyed", "Activity was destroyed", null)
        exportResult?.error("activity_destroyed", "Activity was destroyed", null)
        importResult = null
        exportResult = null
        exportContent = null
        mihomoUploads.values.forEach(mihomoSidecars::discard)
        mihomoUploads.clear()
        coreWorker.shutdownNow()
        super.onDestroy()
    }

    private fun requiredString(call: MethodCall, name: String): String {
        return requireNotNull(call.argument<String>(name)) { "$name is required" }
    }

    companion object {
        private const val METHOD_CHANNEL = "proxima/vpn"
        private const val EVENT_CHANNEL = "proxima/vpn/events"
        private const val VPN_PERMISSION_REQUEST = 4107
        private const val IMPORT_PROFILE_REQUEST = 4108
        private const val EXPORT_PROFILE_REQUEST = 4109
        private const val MAX_PROFILE_BYTES = 8 * 1024 * 1024
    }
}
