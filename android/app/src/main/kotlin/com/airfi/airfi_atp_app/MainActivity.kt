package com.airfi.airfi_atp_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var talkback: TalkbackAudioPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        talkback = TalkbackAudioPlugin(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        talkback?.release()
        talkback = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
