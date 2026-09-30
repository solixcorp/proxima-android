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
import android.os.SystemClock
import android.util.Log
import android.util.SizeF
import android.view.View
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

        if (state == "disconnecting") return

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
                val snapshot = VpnRuntime.snapshot()
                val profile = ProfileRepository(context).active()
                val mode = snapshot["activeMode"]?.toString()
                    ?: VpnSettingsRepository(context).load().mode
                val state = snapshot["state"]?.toString() ?: "disconnected"
                val needsSetup = state !in setOf("connected", "connecting", "disconnecting") &&
                    (profile == null || VpnService.prepare(context) != null)
                val fontScale = context.resources.configuration.fontScale.coerceAtLeast(1f)
                fun render(layout: Int) = createViews(context, layout, snapshot, profile?.name, mode, needsSetup)
                val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Let the launcher select a layout for its actual bounds, including rotation.
                    RemoteViews(mapOf(
                        SizeF(180f, 56f) to render(R.layout.widget_proxima_compact),
                        SizeF(280f * fontScale, 96f * fontScale) to render(R.layout.widget_proxima_wide),
                        SizeF(240f * fontScale, 200f * fontScale) to render(R.layout.widget_proxima_large),
                    ))
                } else {
                    fun layout(width: Int, height: Int): Int = when {
                        width >= 240 * fontScale && height >= 200 * fontScale -> R.layout.widget_proxima_large
                        width >= 280 * fontScale && height >= 96 * fontScale -> R.layout.widget_proxima_wide
                        else -> R.layout.widget_proxima_compact
                    }
                    RemoteViews(
                        render(layout(
                            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH),
                            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT),
                        )),
                        render(layout(
                            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH),
                            options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT),
                        )),
                    )
                }
                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (error: Exception) {
                Log.w("ProximaWidget", "Unable to update widget $appWidgetId", error)
            }
        }

        private fun createViews(
            context: Context,
            layout: Int,
            snapshot: Map<String, Any?>,
            savedProfileName: String?,
            mode: String,
            needsSetup: Boolean,
        ): RemoteViews {
            val views = RemoteViews(context.packageName, layout)
            val state = snapshot["state"]?.toString() ?: "disconnected"
            val connected = state == "connected"
            val connecting = state == "connecting"
            val disconnecting = state == "disconnecting"
            val failed = state == "error"
            val profileName = snapshot["profileName"]?.toString() ?: savedProfileName
            val status = context.getString(when {
                connected -> R.string.widget_on
                connecting -> R.string.widget_connecting
                disconnecting -> R.string.widget_disconnecting
                failed -> R.string.widget_error
                needsSetup -> R.string.widget_setup
                else -> R.string.widget_off
            })
            val actionLabel = context.getString(when {
                connected -> R.string.widget_disconnect
                connecting -> R.string.widget_cancel
                disconnecting -> R.string.widget_wait
                needsSetup -> R.string.widget_open
                failed -> R.string.widget_retry
                else -> R.string.widget_connect
            })
            val modeLabel = context.getString(when (mode) {
                "global" -> R.string.widget_global
                "direct" -> R.string.widget_direct
                else -> R.string.widget_rule
            })
            val detail = when {
                connected -> when (mode) {
                    "direct" -> context.getString(R.string.widget_direct_detail)
                    "global" -> snapshot["activeNode"]?.toString()?.takeIf { it.isNotBlank() } ?: modeLabel
                    else -> context.getString(R.string.widget_auto_node)
                }
                connecting -> context.getString(R.string.widget_preparing)
                disconnecting -> context.getString(R.string.widget_stopping)
                needsSetup && savedProfileName == null -> context.getString(R.string.widget_choose_profile)
                needsSetup -> context.getString(R.string.widget_permission)
                failed -> context.getString(R.string.widget_error_detail)
                else -> context.getString(R.string.widget_ready)
            }
            views.setTextViewText(R.id.widget_status, status)
            views.setTextColor(R.id.widget_status, context.getColor(when {
                connected -> R.color.widget_connected
                failed -> R.color.widget_error
                connecting -> R.color.widget_accent
                else -> R.color.widget_text_secondary
            }))
            views.setTextViewText(R.id.widget_title, when {
                needsSetup && layout != R.layout.widget_proxima_large -> detail
                layout == R.layout.widget_proxima_wide && connected -> "${profileName ?: context.getString(R.string.app_name)} · $modeLabel"
                else -> profileName ?: context.getString(R.string.app_name)
            })
            if (layout == R.layout.widget_proxima_compact &&
                context.resources.configuration.fontScale > 1.2f) {
                views.setViewVisibility(R.id.widget_title, View.GONE)
            }
            views.setInt(R.id.widget_button, "setBackgroundResource", when {
                connected -> R.drawable.widget_button_connected
                connecting || disconnecting -> R.drawable.widget_button_pending
                else -> R.drawable.widget_button_disconnected
            })
            views.setImageViewResource(R.id.widget_button, when {
                connecting -> R.drawable.widget_ic_cancel
                needsSetup -> R.drawable.widget_ic_open
                else -> R.drawable.widget_ic_power
            })
            views.setInt(R.id.widget_button, "setColorFilter", context.getColor(when {
                connected -> R.color.widget_connected
                connecting || disconnecting -> R.color.widget_text_secondary
                else -> R.color.widget_on_accent
            }))
            views.setContentDescription(R.id.widget_button, context.getString(R.string.widget_button_description, status, actionLabel))
            views.setBoolean(R.id.widget_button, "setEnabled", !disconnecting)
            views.setInt(R.id.widget_button, "setImageAlpha", if (disconnecting) 100 else 255)

            val pendingLaunch = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val pendingToggle = PendingIntent.getBroadcast(
                context, 1,
                Intent(context, ProximaWidgetProvider::class.java).apply { action = ACTION_TOGGLE_VPN },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_container, pendingLaunch)
            // Launch setup directly; modern Android restricts background activity starts.
            views.setOnClickPendingIntent(R.id.widget_button, if (needsSetup) pendingLaunch else pendingToggle)

            if (layout != R.layout.widget_proxima_compact) {
                val startedAt = (snapshot["startedAt"] as? Number)?.toLong() ?: 0L
                val showElapsed = startedAt > 0L &&
                    state in setOf("connected", "connecting", "disconnecting")
                views.setViewVisibility(R.id.widget_uptime, if (showElapsed) View.VISIBLE else View.GONE)
                views.setViewVisibility(R.id.widget_uptime_empty, if (showElapsed) View.GONE else View.VISIBLE)
                if (showElapsed) {
                    val elapsed = (System.currentTimeMillis() - startedAt).coerceAtLeast(0L)
                    views.setChronometer(
                        R.id.widget_uptime,
                        SystemClock.elapsedRealtime() - elapsed,
                        context.getString(R.string.widget_elapsed_format),
                        true,
                    )
                }
                if (layout == R.layout.widget_proxima_large) {
                    views.setViewVisibility(
                        R.id.widget_traffic_layout,
                        if (connected) View.VISIBLE else View.GONE,
                    )
                    if (connected) {
                        val down = formatBytes((snapshot["downloadSpeed"] as? Number)?.toLong() ?: 0L)
                        val up = formatBytes((snapshot["uploadSpeed"] as? Number)?.toLong() ?: 0L)
                        views.setTextViewText(R.id.widget_traffic_down, down)
                        views.setTextViewText(R.id.widget_traffic_up, up)
                    }
                    views.setTextViewText(R.id.widget_node, if (connected) "$modeLabel · $detail" else detail)
                }
            }
            return views
        }

        private fun formatBytes(bytesPerSec: Long): String {
            if (bytesPerSec <= 0) return "0 B/s"
            val k = 1024.0
            val sizes = arrayOf("B/s", "KB/s", "MB/s", "GB/s")
            val i = (Math.log(bytesPerSec.toDouble()) / Math.log(k)).toInt().coerceIn(0, 3)
            val value = bytesPerSec / Math.pow(k, i.toDouble())
            return String.format(Locale.US, "%.1f %s", value, sizes[i])
        }

    }
}
