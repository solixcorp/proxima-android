@file:Suppress("UNUSED_PARAMETER")
package android.app

import android.content.Context
import android.content.Intent
import android.os.Bundle

open class Activity : Context() {
    open fun onCreate(savedInstanceState: Bundle?) {}
    fun startActivity(intent: Intent) {}
    fun finish() {}
}
