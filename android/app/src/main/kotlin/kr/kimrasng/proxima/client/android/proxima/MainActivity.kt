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
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var profiles: ProfileRepository
    private lateinit var settings: VpnSettingsRepository
    private var eventSink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private var importResult: MethodChannel.Result? = null
    private var exportResult: MethodChannel.Result? = null
    private var exportContent: String? = null
    // Node probes are independent SOCKS routes. A single worker made the
    // "measure all" button wait for every timeout one by one.
    private val coreWorker = Executors.newFixedThreadPool(8)
    private val runtimeListener: (Map<String, Any?>) -> Unit = { value -> eventSink?.success(value) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VpnRuntime.initialize(this)
        profiles = ProfileRepository(this)
        settings = VpnSettingsRepository(this)
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
                    require(VlessRealityConfig.isGeneratedProfile(content)) {
                        "VLESS + REALITY 링크로 만든 프로필만 저장할 수 있습니다."
                    }
                    result.success(
                        profiles.save(
                            id = call.argument("id"),
                            name = requiredString(call, "name"),
                            sourceUrl = call.argument("sourceUrl"),
                            content = content,
                            subscriptionInfo = call.argument<Map<*, *>>("subscriptionInfo")?.let(
                                StoredSubscriptionInfo::fromMap,
                            ),
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
                "coreInfo" -> result.success(XrayCore.info(this))
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
            XrayConfig.validate(content)
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
        require(VlessRealityConfig.isGeneratedProfile(profiles.readContent(profileId))) {
            "VLESS + REALITY 링크로 만든 프로필만 연결할 수 있습니다."
        }
        profiles.select(profileId)
        val state = VpnRuntime.snapshot()
        val preserveSession = state["state"] in setOf("connected", "connecting") &&
            (state["startedAt"] as? Long ?: 0L) > 0L
        if (preserveSession) VpnRuntime.reconnecting(profile) else VpnRuntime.connecting(profile)
        val intent = Intent(this, ProximaVpnService::class.java)
            .setAction(ProximaVpnService.ACTION_START)
            .putExtra(ProximaVpnService.EXTRA_PROFILE_ID, profileId)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        }.onFailure {
            VpnRuntime.failed(profile, it.message ?: "VPN을 시작하지 못했습니다.")
        }.getOrThrow()
        result.success(null)
    }

    private fun invokeCore(method: String, data: String, result: MethodChannel.Result) {
        require(VpnRuntime.snapshot()["state"] == "connected") { "VPN is not connected" }
        val operation = {
            val payload: Any = when (method) {
                "getProxies" -> currentProxyState()
                "changeProxy" -> {
                    changeProxy(data)
                    JSONObject()
                }
                "updateConfig" -> {
                    restartCurrentVpn()
                    JSONObject()
                }
                "getConnections" -> recentConnections()
                "getMemory" -> Debug.getPss().toLong() * 1024L
                "queryExternalProviders" -> subscriptionProviders()
                "testDelay" -> testDelay(data)
                "closeConnection", "closeAllConnections" -> error("Xray는 개별 연결 종료를 지원하지 않습니다.")
                "updateExternalProvider" -> error("Xray 구독은 프로필 탭에서 업데이트합니다.")
                "probeCurrentProxyIp" -> probeCurrentProxyIp()
                else -> error("지원하지 않는 코어 작업입니다: $method")
            }
            JSONObject().put("code", 0).put("data", payload).toString()
        }
        if (method in setOf("testDelay", "probeCurrentProxyIp")) {
            coreWorker.execute {
                runCatching(operation)
                    .onSuccess { payload -> runOnUiThread { result.success(payload) } }
                    .onFailure { error -> runOnUiThread { result.error("core_action_error", error.message, null) } }
            }
        } else {
            runCatching(operation)
                .onSuccess(result::success)
                .onFailure { error -> result.error("core_action_error", error.message, null) }
        }
    }

    private fun currentProfile(): StoredProfile {
        val profileId = VpnRuntime.snapshot()["profileId"] as? String
            ?: error("연결 중인 프로필을 찾을 수 없습니다.")
        return profiles.profile(profileId) ?: error("연결 중인 프로필을 찾을 수 없습니다.")
    }

    private fun currentProxyState(): JSONObject {
        val profile = currentProfile()
        return XrayConfig.proxyState(
            profile = profile,
            content = profiles.readContent(profile.id),
            selected = settings.selectedProxies(profile.id),
            activeNode = VpnRuntime.snapshot()["activeNode"] as? String,
            activeMode = VpnRuntime.snapshot()["activeMode"] as? String,
        )
    }

    private fun recentConnections(): JSONObject {
        val runtime = VpnRuntime.snapshot()
        return JSONObject()
            .put("uploadTotal", runtime["totalUpload"] ?: 0)
            .put("downloadTotal", runtime["totalDownload"] ?: 0)
            .put(
                "connections",
                XrayConnectionLog.recent(
                    path = VpnRuntime.accessLogPath(),
                ),
            )
    }

    private fun testDelay(data: String): Int {
        val request = JSONObject(data)
        val node = request.optString("proxy-name").trim()
        require(node.isNotEmpty()) { "검사할 노드를 선택해 주세요." }
        val port = VpnRuntime.probePort(node) ?: error("이 노드는 현재 Xray 검사 준비가 되지 않았습니다.")
        return XrayProbe.delay(
            port = port,
            target = request.optString("test-url", "https://www.gstatic.com/generate_204"),
            timeoutMillis = request.optInt("timeout", 3_000),
        )
    }

    private fun probeCurrentProxyIp(): JSONObject {
        val snapshot = VpnRuntime.snapshot()
        val rulePort = if (snapshot["activeMode"] == "rule") {
            VpnRuntime.probePort(XrayConfig.RULE_PROBE_KEY)
        } else null
        val port = rulePort ?: (snapshot["activeNode"] as? String)
            ?.let(VpnRuntime::probePort)
            ?: error("직접 연결 모드에서는 프록시 IP를 확인할 수 없습니다.")
        return XrayProbe.publicIp(port)
    }

    private fun subscriptionProviders(): JSONArray = JSONArray().apply {
        profiles.list().forEach { item ->
            val source = item["sourceUrl"]?.toString()?.takeIf { it.isNotBlank() } ?: return@forEach
            val id = item["id"]?.toString() ?: return@forEach
            val count = runCatching { XrayConfig.nodeNames(profiles.profile(id)!!, profiles.readContent(id)).size }.getOrDefault(0)
            put(
                JSONObject()
                    .put("name", item["name"]?.toString().orEmpty())
                    .put("type", "subscription")
                    .put("vehicle-type", "http")
                    .put("count", count)
                    .put("path", source),
            )
        }
    }

    private fun changeProxy(data: String) {
        val profile = currentProfile()
        val selection = JSONObject(data)
        val group = selection.optString("group-name")
        val proxy = selection.optString("proxy-name")
        require(group == "GLOBAL") { "노드는 전역 모드에서만 직접 선택할 수 있습니다." }
        require(proxy in XrayConfig.nodeNames(profile, profiles.readContent(profile.id))) {
            "선택할 수 없는 노드입니다."
        }
        settings.saveSelectedProxy(profile.id, group, proxy)
        restartVpn(profile.id)
    }

    private fun restartCurrentVpn() {
        restartVpn(currentProfile().id)
    }

    private fun restartVpn(profileId: String) {
        val profile = profiles.profile(profileId) ?: error("연결 중인 프로필을 찾을 수 없습니다.")
        // Publish the transition before returning over MethodChannel so a
        // second mode/node change cannot target the outgoing generation.
        VpnRuntime.reconnecting(profile)
        val intent = Intent(this, ProximaVpnService::class.java)
            .setAction(ProximaVpnService.ACTION_START)
            .putExtra(ProximaVpnService.EXTRA_PROFILE_ID, profileId)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        }.onFailure {
            VpnRuntime.failed(profile, it.message ?: "VPN을 다시 시작하지 못했습니다.")
        }.getOrThrow()
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
            result.success(false)
            return
        }
        val manager = getSystemService(StatusBarManager::class.java)
        manager.requestAddTileService(
            ComponentName(this, ProximaTileService::class.java),
            getString(applicationInfo.labelRes),
            Icon.createWithResource(this, R.drawable.ic_stat_proxima),
            mainExecutor,
        ) { status ->
            result.success(
                status == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                    status == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED,
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
