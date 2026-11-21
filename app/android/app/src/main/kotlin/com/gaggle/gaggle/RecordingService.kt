package com.gaggle.gaggle

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 录音前台服务。
 *
 * 作用：录音期间把进程提升为「前台服务」，避免 Android 在内存紧张或息屏后把进程回收，
 * 同时按系统要求常驻一条通知（含计时与「停止」）。
 *
 * 注意：真正的录音仍在 Flutter 引擎内（同一进程）。所以通知上的「停止」不是直接
 * 杀服务，而是把应用拉到前台并通知 Flutter 执行 stopRecord()，保证录音正常收尾落盘。
 */
class RecordingService : Service() {

    companion object {
        private const val CHANNEL_ID = "gaggle_recording"
        private const val NOTIFICATION_ID = 4101
        private const val ACTION_STOP = "com.gaggle.gaggle.action.STOP_RECORDING"

        /** 通知点击/停止时带回的标记，MainActivity 会转发给 Flutter */
        const val EXTRA_STOP = "gaggle.stopRecording"

        /** 启动前台服务；[sinceMs] 用于通知里的计时器起点 */
        fun start(context: Context, sinceMs: Long) {
            val i = Intent(context, RecordingService::class.java)
            i.putExtra("since", sinceMs)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        /** 停止前台服务（只撤掉通知与前台状态，不动录音本身） */
        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // 通知上的「停止」：把应用拉到前台，由 Dart 侧真正停止录音
            val open = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra(EXTRA_STOP, true)
            }
            startActivity(open)
            return START_NOT_STICKY
        }

        val since = intent?.getLongExtra("since", System.currentTimeMillis())
            ?: System.currentTimeMillis()

        startForeground(NOTIFICATION_ID, buildNotification(since))
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            "录音状态",
            NotificationManager.IMPORTANCE_LOW // 常驻但不打扰：无声音、不弹横幅
        ).apply {
            description = "录音进行中的常驻通知"
            setShowBadge(false)
        }
        mgr.createNotificationChannel(ch)
    }

    private fun buildNotification(since: Long): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

        // 点通知 → 回到应用
        val openIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val contentPi = PendingIntent.getActivity(this, 1, openIntent, flags)

        // 点「停止」→ 回到应用并让它停录
        val stopIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_STOP, true)
        }
        val stopPi = PendingIntent.getActivity(this, 2, stopIntent, flags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("雁书正在录音")
            .setContentText("锁屏也不中断 · 点按返回应用")
            // 系统自带的麦克风图标，避免额外引入 drawable
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setWhen(since)
            .setUsesChronometer(true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentPi)
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "停止",
                    stopPi
                ).build()
            )
            .build()
    }
}
