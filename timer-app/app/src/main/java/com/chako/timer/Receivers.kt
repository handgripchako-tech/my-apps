package com.chako.timer

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.app.Notification

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra("id", -1)
        val job = Store.get(context, id) ?: return
        if (!job.enabled) {
            Scheduler.schedule(context, job)
            return
        }
        if (job.once) {
            // 1回だけ: 起動済みにして、終了の予約が無ければここで自動OFF
            job.onceStarted = true
            if (job.stopAt < 0) job.enabled = false
            Store.put(context, job)
        }
        // 毎日の予定なら、ここで明日分を予約する（1回だけなら予約しない）
        Scheduler.schedule(context, job)
        val svc = MacroService.instance
        if (svc != null) {
            svc.runJob(job, false)
        } else {
            Store.log(context, "「${job.label}」アクセシビリティがOFFのため通知のみ")
            Notifier.fallback(context, job)
        }
    }
}

class StopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val job = Store.get(context, intent.getIntExtra("id", -1)) ?: return
        if (intent.getBooleanExtra("daily", false)) {
            if (!job.enabled) return
            if (job.once) {
                // 1回だけ: 終了まで済んだので自動OFF
                job.enabled = false
                Store.put(context, job)
            } else {
                // 毎日の終了時刻: 明日分を予約し直す
                Scheduler.scheduleStopAt(context, job)
            }
        }
        val svc = MacroService.instance
        if (svc != null) {
            svc.stopApp(job.pkg, job.label)
        } else {
            // アクセシビリティがOFFなので、裏に回っている場合だけ閉じられる
            context.getSystemService(ActivityManager::class.java).killBackgroundProcesses(job.pkg)
            Store.log(context, "「${job.label}」終了を試みました（アクセシビリティOFF）")
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Scheduler.scheduleAll(context)
    }
}

object Notifier {
    /** 自動起動できないとき、タップで起動できる通知を出す。 */
    fun fallback(c: Context, job: Job) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel("timer", "時限起動", NotificationManager.IMPORTANCE_HIGH)
        )
        val launch = c.packageManager.getLaunchIntentForPackage(job.pkg) ?: return
        val pi = PendingIntent.getActivity(c, job.id, launch, PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(c, "timer")
            .setSmallIcon(android.R.drawable.ic_menu_recent_history)
            .setContentTitle("時限起動：自動で起動できませんでした")
            .setContentText("タップで「${job.label}」を起動")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        nm.notify(job.id, n)
    }
}
