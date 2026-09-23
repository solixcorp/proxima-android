package kr.kimrasng.proxima.client.android.proxima

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class ProximaTileService : TileService() {
    private val listener: (Map<String, Any?>) -> Unit = { updateTile(it) }

    override fun onStartListening() {
        super.onStartListening()
        VpnRuntime.addListener(listener)
    }

    override fun onStopListening() {
        VpnRuntime.removeListener(listener)
        super.onStopListening()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val state = VpnRuntime.snapshot()["state"]?.toString()
        if (state == "connected" || state == "connecting") {
            startService(Intent(this, ProximaVpnService::class.java).setAction(ProximaVpnService.ACTION_STOP))
            return
        }
        val profile = ProfileRepository(this).active()
        if (profile == null || VpnService.prepare(this) != null) {
            val launchIntent = Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(
                    PendingIntent.getActivity(
                        this,
                        0,
                        launchIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(launchIntent)
            }
            return
        }
        val intent = Intent(this, ProximaVpnService::class.java)
            .setAction(ProximaVpnService.ACTION_START)
            .putExtra(ProximaVpnService.EXTRA_PROFILE_ID, profile.id)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    private fun updateTile(snapshot: Map<String, Any?>) {
        val tile = qsTile ?: return
        val connected = snapshot["state"] == "connected"
        val activeNode = snapshot["activeNode"]?.toString()
        val activeMode = snapshot["activeMode"]?.toString()
            ?: VpnSettingsRepository(this).load().mode
        val profileName = snapshot["profileName"]?.toString()
        val uploadSpeed = (snapshot["uploadSpeed"] as? Number)?.toLong() ?: 0L
        val downloadSpeed = (snapshot["downloadSpeed"] as? Number)?.toLong() ?: 0L

        tile.state = if (connected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Proxima"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val displayNode = when (activeMode) {
                "rule" -> "규칙 모드 · 자동 선택"
                "direct" -> "직접 모드"
                "global" -> activeNode?.let { "전역 모드 · $it" } ?: "전역 모드"
                else -> activeNode ?: profileName ?: "연결됨"
            }
            tile.subtitle = if (connected) {
                if (uploadSpeed > 0 || downloadSpeed > 0) {
                    "$displayNode · ↑${formatSpeed(uploadSpeed)} ↓${formatSpeed(downloadSpeed)}"
                } else {
                    displayNode
                }
            } else {
                "연결 안 됨"
            }
        }
        tile.updateTile()
    }

    private fun formatSpeed(bytesPerSec: Long): String {
        if (bytesPerSec <= 0) return "0B/s"
        val k = 1024.0
        val sizes = arrayOf("B/s", "KB/s", "MB/s", "GB/s")
        val i = (Math.log(bytesPerSec.toDouble()) / Math.log(k)).toInt().coerceIn(0, 3)
        val value = bytesPerSec / Math.pow(k, i.toDouble())
        return String.format(java.util.Locale.US, "%.0f%s", value, sizes[i])
    }
}
