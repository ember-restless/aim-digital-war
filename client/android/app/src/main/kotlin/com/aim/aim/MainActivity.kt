package com.aim.aim

import android.content.Context
import android.graphics.Rect
import android.net.wifi.WifiManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var keyboardChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        keyboardChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aim/keyboard")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 局域网组播发现（Minecraft 式）：获取 MulticastLock，否则收不到组播包
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("aim_lan_discover").apply {
                setReferenceCounted(false)
            }
        } catch (_: Exception) {
        }
        // 键盘高度监听：windowSoftInputMode=adjustNothing 时窗口不 resize，
        // MediaQuery.viewInsets 恒为 0，用 visibleDisplayFrame 差值算键盘高度发给 Flutter
        window.decorView.viewTreeObserver.addOnGlobalLayoutListener {
            try {
                val r = Rect()
                window.decorView.getWindowVisibleDisplayFrame(r)
                val screenH = window.decorView.height
                val kb = screenH - r.bottom
                val visible = kb > screenH * 0.18 // 阈值：键盘至少占屏幕 18% 才算弹起
                keyboardChannel?.invokeMethod(
                    "onKeyboard",
                    mapOf("visible" to visible, "height" to (if (visible) kb else 0)),
                )
            } catch (_: Exception) {
            }
        }
    }

    override fun onResume() {
        super.onResume()
        try {
            multicastLock?.acquire()
        } catch (_: Exception) {
        }
    }

    override fun onPause() {
        super.onPause()
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (_: Exception) {
        }
    }
}
