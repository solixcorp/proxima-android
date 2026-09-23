package kr.kimrasng.proxima.client.android.proxima

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.widget.RemoteViews
import java.util.Locale

class ProximaWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        updateWidget(context, appWidgetManager, appWidgetId)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_TOGGLE_VPN) {
            toggleVpn(context)
        }
        updateAllWidgets(context)
    }

    private fun toggleVpn(context: Context) {
        val snapshot = VpnRuntime.snapshot()
        val state = snapshot["state"]?.toString()

        if (state == "connected" || state == "connecting") {
            val stopIntent = Intent(context, ProximaVpnService::class.java).apply {
                action = ProximaVpnService.ACTION_STOP
            }
            context.startService(stopIntent)
            return
        }

        val profile = ProfileRepository(context).active()
        if (profile == null || VpnService.prepare(context) != null) {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            context.startActivity(launchIntent)
            return
        }

        val startIntent = Intent(context, ProximaVpnService::class.java).apply {
            action = ProximaVpnService.ACTION_START
            putExtra(ProximaVpnService.EXTRA_PROFILE_ID, profile.id)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(startIntent)
        } else {
            context.startService(startIntent)
        }
    }

    companion object {
        const val ACTION_TOGGLE_VPN = "kr.kimrasng.proxima.ACTION_TOGGLE_VPN"

        fun updateAllWidgets(context: Context) {
            val appWidgetManager = AppWidgetManager.getInstance(context) ?: return
            val componentName = ComponentName(context, ProximaWidgetProvider::class.java)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(componentName) ?: return
            for (appWidgetId in appWidgetIds) {
                updateWidget(context, appWidgetManager, appWidgetId)
            }
        }

        fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            try {
                val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
                val minWidth = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0
                val minHeight = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
                val isLarge = minHeight >= 118
                val isWide = !isLarge && minWidth >= 220 && minHeight >= 64
                val layoutId = when {
                    isLarge -> R.layout.widget_proxima_large
                    isWide -> R.layout.widget_proxima_wide
                    else -> R.layout.widget_proxima_compact
                }
                val views = RemoteViews(context.packageName, layoutId)

                val snapshot = VpnRuntime.snapshot()
                val state = snapshot["state"]?.toString() ?: "disconnected"
                val profileName = snapshot["profileName"]?.toString()
                    ?: ProfileRepository(context).active()?.name
                views.setTextViewText(R.id.widget_title, profileName ?: "Proxima VPN")
                val activeNode = snapshot["activeNode"]?.toString()
                // A widget can be refreshed before the process recreates the
                // in-memory snapshot. Fall back to persisted settings so a
                // stale node name can never disguise RULE mode as GLOBAL.
                val activeMode = snapshot["activeMode"]?.toString()
                    ?: VpnSettingsRepository(context).load().mode
                val startedAt = (snapshot["startedAt"] as? Number)?.toLong() ?: 0L
                val uploadSpeed = (snapshot["uploadSpeed"] as? Number)?.toLong() ?: 0L
                val downloadSpeed = (snapshot["downloadSpeed"] as? Number)?.toLong() ?: 0L

                // Launch MainActivity when tapping container
                val launchIntent = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                }
                val pendingLaunch = PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_container, pendingLaunch)

                // Toggle VPN when tapping button
                val toggleIntent = Intent(context, ProximaWidgetProvider::class.java).apply {
                    action = ACTION_TOGGLE_VPN
                }
                val pendingToggle = PendingIntent.getBroadcast(
                    context,
                    1,
                    toggleIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_button, pendingToggle)

                val displayNode = when {
                    state == "connected" && activeMode == "rule" -> "규칙 모드 · 자동 선택"
                    state == "connected" && activeMode == "direct" -> "직접 모드"
                    state == "connected" && activeMode == "global" && !activeNode.isNullOrEmpty() ->
                        "전역 모드 · $activeNode"
                    !activeNode.isNullOrEmpty() && !profileName.isNullOrEmpty() -> "$profileName · $activeNode"
                    !activeNode.isNullOrEmpty() -> activeNode
                    !profileName.isNullOrEmpty() -> profileName
                    else -> "연결되지 않음"
                }

                if (isLarge) {
                    // Large widgets need an explicit state in their spacious
                    // centre area.  Leaving the last profile/node name here
                    // made a disconnected widget look as though it was still
                    // routing through that node.
                    when (state) {
                        "connected" -> {
                            views.setViewVisibility(R.id.widget_traffic_layout, android.view.View.VISIBLE)
                            views.setViewVisibility(R.id.widget_traffic_down, android.view.View.VISIBLE)
                            views.setTextViewText(R.id.widget_node, displayNode)
                            views.setTextViewText(R.id.widget_uptime, "⏱ ${formatUptime(startedAt)}")
                            views.setTextViewText(R.id.widget_traffic_up, "↑ ${formatBytes(uploadSpeed)}")
                            views.setTextViewText(R.id.widget_traffic_down, "↓ ${formatBytes(downloadSpeed)}")
                            views.setTextViewText(R.id.widget_button, "연결 해제")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_connected
                            )
                        }
                        "connecting" -> {
                            views.setViewVisibility(R.id.widget_traffic_layout, android.view.View.VISIBLE)
                            views.setViewVisibility(R.id.widget_traffic_down, android.view.View.GONE)
                            views.setTextViewText(R.id.widget_node, "VPN 연결 중")
                            views.setTextViewText(R.id.widget_traffic_up, "안전한 연결을 준비하고 있습니다")
                            views.setTextViewText(R.id.widget_button, "연결하는 중…")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_disconnected
                            )
                        }
                        else -> {
                            views.setViewVisibility(R.id.widget_traffic_layout, android.view.View.VISIBLE)
                            views.setViewVisibility(R.id.widget_traffic_down, android.view.View.GONE)
                            views.setTextViewText(R.id.widget_node, "VPN 꺼짐")
                            views.setTextViewText(R.id.widget_uptime, profileName ?: "연결할 프로필을 선택하세요")
                            views.setTextViewText(R.id.widget_traffic_up, "안전한 연결을 시작하세요")
                            views.setTextViewText(R.id.widget_button, "연결")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_disconnected
                            )
                        }
                    }
                } else if (isWide) {
                    when (state) {
                        "connected" -> {
                            views.setViewVisibility(R.id.widget_traffic_layout, android.view.View.VISIBLE)
                            views.setTextViewText(R.id.widget_status, displayNode)
                            views.setTextViewText(R.id.widget_traffic_up, "↑ ${formatBytes(uploadSpeed)}")
                            views.setTextViewText(R.id.widget_traffic_down, "↓ ${formatBytes(downloadSpeed)}")
                            views.setTextViewText(R.id.widget_button, "연결 해제")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_connected,
                            )
                        }
                        "connecting" -> {
                            views.setViewVisibility(R.id.widget_traffic_layout, android.view.View.GONE)
                            views.setTextViewText(R.id.widget_status, "연결하는 중…")
                            views.setTextViewText(R.id.widget_button, "대기")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_disconnected,
                            )
                        }
                        else -> {
                            views.setViewVisibility(R.id.widget_traffic_layout, android.view.View.GONE)
                            views.setTextViewText(R.id.widget_status, "VPN 꺼짐")
                            views.setTextViewText(R.id.widget_button, "연결")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_disconnected,
                            )
                        }
                    }
                } else {
                    // 세로 1칸 컴팩트 레이아웃 (원래 전 모습)
                    when (state) {
                        "connected" -> {
                            val statusText = "보호됨 · $displayNode"
                            views.setTextViewText(R.id.widget_status, statusText)
                            views.setTextViewText(R.id.widget_button, "연결 해제")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_connected
                            )
                        }
                        "connecting" -> {
                            views.setTextViewText(R.id.widget_status, "연결하는 중…")
                            views.setTextViewText(R.id.widget_button, "연결 중")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_disconnected
                            )
                        }
                        else -> {
                            val statusText = if (!profileName.isNullOrEmpty()) "연결 안 됨 · $profileName" else "연결되지 않음"
                            views.setTextViewText(R.id.widget_status, statusText)
                            views.setTextViewText(R.id.widget_button, "연결")
                            views.setInt(
                                R.id.widget_button,
                                "setBackgroundResource",
                                R.drawable.widget_button_disconnected
                            )
                        }
                    }
                }

                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (e: Exception) {
                // Ignore
            }
        }

        private fun formatBytes(bytesPerSec: Long): String {
            if (bytesPerSec <= 0) return "0 B/s"
            val k = 1024.0
            val sizes = arrayOf("B/s", "KB/s", "MB/s", "GB/s")
            val i = (Math.log(bytesPerSec.toDouble()) / Math.log(k)).toInt().coerceIn(0, 3)
            val value = bytesPerSec / Math.pow(k, i.toDouble())
            return String.format(Locale.US, "%.1f %s", value, sizes[i])
        }

        private fun formatUptime(startedAt: Long): String {
            if (startedAt <= 0) return "00:00:00"
            val elapsedSec = ((System.currentTimeMillis() - startedAt) / 1000).coerceAtLeast(0)
            val hours = elapsedSec / 3600
            val minutes = (elapsedSec % 3600) / 60
            val seconds = elapsedSec % 60
            return String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, seconds)
        }
    }
}
