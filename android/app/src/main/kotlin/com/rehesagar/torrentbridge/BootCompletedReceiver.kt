package com.rehesagar.torrentbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Restores the Torrent Bridge Foreground Service after device reboot or app
 * update if the server was left running.
 */
class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        if (!TorrentServerForegroundService.shouldKeepServerRunning(context)) {
            return
        }

        val serviceIntent = Intent(context, TorrentServerForegroundService::class.java).apply {
            this.action = TorrentServerForegroundService.ACTION_START_OR_UPDATE
            putExtra(TorrentServerForegroundService.EXTRA_TITLE, "Torrent Bridge Running")
            putExtra(TorrentServerForegroundService.EXTRA_CONTENT, "Resuming HTTP streaming server...")
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (_: Exception) {
            // Android 12+ may restrict background FGS start on boot if battery optimization
            // exemption has not been granted yet; fail gracefully without crashing.
        }
    }
}
