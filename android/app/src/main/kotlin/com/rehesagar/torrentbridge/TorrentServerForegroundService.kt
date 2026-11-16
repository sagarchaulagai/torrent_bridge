package com.rehesagar.torrentbridge

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock

class TorrentServerForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "torrent_bridge_server_v2"
        const val NOTIFICATION_ID = 4201
        const val PREFS_NAME = "torrent_bridge_service_prefs"
        const val KEY_KEEP_SERVER_RUNNING = "keep_server_running"
        const val ACTION_START_OR_UPDATE = "com.rehesagar.torrentbridge.ACTION_START_OR_UPDATE"
        const val ACTION_UPDATE_NOTIFICATION = "com.rehesagar.torrentbridge.ACTION_UPDATE_NOTIFICATION"
        const val ACTION_STOP_SERVER = "com.rehesagar.torrentbridge.ACTION_STOP_SERVER"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_CONTENT = "extra_content"
        private const val RESTART_ALARM_REQ_CODE = 4299

        @Volatile
        var isServiceRunning: Boolean = false

        var onStopRequestedCallback: (() -> Unit)? = null
        var onServiceDestroyedCallback: (() -> Unit)? = null
        var onNetworkChangedCallback: (() -> Unit)? = null

        fun setKeepServerRunningPref(context: Context, keep: Boolean) {
            try {
                context.applicationContext
                    .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(KEY_KEEP_SERVER_RUNNING, keep)
                    .apply()
            } catch (_: Exception) {}
        }

        fun shouldKeepServerRunning(context: Context): Boolean {
            return try {
                context.applicationContext
                    .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .getBoolean(KEY_KEEP_SERVER_RUNNING, false)
            } catch (_: Exception) {
                false
            }
        }

        fun cancelRestartAlarm(context: Context) {
            try {
                val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                val intent = Intent(context, TorrentServerForegroundService::class.java).apply {
                    action = ACTION_START_OR_UPDATE
                }
                val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    PendingIntent.getForegroundService(
                        context,
                        RESTART_ALARM_REQ_CODE,
                        intent,
                        PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
                    )
                } else {
                    PendingIntent.getService(
                        context,
                        RESTART_ALARM_REQ_CODE,
                        intent,
                        PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
                    )
                }
                if (pi != null) {
                    alarmManager.cancel(pi)
                    pi.cancel()
                }
            } catch (_: Exception) {}
        }

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
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .addAction(stopAction)
                .build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onCreate() {
        super.onCreate()
        isServiceRunning = true
        createNotificationChannel()
        acquireLocks()
        registerNetworkMonitor()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP_SERVER) {
            setKeepServerRunningPref(this, false)
            cancelRestartAlarm(this)
            isServiceRunning = false
            onStopRequestedCallback?.invoke()
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        // Sticky OS restart with null intent: only keep running if the server was left ON
        if (intent == null && !shouldKeepServerRunning(this)) {
            isServiceRunning = false
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        isServiceRunning = true
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Torrent Bridge Running"
        val content = intent?.getStringExtra(EXTRA_CONTENT) ?: "Ready for HTTP audio streaming"
        val notification = buildNotificationForContext(this, title, content)

        startForegroundTyped(notification)
        acquireLocks()

        // Ensure the persistent FlutterEngine (and Dart HTTP/libtorrent servers) is alive,
        // even if Android restarted the service headlessly after killing the Activity.
        try {
            TorrentBridgeEngineHost.getOrCreateEngine(applicationContext)
        } catch (_: Exception) {}

        return START_STICKY
    }

    private fun startForegroundTyped(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Non-Play-Store app: specialUse has no 6-hour dataSync timeout on Android 14/15/16.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onTimeout(startId: Int) {
        // Defensive handler for Android 14+ timeout callbacks: renew foreground state if needed
        if (shouldKeepServerRunning(this)) {
            try {
                val notification = buildNotificationForContext(
                    this,
                    "Torrent Bridge Running",
                    "Keeping HTTP & torrent engine active"
                )
                startForegroundTyped(notification)
            } catch (_: Exception) {
                stopForegroundCompat()
                stopSelf()
            }
        } else {
            stopForegroundCompat()
            stopSelf()
        }
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        onTimeout(startId)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Keep the foreground service and shared FlutterEngine alive when the user switches
        // apps or swipes the app away from Recents. Schedule a safety revival if OEM kills us.
        if (shouldKeepServerRunning(this)) {
            acquireLocks()
            scheduleSafetyRestartIfNeeded()
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun scheduleSafetyRestartIfNeeded() {
        try {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val restartIntent = Intent(applicationContext, TorrentServerForegroundService::class.java).apply {
                action = ACTION_START_OR_UPDATE
                putExtra(EXTRA_TITLE, "Torrent Bridge Running")
                putExtra(EXTRA_CONTENT, "Streaming server active in background")
            }
            val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(
                    applicationContext,
                    RESTART_ALARM_REQ_CODE,
                    restartIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            } else {
                PendingIntent.getService(
                    applicationContext,
                    RESTART_ALARM_REQ_CODE,
                    restartIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            }
            alarmManager.set(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + 2500L,
                pi
            )
        } catch (_: Exception) {}
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isServiceRunning = false
        unregisterNetworkMonitor()
        releaseLocks()
        onServiceDestroyedCallback?.invoke()
        super.onDestroy()
    }

    private fun registerNetworkMonitor() {
        if (networkCallback != null) return
        try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    onNetworkChangedCallback?.invoke()
                }

                override fun onLost(network: Network) {
                    onNetworkChangedCallback?.invoke()
                }
            }
            val req = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(req, cb)
            networkCallback = cb
        } catch (_: Exception) {}
    }

    private fun unregisterNetworkMonitor() {
        val cb = networkCallback ?: return
        networkCallback = null
        try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.unregisterNetworkCallback(cb)
        } catch (_: Exception) {}
    }

    private fun acquireLocks() {
        try {
            if (wakeLock?.isHeld != true) {
                val pm = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "TorrentBridge::ServerWakeLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {}

        try {
            if (wifiLock?.isHeld != true) {
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
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Persistent notification keeping the HTTP torrent audio server alive in the background"
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }
}
