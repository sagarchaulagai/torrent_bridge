package com.rehesagar.torrentbridge

import android.app.Application

class TorrentBridgeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Resume the foreground service + headless Dart engine automatically if the
        // user left the server enabled and the OS restarts the process.
        if (TorrentServerForegroundService.shouldKeepServerRunning(this)) {
            TorrentBridgeEngineHost.getOrCreateEngine(this)
        }
    }
}
