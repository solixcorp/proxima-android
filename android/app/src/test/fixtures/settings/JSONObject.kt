@file:Suppress("UNUSED_PARAMETER")
package org.json

class JSONObject {
    constructor()
    constructor(value: String)
    constructor(value: Map<String, String>)
    fun keys(): Iterator<String> = emptyList<String>().iterator()
    fun optString(key: String): String = ""
    fun put(key: String, value: String): JSONObject = this
}
