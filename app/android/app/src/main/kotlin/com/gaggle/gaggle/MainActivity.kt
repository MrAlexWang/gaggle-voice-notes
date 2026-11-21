package com.gaggle.gaggle

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 原生能力通道（gaggle/native）：
 *  - 前台服务（录音保活 + 常驻通知）
 *  - 通知权限申请（Android 13+）
 *  - 电池优化白名单查询与跳转
 *
 * Dart 侧封装见 lib/android_foreground.dart
 */
class MainActivity : FlutterActivity() {

    private val channelName = "gaggle/native"
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecordingService" -> {
                    RecordingService.start(this, System.currentTimeMillis())
                    result.success(true)
                }

                "stopRecordingService" -> {
                    RecordingService.stop(this)
                    result.success(true)
                }

                "requestNotificationPermission" -> {
                    result.success(requestNotificationPermission())
                }

                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }

                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(true)
                }

                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        // 冷启动时如果是「点通知停止」进来的，直接转发
        handleStopExtra(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleStopExtra(intent)
    }

    /** 通知上的「停止」把应用拉回来时，通知 Flutter 去停录 */
    private fun handleStopExtra(intent: Intent?) {
        if (intent?.getBooleanExtra(RecordingService.EXTRA_STOP, false) == true) {
            intent.removeExtra(RecordingService.EXTRA_STOP)
            channel?.invokeMethod("stopRecordingFromNotification", null)
        }
    }

    // ---------- 通知权限（Android 13+） ----------

    private var pendingNotifResult: MethodChannel.Result? = null

    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return true
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF)
        return false
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIF) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingNotifResult?.success(granted)
            pendingNotifResult = null
        }
    }

    // ---------- 电池优化白名单 ----------

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Throwable) {
            false
        }
    }

    private fun requestIgnoreBatteryOptimizations() {
        // 先试系统标准弹窗；部分国产 ROM 不支持该 Action，退到应用详情页
        try {
            val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            i.data = Uri.parse("package:$packageName")
            startActivity(i)
        } catch (_: Throwable) {
            openAppSettings()
        }
    }

    private fun openAppSettings() {
        try {
            val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            i.data = Uri.parse("package:$packageName")
            startActivity(i)
        } catch (_: Throwable) {
            // 兜底：直接打开系统设置
            try {
                startActivity(Intent(Settings.ACTION_SETTINGS))
            } catch (_: Throwable) {
            }
        }
    }

    companion object {
        private const val REQ_NOTIF = 4101
    }
}
