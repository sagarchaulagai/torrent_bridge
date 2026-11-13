package com.rehesagar.torrentbridge

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "com.rehesagar.torrentbridge/foreground_service"
    private var methodChannel: MethodChannel? = null
    private var batteryPromptShown = false

    @SuppressLint("BatteryLife")
    private fun requestBatteryOptimizationExemptionIfNeeded() {
        if (batteryPromptShown || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                batteryPromptShown = true
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            }
        } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel = channel

        TorrentServerForegroundService.onStopRequestedCallback = {
            runOnUiThread {
                channel.invokeMethod("onStopServerRequested", null)
            }
        }
        TorrentServerForegroundService.onServiceDestroyedCallback = {
            runOnUiThread {
                channel.invokeMethod("onServiceDestroyed", null)
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val granted = ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.POST_NOTIFICATIONS
                        ) == PackageManager.PERMISSION_GRANTED
                        if (!granted) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                1001
                            )
                        }
                        result.success(true)
                    } else {
                        result.success(true)
                    }
                }
                "startService" -> {
                    val title = call.argument<String>("title") ?: "Torrent Bridge Running"
                    val content = call.argument<String>("content") ?: "Streaming audio over HTTP"
                    val serviceIntent = Intent(this, TorrentServerForegroundService::class.java).apply {
                        action = TorrentServerForegroundService.ACTION_START_OR_UPDATE
                        putExtra(TorrentServerForegroundService.EXTRA_TITLE, title)
                        putExtra(TorrentServerForegroundService.EXTRA_CONTENT, content)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    requestBatteryOptimizationExemptionIfNeeded()
                    result.success(true)
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "Torrent Bridge Running"
                    val content = call.argument<String>("content") ?: "Streaming audio over HTTP"
                    if (TorrentServerForegroundService.isServiceRunning) {
                        TorrentServerForegroundService.updateNotificationDirect(this, title, content)
                    } else {
                        val serviceIntent = Intent(this, TorrentServerForegroundService::class.java).apply {
                            action = TorrentServerForegroundService.ACTION_START_OR_UPDATE
                            putExtra(TorrentServerForegroundService.EXTRA_TITLE, title)
                            putExtra(TorrentServerForegroundService.EXTRA_CONTENT, content)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                    }
                    result.success(true)
                }
                "isServiceRunning" -> {
                    result.success(TorrentServerForegroundService.isServiceRunning)
                }
                "stopService" -> {
                    val serviceIntent = Intent(this, TorrentServerForegroundService::class.java)
                    stopService(serviceIntent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
