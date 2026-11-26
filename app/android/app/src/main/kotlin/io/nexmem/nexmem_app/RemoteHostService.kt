package io.nexmem.nexmem_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 远程控制被控期间的 mediaProjection 前台服务。
 *
 * Android 10（API 29）起，调用 `MediaProjectionManager.getMediaProjection`
 * 前必须存在 `mediaProjection` 类型的前台服务，否则系统抛 SecurityException。
 * 该服务只负责满足系统要求与展示“正在被远程控制”的常驻通知，采集本身由
 * flutter_webrtc 完成。
 */
class RemoteHostService : Service() {

    companion object {
        const val CHANNEL_ID = "nexmem_remote"
        const val NOTIFICATION_ID = 1002
        const val ACTION_STOP = "io.nexmem.nexmem_app.REMOTE_STOP"

        fun start(context: Context) {
            val intent = Intent(context, RemoteHostService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RemoteHostService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "远程控制", NotificationManager.IMPORTANCE_LOW).apply {
                description = "被远程控制时保持屏幕共享"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        return builder
            .setContentTitle("本机正在被远程控制")
            .setContentText("屏幕正在共享，点按返回应用可随时停止")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setShowWhen(false)
            .setOngoing(true)
            .build()
    }
}
