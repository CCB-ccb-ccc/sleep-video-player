package com.sleep.localvideoplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * 后台播放保活服务。
 * 开启后以“前台服务”身份运行：进程优先级提升，息屏 / 切后台也不会被系统轻易回收；
 * 同时持有 mediaPlayback 前台服务类型，并【自身持有 PARTIAL_WAKE_LOCK】。
 *
 * 关键点（华为 / 荣耀等激进省电机型）：
 * 普通后台 App 持有的 wakelock 在息屏时会被系统直接忽略，导致 CPU 休眠、ExoPlayer
 * 解码线程停 → 声音戛然而止。而【前台服务内部持有的 wakelock 受系统尊重】，
 * 因此这里在服务启动时就主动拿锁，息屏后 CPU 不睡，音频才能持续。
 */
class KeepAliveService : Service() {
    companion object {
        const val CHANNEL_ID = "bg_play_channel"
        const val NOTIF_ID = 1001
        const val WAKE_LOCK_TAG = "SleepPlayer::BackgroundPlay"
    }

    private var wakeLock: PowerManager.WakeLock? = null

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

        // 服务自身持有 PARTIAL_WAKE_LOCK（不限时，直到服务停止才释放），
        // 保证息屏后 CPU 不休眠，ExoPlayer 持续解码出声。
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
        wakeLock?.setReferenceCounted(false)
        wakeLock?.acquire()

        return START_STICKY
    }

    override fun onDestroy() {
        // 释放唤醒锁，让 CPU 可重新休眠（用户关闭“后台”开关时调用）
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
