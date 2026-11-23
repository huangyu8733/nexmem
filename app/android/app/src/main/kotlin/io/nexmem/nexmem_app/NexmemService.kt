package io.nexmem.nexmem_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import java.util.concurrent.Executors

/**
 * 前台服务（P6-01 保活策略）。
 *
 * 作用：把内核进程从「后台空闲」提升为前台服务，避免锁屏后系统回收，
 * 由 [NexmemCore] 单例持有真正的 gomobile Handle，本服务只负责常驻通知。
 *
 * 保活要点：
 * - `START_STICKY`：进程被系统回收后由系统重建服务；
 * - 重建时按最近一次 `core.start` 配置调用 [NexmemCore.ensureStarted] 恢复内核，
 *   锁屏期间继续接收消息，Dart 重新挂载后按 seq 重放事件；
 * - 通知本身可点击回到应用，并使用低优先级渠道避免打扰。
 */
class NexmemService : Service() {

    companion object {
        const val CHANNEL_ID = "nexmem_core"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "io.nexmem.nexmem_app.STOP"

        private val worker = Executors.newSingleThreadExecutor { r ->
            Thread(r, "nexmem-service").apply { isDaemon = true }
        }

        fun start(context: Context) {
            val intent = Intent(context, NexmemService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, NexmemService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 进程被回收后重建时恢复内核；已在运行时为空操作。
        worker.execute { NexmemCore.ensureStarted(applicationContext) }
        // 保持内核运行；系统回收后自动重建，避免锁屏期间断收。
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
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
            NotificationChannel(CHANNEL_ID, "Nexmem 内核", NotificationManager.IMPORTANCE_LOW).apply {
                description = "保持后台消息接收"
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
            .setContentTitle("Nexmem 正在运行")
            .setContentText("保持后台消息接收")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setShowWhen(false)
            .setOngoing(true)
            .build()
    }
}
