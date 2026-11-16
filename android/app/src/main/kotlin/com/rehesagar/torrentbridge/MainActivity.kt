package com.rehesagar.torrentbridge

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        TorrentBridgeEngineHost.attachActivity(this)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return TorrentBridgeEngineHost.getOrCreateEngine(context)
    }

    override fun shouldDestroyEngineWithHost(): Boolean {
        // Keep the shared FlutterEngine alive inside the Foreground Service when the
        // Activity is closed or swiped away from Recents.
        return false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        TorrentBridgeEngineHost.attachActivity(this)
        TorrentBridgeEngineHost.ensureChannelsConfigured(applicationContext, flutterEngine)
    }

    override fun onDestroy() {
        TorrentBridgeEngineHost.detachActivity(this)
        super.onDestroy()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        TorrentBridgeEngineHost.handleActivityResult(this, requestCode)
    }
}
