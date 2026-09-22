package kr.kimrasng.proxima.client.android.proxima

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class StoredProfile(
    val id: String,
    val name: String,
    val sourceUrl: String?,
    val updatedAt: Long,
    val subscriptionInfo: StoredSubscriptionInfo? = null,
)

data class StoredSubscriptionInfo(
    val upload: Long = 0,
    val download: Long = 0,
    val total: Long = 0,
    val expire: Long = 0,
    val planName: String? = null,
) {
    fun asMap(): Map<String, Any> = mapOf(
        "upload" to upload,
        "download" to download,
        "total" to total,
        "expire" to expire,
        "planName" to (planName ?: ""),
    )

    companion object {
        fun fromMap(value: Map<*, *>): StoredSubscriptionInfo = StoredSubscriptionInfo(
            upload = (value["upload"] as? Number)?.toLong()?.coerceAtLeast(0) ?: 0,
            download = (value["download"] as? Number)?.toLong()?.coerceAtLeast(0) ?: 0,
            total = (value["total"] as? Number)?.toLong()?.coerceAtLeast(0) ?: 0,
            expire = (value["expire"] as? Number)?.toLong()?.coerceAtLeast(0) ?: 0,
            planName = value["planName"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }?.take(120),
        )

        fun fromJson(value: JSONObject): StoredSubscriptionInfo = StoredSubscriptionInfo(
            upload = value.optLong("upload").coerceAtLeast(0),
            download = value.optLong("download").coerceAtLeast(0),
            total = value.optLong("total").coerceAtLeast(0),
            expire = value.optLong("expire").coerceAtLeast(0),
            planName = value.optString("planName").trim().takeIf { it.isNotEmpty() }?.take(120),
        )
    }
}

class ProfileRepository(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val directory = File(appContext.filesDir, "profiles").apply { mkdirs() }

    @Synchronized
    fun list(): List<Map<String, Any?>> {
        val active = activeId()
        return readMetadata().map { profile ->
            mapOf(
                "id" to profile.id,
                "name" to profile.name,
                "sourceUrl" to profile.sourceUrl,
                "updatedAt" to profile.updatedAt,
                "isActive" to (profile.id == active),
                "subscriptionInfo" to profile.subscriptionInfo?.asMap(),
            )
        }
    }

    @Synchronized
    fun profile(id: String): StoredProfile? = readMetadata().firstOrNull { it.id == id }

    @Synchronized
    fun active(): StoredProfile? = activeId()?.let(::profile)

    @Synchronized
    fun readContent(id: String): String {
        require(profile(id) != null) { "Profile not found" }
        return profileFile(id).readText(Charsets.UTF_8)
    }

    @Synchronized
    fun save(
        id: String?,
        name: String,
        sourceUrl: String?,
        content: String,
        subscriptionInfo: StoredSubscriptionInfo? = null,
    ): Map<String, Any?> {
        require(name.isNotBlank()) { "Profile name is required" }
        require(content.isNotBlank()) { "Profile content is required" }
        require(content.toByteArray(Charsets.UTF_8).size <= MAX_PROFILE_BYTES) { "Profile is larger than 8 MB" }

        val profiles = readMetadata().toMutableList()
        val existing = id?.let { candidate -> profiles.indexOfFirst { it.id == candidate } } ?: -1
        val profileId = if (existing >= 0) profiles[existing].id else UUID.randomUUID().toString()
        val next = StoredProfile(
            id = profileId,
            name = name.trim().take(80),
            sourceUrl = sourceUrl?.trim()?.takeIf { it.isNotEmpty() },
            updatedAt = System.currentTimeMillis(),
            subscriptionInfo = subscriptionInfo ?: existing.takeIf { it >= 0 }?.let { profiles[it].subscriptionInfo },
        )
        writeAtomically(profileFile(profileId), content)
        if (existing >= 0) profiles[existing] = next else profiles.add(0, next)
        writeMetadata(profiles)
        if (activeId() == null) preferences.edit().putString(KEY_ACTIVE_ID, profileId).apply()
        return list().first { it["id"] == profileId }
    }

    @Synchronized
    fun delete(id: String) {
        val profiles = readMetadata().toMutableList()
        require(profiles.any { it.id == id }) { "Profile not found" }
        profiles.removeAll { it.id == id }
        profileFile(id).delete()
        writeMetadata(profiles)
        if (activeId() == id) {
            preferences.edit().putString(KEY_ACTIVE_ID, profiles.firstOrNull()?.id).apply()
        }
    }

    @Synchronized
    fun select(id: String) {
        require(readMetadata().any { it.id == id }) { "Profile not found" }
        preferences.edit().putString(KEY_ACTIVE_ID, id).apply()
    }

    fun activeId(): String? = preferences.getString(KEY_ACTIVE_ID, null)

    private fun profileFile(id: String): File {
        require(ID_PATTERN.matches(id)) { "Invalid profile id" }
        return File(directory, "$id.yaml")
    }

    private fun readMetadata(): List<StoredProfile> {
        val raw = preferences.getString(KEY_METADATA, "[]") ?: "[]"
        val array = runCatching { JSONArray(raw) }.getOrDefault(JSONArray())
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val id = item.optString("id")
                if (!ID_PATTERN.matches(id) || !profileFile(id).isFile) continue
                add(
                    StoredProfile(
                        id = id,
                        name = item.optString("name", "Profile"),
                        sourceUrl = item.optString("sourceUrl").takeIf { it.isNotEmpty() },
                        updatedAt = item.optLong("updatedAt"),
                        subscriptionInfo = item.optJSONObject("subscriptionInfo")?.let(StoredSubscriptionInfo::fromJson),
                    ),
                )
            }
        }
    }

    private fun writeMetadata(profiles: List<StoredProfile>) {
        val array = JSONArray()
        profiles.forEach { profile ->
            array.put(
                JSONObject()
                    .put("id", profile.id)
                    .put("name", profile.name)
                    .put("sourceUrl", profile.sourceUrl ?: "")
                    .put("updatedAt", profile.updatedAt)
                    .apply {
                        profile.subscriptionInfo?.let { put("subscriptionInfo", JSONObject(it.asMap())) }
                    },
            )
        }
        preferences.edit().putString(KEY_METADATA, array.toString()).apply()
    }

    private fun writeAtomically(destination: File, content: String) {
        val temporary = File(destination.parentFile, ".${destination.name}.tmp")
        temporary.writeText(content, Charsets.UTF_8)
        if (!temporary.renameTo(destination)) {
            temporary.copyTo(destination, overwrite = true)
            temporary.delete()
        }
    }

    companion object {
        private const val PREFERENCES = "proxima_profiles"
        private const val KEY_METADATA = "metadata"
        private const val KEY_ACTIVE_ID = "active_id"
        private const val MAX_PROFILE_BYTES = 8 * 1024 * 1024
        private val ID_PATTERN = Regex("^[a-fA-F0-9-]{36}$")

    }
}

object VlessRealityConfig {
    private const val METADATA_PREFIX = "# proxima-vless-reality-link:"

    fun isGeneratedProfile(content: String): Boolean = content.lineSequence().any { line ->
        line.trimStart().startsWith(METADATA_PREFIX)
    }
}
