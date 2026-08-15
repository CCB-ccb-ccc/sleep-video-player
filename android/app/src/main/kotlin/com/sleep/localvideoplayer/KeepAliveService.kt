package com.sleep.localvideoplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 后台播放保活服务。
 * 开启后以“前台服务”身份运行：进程优先级提升，息屏 / 切后台也不会被系统回收，
 * 同时持有 mediaPlayback 前台服务类型，音频焦点更稳定，从而保证 ExoPlayer 持续出声。
 */
class KeepAliveService : Service() {
    companion object {
        const val CHANNEL_ID = "bg_play_channel"
        const val NOTIF_ID = 1001
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "后台播放",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.setShowBadge(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("助眠播放器")
            .setContentText("后台播放中，息屏也能继续听")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
