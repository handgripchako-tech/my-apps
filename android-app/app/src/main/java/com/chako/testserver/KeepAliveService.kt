package com.chako.testserver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 背景でもアプリが止められないよう、通知付きで常駐するだけのサービス。
 * 通知のボタン（前・再生/停止・次・終了）も受け持つ。
 */
class KeepAliveService : Service() {

    companion object {
        const val CH = "keepalive"
        const val ACT_PREV = "prev"
        const val ACT_TOGGLE = "toggle"
        const val ACT_NEXT = "next"
        const val ACT_STOP = "stop"

        private fun log(expr: String) =
            "try{var a=JSON.parse(localStorage.getItem('app.dbg')||'[]');a.push(new Date().toTimeString().slice(0,8)+' '+$expr);localStorage.setItem('app.dbg',JSON.stringify(a.slice(-8)))}catch(e){};"

        private fun jsAction(name: String) =
            "(function(){var h=window.__msh||{},f=h['$name'];" +
                log("'btn:$name handler='+(f?'yes':'no')+' hidden='+document.hidden") +
                "if(f)f({action:'$name'})})()"

        private fun jsToggle() =
            "(function(){var h=window.__msh||{},c=window.__cur,p=c&&!c.paused,n=p?'pause':'play',f=h[n];" +
                log("'btn:toggle->'+n+' handler='+(f?'yes':'no')+' cur='+(c?'yes':'no')+' hidden='+document.hidden") +
                "if(f)f({action:n})})()"
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACT_PREV -> {
                Bridge.js(jsAction("previoustrack"))
                return START_NOT_STICKY
            }
            ACT_NEXT -> {
                Bridge.js(jsAction("nexttrack"))
                return START_NOT_STICKY
            }
            ACT_TOGGLE -> {
                Bridge.js(jsToggle())
                return START_NOT_STICKY
            }
            ACT_STOP -> {
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                android.os.Process.killProcess(android.os.Process.myPid())
                return START_NOT_STICKY
            }
        }
        startFg()
        return START_NOT_STICKY
    }

    private fun action(name: String, icon: Int, label: String, rc: Int): Notification.Action {
        val pi = PendingIntent.getService(
            this,
            rc,
            Intent(this, KeepAliveService::class.java).setAction(name),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), label, pi).build()
    }

    private fun startFg() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH, "再生の維持", NotificationManager.IMPORTANCE_LOW)
        )

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val n = Notification.Builder(this, CH)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("サーバー再生")
            .setContentText("画面を消しても再生を続けます")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(action(ACT_PREV, R.drawable.ic_prev, "前", 1))
            .addAction(action(ACT_TOGGLE, R.drawable.ic_play, "再生/停止", 2))
            .addAction(action(ACT_NEXT, R.drawable.ic_next, "次", 3))
            .addAction(action(ACT_STOP, R.drawable.ic_stop, "終了", 4))
            .setStyle(Notification.MediaStyle().setShowActionsInCompactView(0, 1, 2))
            .build()

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(1, n)
        }
        acquireLocks()
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (wake == null) {
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "testserver:play").apply {
                setReferenceCounted(false)
            }
        }
        wake?.acquire(8 * 60 * 60 * 1000L)

        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (wifi == null) {
            wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "testserver:wifi").apply {
                setReferenceCounted(false)
            }
        }
        wifi?.acquire()
    }

    private fun releaseLocks() {
        try {
            if (wake?.isHeld == true) wake?.release()
        } catch (_: Exception) {
        }
        try {
            if (wifi?.isHeld == true) wifi?.release()
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}
