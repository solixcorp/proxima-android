package android.content

open class Context {
    open val applicationContext: Context get() = this
    open fun getSharedPreferences(name: String, mode: Int): SharedPreferences = error("not implemented")
    companion object { const val MODE_PRIVATE = 0 }
}

interface SharedPreferences {
    fun getString(key: String, default: String?): String?
    fun getBoolean(key: String, default: Boolean): Boolean
    fun getInt(key: String, default: Int): Int
    fun edit(): Editor
    interface Editor {
        fun putString(key: String, value: String?): Editor
        fun putBoolean(key: String, value: Boolean): Editor
        fun putInt(key: String, value: Int): Editor
        fun apply()
    }
}
