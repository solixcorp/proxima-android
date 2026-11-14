package kr.kimrasng.proxima.client.android.proxima

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import java.util.UUID

// The launcher PendingIntent targets this non-exported activity, not the
// exported Flutter activity. A one-use capability prevents other apps from
// forging a connection request directly to MainActivity.
class ExternalConnectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val token = ExternalConnectCapability.issue()
        startActivity(Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_CONNECT_TOKEN, token))
        finish()
    }

    companion object {
        const val EXTRA_CONNECT_TOKEN = "kr.kimrasng.proxima.CONNECT_TOKEN"
    }
}

internal object ExternalConnectCapability {
    private val tokens = mutableSetOf<String>()

    @Synchronized fun issue(): String = UUID.randomUUID().toString().also { tokens.add(it) }
    @Synchronized fun consume(token: String?): Boolean = token != null && tokens.remove(token)
}

internal class PendingExternalConnect {
    private var pending = false
    fun request() { pending = true }
    fun consume(): Boolean = pending.also { pending = false }
    fun isPending(): Boolean = pending
}
