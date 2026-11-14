@file:Suppress("UNUSED_PARAMETER")
package android.content

import java.io.File

open class Context {
    open val applicationContext: Context get() = this
    open val filesDir: File get() = error("not implemented")
    open fun getSharedPreferences(name: String, mode: Int): SharedPreferences = error("not implemented")
    companion object { const val MODE_PRIVATE = 0 }
}
interface SharedPreferences {
    fun getString(key: String, default: String?): String?
    fun edit(): Editor
    interface Editor {
        fun putString(key: String, value: String?): Editor
        fun apply()
    }
}
class Intent(context: Context, target: Class<*>) {
    fun addFlags(flags: Int): Intent = this
    fun putExtra(name: String, value: String): Intent = this
    companion object {
        const val FLAG_ACTIVITY_NEW_TASK = 1
        const val FLAG_ACTIVITY_CLEAR_TOP = 2
        const val FLAG_ACTIVITY_SINGLE_TOP = 4
    }
}
