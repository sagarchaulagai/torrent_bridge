package com.rehesagar.torrentbridge

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference

/**
 * Owns the single persistent [FlutterEngine] for Torrent Bridge so the Dart
 * isolate (`HttpStreamingServer` and `LibtorrentFlutter`) keeps running even
 * when `MainActivity` is destroyed or swiped from Recents, and can be booted
 * headlessly by `TorrentServerForegroundService` on OS sticky restarts or boot.
 */
object TorrentBridgeEngineHost {

    const val ENGINE_ID = "torrent_bridge_engine"
    private const val CHANNEL_FOREGROUND = "com.rehesagar.torrentbridge/foreground_service"
    private const val CHANNEL_UPDATER = "com.rehesagar.torrentbridge/app_updater"
    const val REQUEST_CODE_NOTIFICATIONS = 1001
    const val REQUEST_CODE_INSTALL_UNKNOWN_APPS = 2002

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var cachedEngine: FlutterEngine? = null
    private var configuredEngineIdentity: Int = 0
    private var foregroundChannel: MethodChannel? = null
    private var updaterChannel: MethodChannel? = null
    private var activityRef: WeakReference<Activity>? = null
    private var batteryPromptShown = false
    private var pendingInstallApkPath: String? = null

    fun attachActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    fun detachActivity(activity: Activity) {
        if (activityRef?.get() === activity) {
            activityRef = null
        }
    }

    fun getExistingEngine(): FlutterEngine? {
        return cachedEngine ?: FlutterEngineCache.getInstance().get(ENGINE_ID)
    }

    fun getOrCreateEngine(context: Context): FlutterEngine {
        val appCtx = context.applicationContext
        val existing = getExistingEngine()
        if (existing != null) {
            cachedEngine = existing
            ensureChannelsConfigured(appCtx, existing)
            return existing
        }

        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(appCtx)
        }
        loader.ensureInitializationComplete(appCtx, null)

        val engine = FlutterEngine(appCtx)
        cachedEngine = engine
        ensureChannelsConfigured(appCtx, engine)

        if (!engine.dartExecutor.isExecutingDart) {
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "main")
            )
        }

        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    fun ensureChannelsConfigured(appContext: Context, engine: FlutterEngine) {
        val idHash = System.identityHashCode(engine)
        if (configuredEngineIdentity == idHash && foregroundChannel != null && updaterChannel != null) {
            return
        }
        configuredEngineIdentity = idHash

        val fgChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_FOREGROUND)
        foregroundChannel = fgChannel

        TorrentServerForegroundService.onStopRequestedCallback = {
            invokeOnMain("onStopServerRequested", null)
        }
        TorrentServerForegroundService.onServiceDestroyedCallback = {
            invokeOnMain("onServiceDestroyed", null)
        }
        TorrentServerForegroundService.onNetworkChangedCallback = {
            invokeOnMain("onNetworkChanged", null)
        }

        fgChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    result.success(requestNotificationPermissionIfNeeded(appContext))
                }
                "startService" -> {
                    val title = call.argument<String>("title") ?: "Torrent Bridge Running"
                    val content = call.argument<String>("content") ?: "Streaming audio over HTTP"
                    TorrentServerForegroundService.setKeepServerRunningPref(appContext, true)
                    val serviceIntent = Intent(appContext, TorrentServerForegroundService::class.java).apply {
                        action = TorrentServerForegroundService.ACTION_START_OR_UPDATE
                        putExtra(TorrentServerForegroundService.EXTRA_TITLE, title)
                        putExtra(TorrentServerForegroundService.EXTRA_CONTENT, content)
                    }
                    startForegroundServiceCompat(appContext, serviceIntent)
                    requestBatteryOptimizationExemptionIfNeeded(appContext, onlyOnce = true)
                    result.success(true)
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "Torrent Bridge Running"
                    val content = call.argument<String>("content") ?: "Streaming audio over HTTP"
                    if (TorrentServerForegroundService.isServiceRunning) {
                        TorrentServerForegroundService.updateNotificationDirect(appContext, title, content)
                    } else if (TorrentServerForegroundService.shouldKeepServerRunning(appContext)) {
                        val serviceIntent = Intent(appContext, TorrentServerForegroundService::class.java).apply {
                            action = TorrentServerForegroundService.ACTION_START_OR_UPDATE
                            putExtra(TorrentServerForegroundService.EXTRA_TITLE, title)
                            putExtra(TorrentServerForegroundService.EXTRA_CONTENT, content)
                        }
                        startForegroundServiceCompat(appContext, serviceIntent)
                    }
                    result.success(true)
                }
                "isServiceRunning" -> {
                    result.success(TorrentServerForegroundService.isServiceRunning)
                }
                "stopService" -> {
                    TorrentServerForegroundService.setKeepServerRunningPref(appContext, false)
                    TorrentServerForegroundService.cancelRestartAlarm(appContext)
                    val serviceIntent = Intent(appContext, TorrentServerForegroundService::class.java)
                    appContext.stopService(serviceIntent)
                    result.success(true)
                }
                "getBackgroundHealth" -> {
                    result.success(collectBackgroundHealth(appContext))
                }
                "requestBatteryOptimizationExemption" -> {
                    result.success(requestBatteryOptimizationExemptionIfNeeded(appContext, onlyOnce = false))
                }
                "openUnrestrictedDataSettings" -> {
                    result.success(openUnrestrictedDataSettings(appContext))
                }
                "openOemBackgroundSettings" -> {
                    result.success(openOemBackgroundSettings(appContext))
                }
                "openAppSettings" -> {
                    result.success(openAppDetailsSettings(appContext))
                }
                else -> result.notImplemented()
            }
        }

        val updChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_UPDATER)
        updaterChannel = updChannel
        updChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> {
                    try {
                        val pm = appContext.packageManager
                        val pInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            pm.getPackageInfo(
                                appContext.packageName,
                                PackageManager.PackageInfoFlags.of(0)
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            pm.getPackageInfo(appContext.packageName, 0)
                        }
                        val versionName = pInfo.versionName ?: "1.0.0"
                        val versionCode = PackageInfoCompat.getLongVersionCode(pInfo)
                        result.success(
                            mapOf(
                                "versionName" to versionName,
                                "versionCode" to versionCode,
                                "fullVersion" to "$versionName+$versionCode"
                            )
                        )
                    } catch (e: Exception) {
                        result.error("VERSION_ERROR", e.message, null)
                    }
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "Missing apkPath", null)
                        return@setMethodCallHandler
                    }
                    val apkFile = File(apkPath)
                    if (!apkFile.exists()) {
                        result.error("FILE_NOT_FOUND", "Update APK not found at $apkPath", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !appContext.packageManager.canRequestPackageInstalls()
                        ) {
                            pendingInstallApkPath = apkPath
                            val permIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:${appContext.packageName}")
                            }
                            val act = activityRef?.get()
                            if (act != null && !act.isFinishing) {
                                @Suppress("DEPRECATION")
                                act.startActivityForResult(permIntent, REQUEST_CODE_INSTALL_UNKNOWN_APPS)
                            } else {
                                permIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                appContext.startActivity(permIntent)
                            }
                            result.success("permission_requested")
                            return@setMethodCallHandler
                        }
                        launchApkInstaller(appContext, apkFile)
                        result.success("launched")
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun handleActivityResult(activity: Activity, requestCode: Int) {
        if (requestCode == REQUEST_CODE_INSTALL_UNKNOWN_APPS) {
            val pendingPath = pendingInstallApkPath
            pendingInstallApkPath = null
            if (!pendingPath.isNullOrBlank()) {
                val file = File(pendingPath)
                if (file.exists() &&
                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        activity.packageManager.canRequestPackageInstalls())
                ) {
                    try {
                        launchApkInstaller(activity, file)
                    } catch (_: Exception) {}
                }
            }
        }
    }

    private fun invokeOnMain(method: String, args: Any?) {
        mainHandler.post {
            try {
                foregroundChannel?.invokeMethod(method, args)
            } catch (_: Exception) {}
        }
    }

    private fun startForegroundServiceCompat(context: Context, intent: Intent) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (_: Exception) {
            try {
                context.startService(intent)
            } catch (_: Exception) {}
        }
    }

    private fun launchApkInstaller(context: Context, apkFile: File) {
        val apkUri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            apkFile
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(intent)
    }

    private fun requestNotificationPermissionIfNeeded(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            val act = activityRef?.get()
            if (act != null && !act.isFinishing) {
                ActivityCompat.requestPermissions(
                    act,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQUEST_CODE_NOTIFICATIONS
                )
            }
        }
        return granted
    }

    @SuppressLint("BatteryLife")
    private fun requestBatteryOptimizationExemptionIfNeeded(
        context: Context,
        onlyOnce: Boolean
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (onlyOnce && batteryPromptShown) return isIgnoringBatteryOptimizations(context)
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(context.packageName)) {
                return true
            }
            batteryPromptShown = true
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${context.packageName}")
            }
            launchIntent(context, intent)
            true
        } catch (_: Exception) {
            openAppDetailsSettings(context)
        }
    }

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(context.packageName)
        } catch (_: Exception) {
            true
        }
    }

    private fun collectBackgroundHealth(context: Context): Map<String, Any> {
        val ignoringBattery = isIgnoringBatteryOptimizations(context)

        val notifPermGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        val notificationsEnabled = try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                nm.areNotificationsEnabled()
            } else {
                true
            }
        } catch (_: Exception) {
            true
        }

        val unrestrictedData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                cm.restrictBackgroundStatus != ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
            } catch (_: Exception) {
                true
            }
        } else {
            true
        }

        return mapOf(
            "ignoringBatteryOptimizations" to ignoringBattery,
            "notificationPermissionGranted" to notifPermGranted,
            "notificationsEnabled" to notificationsEnabled,
            "unrestrictedBackgroundData" to unrestrictedData,
            "isServiceRunning" to TorrentServerForegroundService.isServiceRunning,
            "manufacturer" to (Build.MANUFACTURER ?: "Android"),
            "model" to (Build.MODEL ?: ""),
            "sdkInt" to Build.VERSION.SDK_INT
        )
    }

    private fun openUnrestrictedDataSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val intent = Intent(Settings.ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS).apply {
                data = Uri.parse("package:${context.packageName}")
            }
            if (launchIntent(context, intent)) return true
        }
        return openAppDetailsSettings(context)
    }

    private fun openOemBackgroundSettings(context: Context): Boolean {
        val pkg = context.packageName
        val mfr = (Build.MANUFACTURER ?: "").lowercase()
        val candidates = mutableListOf<Intent>()

        if (mfr.contains("xiaomi") || mfr.contains("redmi") || mfr.contains("poco")) {
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity"
                    )
                }
            )
            candidates.add(
                Intent("miui.intent.action.OP_AUTO_START").apply {
                    addCategory(Intent.CATEGORY_DEFAULT)
                }
            )
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.miui.powerkeeper",
                        "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                    )
                    putExtra("package_name", pkg)
                    putExtra("package_label", "Torrent Bridge")
                }
            )
        } else if (mfr.contains("samsung")) {
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.samsung.android.lool",
                        "com.samsung.android.sm.battery.ui.BatteryActivity"
                    )
                }
            )
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.samsung.android.sm",
                        "com.samsung.android.sm.ui.battery.BatteryActivity"
                    )
                }
            )
        } else if (mfr.contains("oppo") || mfr.contains("realme")) {
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                    )
                }
            )
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.oplus.battery",
                        "com.oplus.powermanager.fuelgaue.PowerUsageModelActivity"
                    )
                }
            )
        } else if (mfr.contains("vivo")) {
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"
                    )
                }
            )
        } else if (mfr.contains("oneplus")) {
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.oneplus.security",
                        "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
                    )
                }
            )
        } else if (mfr.contains("huawei") || mfr.contains("honor")) {
            candidates.add(
                Intent().apply {
                    component = ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                    )
                }
            )
        }

        for (intent in candidates) {
            if (launchIntent(context, intent)) return true
        }
        return openAppDetailsSettings(context)
    }

    private fun openAppDetailsSettings(context: Context): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${context.packageName}")
        }
        return launchIntent(context, intent)
    }

    private fun launchIntent(context: Context, intent: Intent): Boolean {
        return try {
            val act = activityRef?.get()
            if (act != null && !act.isFinishing) {
                act.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            true
        } catch (_: Exception) {
            false
        }
    }
}
