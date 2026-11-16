@file:Suppress("UNUSED_PARAMETER")
package org.json

class JSONObject {
    constructor()
    constructor(value: Map<*, *>)
    fun optString(key: String): String = ""
    fun optString(key: String, fallback: String): String = fallback
    fun optInt(key: String): Int = 0
    fun optLong(key: String): Long = 0
    fun optJSONArray(key: String): JSONArray? = null
    fun optJSONObject(key: String): JSONObject? = null
    fun put(key: String, value: Any?): JSONObject = this
}
class JSONArray {
    constructor()
    constructor(value: String)
    fun length(): Int = 0
    fun optJSONObject(index: Int): JSONObject? = null
    fun put(value: Any?): JSONArray = this
}
