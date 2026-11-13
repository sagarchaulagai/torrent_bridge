package com.rehesagar.torrentbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class TorrentServerForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "torrent_audio_server_channel"
        const val NOTIFICATION_ID = 4201
        const val ACTION_START_OR_UPDATE = "com.rehesagar.torrentbridge.ACTION_START_OR_UPDATE"
        const val ACTION_UPDATE_NOTIFICATION = "com.rehesagar.torrentbridge.ACTION_UPDATE_NOTIFICATION"
        const val ACTION_STOP_SERVER = "com.rehesagar.torrentbridge.ACTION_STOP_SERVER"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_CONTENT = "extra_content"

        @Volatile
        var isServiceRunning: Boolean = false

        var onStopRequestedCallback: (() -> Unit)? = null
        var onServiceDestroyedCallback: (() -> Unit)? = null

        fun updateNotificationDirect(context: Context, title: String, content: String) {
            if (!isServiceRunning) return
            try {
                val manager =
                    context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                val notification = buildNotificationForContext(context, title, content)
                manager.notify(NOTIFICATION_ID, notification)
            } catch (_: Exception) {}
        }

        private fun buildNotificationForContext(
            context: Context,
            title: String,
            content: String
        ): Notification {
            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val openPendingIntent = PendingIntent.getActivity(
                context,
                0,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val stopIntent = Intent(context, TorrentServerForegroundService::class.java).apply {
                action = ACTION_STOP_SERVER
            }
            val stopPendingIntent = PendingIntent.getService(
                context,
                1,
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }

            val stopAction = Notification.Action.Builder(
                android.R.drawable.ic_media_pause,
                "Stop Server",
                stopPendingIntent
            ).build()

            return builder
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentIntent(openPendingIntent)
                .setOngoing(true)
                .addAction(stopAction)
                .build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        isServiceRunning = true
        createNotificationChannel()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP_SERVER) {
            isServiceRunning = false
            onStopRequestedCallback?.invoke()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        isServiceRunning = true
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Torrent Bridge Running"
        val content = intent?.getStringExtra(EXTRA_CONTENT) ?: "Ready for HTTP audio streaming"
        val notification = buildNotificationForContext(this, title, content)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Keep the foreground service alive when the user switches apps or swipes recents
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isServiceRunning = false
        releaseLocks()
        onServiceDestroyedCallback?.invoke()
        super.onDestroy()
    }

    private fun acquireLocks() {
        try {
            val pm = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "TorrentBridge::ServerWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {}

        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lockMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wm.createWifiLock(lockMode, "TorrentBridge::ServerWifiLock").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {}
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {}
        wakeLock = null

        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (_: Exception) {}
        wifiLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Torrent Bridge Streaming Server",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Persistent notification while the local HTTP torrent audio server is running"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }
}
