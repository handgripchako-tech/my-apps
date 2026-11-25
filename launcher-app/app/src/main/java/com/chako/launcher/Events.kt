package com.chako.launcher

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId

/** カレンダーの予定（SharedPreferences に保存）と、時刻になったときの通知 */
object Events {
    const val ACTION = "com.chako.launcher.EVENT_ALARM"
    private const val CH = "events"

    class Ev(val date: LocalDate, val time: LocalTime, val title: String) {
        val key: String get() = "$date\t$time\t$title"
        val at: Long
            get() = LocalDateTime.of(date, time).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
    }

    private fun prefs(c: Context) = c.getSharedPreferences("launcher", Context.MODE_PRIVATE)

    fun load(c: Context): List<Ev> {
        val s = prefs(c).getString("events", "") ?: ""
        return s.split("\n").mapNotNull { l ->
            val p = l.split("\t", limit = 3)
            if (p.size < 3) null else try {
                Ev(LocalDate.parse(p[0]), LocalTime.parse(p[1]), p[2])
            } catch (e: Exception) {
                null
            }
        }.sortedBy { it.at }
    }

    private fun save(c: Context, list: List<Ev>) {
        prefs(c).edit().putString("events", list.joinToString("\n") { it.key }).apply()
    }

    fun add(c: Context, e: Ev) {
        save(c, load(c) + e)
        schedule(c, e)
    }

    fun remove(c: Context, e: Ev) {
        cancel(c, e)
        var removed = false
        save(c, load(c).filter { x -> if (!removed && x.key == e.key) { removed = true; false } else true })
    }

    private fun pi(c: Context, e: Ev): PendingIntent {
        val i = Intent(c, EventReceiver::class.java)
            .setAction(ACTION)
            .setData(Uri.parse("ev://" + Uri.encode(e.key)))
            .putExtra("title", e.title)
            .putExtra("time", e.time.toString())
        return PendingIntent.getBroadcast(c, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun schedule(c: Context, e: Ev) {
        if (e.at <= System.currentTimeMillis()) return
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val p = pi(c, e)
        try {
            if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, e.at, p)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, e.at, p)
            }
        } catch (se: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, e.at, p)
        }
    }

    private fun cancel(c: Context, e: Ev) {
        (c.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pi(c, e))
    }

    fun rescheduleAll(c: Context) {
        load(c).forEach { schedule(c, it) }
    }

    fun notify(c: Context, title: String, time: String) {
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(CH, "予定", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(
            c, 0,
            Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(c, CH)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title)
            .setContentText("$time の予定")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        nm.notify((title + time + System.nanoTime()).hashCode(), n)
    }
}

class EventReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        if (i.action == Events.ACTION) {
            Events.notify(c, i.getStringExtra("title") ?: "予定", i.getStringExtra("time") ?: "")
        } else {
            Events.rescheduleAll(c) // 再起動・アプリ更新・時刻変更のあとに予約し直す
        }
    }
}
