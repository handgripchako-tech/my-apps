package com.chako.timer

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs

/**
 * 終了の予約が生きている間、画面の上（ゲーム中でも）に残り時間を出す小さな窓。
 * タップで開いて、残り時間の増減・取り消し・いますぐ終了ができる。
 * アクセシビリティのオーバーレイなので「他のアプリの上に重ねて表示」の許可は不要。
 *
 * 出す条件:
 *  ・起動から○分後の終了 … 予約中ならいつでも
 *  ・毎日の終了時刻     … そのアプリが前面にいて、残り12時間以内のとき
 */
class FloatingStop(private val svc: MacroService) {
    companion object {
        fun enabled(c: Context): Boolean =
            c.getSharedPreferences("timer", Context.MODE_PRIVATE).getBoolean("float", true)

        fun setEnabled(c: Context, on: Boolean) {
            c.getSharedPreferences("timer", Context.MODE_PRIVATE).edit().putBoolean("float", on).apply()
        }

        /** 「隠す」中に出す通知の番号（ジョブの通知と重ならない大きな数） */
        const val HIDDEN_NOTIF_ID = 900001
    }

    private val h = Handler(Looper.getMainLooper())
    private val wm = svc.getSystemService(WindowManager::class.java)
    private val prefs = svc.getSharedPreferences("timer", Context.MODE_PRIVATE)
    private val density = svc.resources.displayMetrics.density
    private fun dp(v: Int) = (v * density).toInt()

    /** いま前面にいるアプリ（アクセシビリティのイベントから追う）。 */
    var fgPkg: String? = null

    private var root: LinearLayout? = null
    private var lp: WindowManager.LayoutParams? = null
    private var bubble: TextView? = null
    private var detail: LinearLayout? = null
    private var title: TextView? = null
    private var expanded = false
    private var cur: PendingStop? = null
    private var curLabel = ""
    private var hiddenKey: String? = null
    private var armed: String? = null
    private var armedUntil = 0L
    private val confirmBtns = mutableMapOf<String, Button>()
    private var running = false

    private val tick = object : Runnable {
        override fun run() {
            try {
                update()
            } catch (_: Exception) {
            }
            if (running) h.postDelayed(this, 1000)
        }
    }

    fun start() {
        if (running) return
        running = true
        h.post(tick)
    }

    fun stop() {
        running = false
        h.removeCallbacks(tick)
        remove()
        hiddenKey = null
        cancelHiddenNotif()
    }

    private fun pick(): Pair<PendingStop, Job>? {
        val now = System.currentTimeMillis()
        val jobs = Store.load(svc).associateBy { it.id }
        for (s in Stops.all(svc)) {
            val j = jobs[s.id] ?: continue
            if (s.at < now - 5000) continue
            if ("${s.key}:${s.at}" == hiddenKey) continue
            val show = if (!s.daily) true
            else fgPkg == j.pkg && s.at - now <= 12 * 3600_000L
            if (show) return s to j
        }
        return null
    }

    private fun update() {
        // 隠していた終了予定が終わった（消えた）ら、隠す状態と通知を片付ける
        val hk = hiddenKey
        if (hk != null && Stops.all(svc).none { "${it.key}:${it.at}" == hk }) {
            hiddenKey = null
            cancelHiddenNotif()
        }
        val km = svc.getSystemService(KeyguardManager::class.java)
        if (!enabled(svc) || km.isKeyguardLocked || svc.isTeaching()) {
            remove()
            return
        }
        if (fgPkg == null) fgPkg = svc.rootInActiveWindow?.packageName?.toString()
        val p = pick()
        if (p == null) {
            remove()
            return
        }
        cur = p.first
        curLabel = p.second.label
        if (root == null) build()
        render()
    }

    private fun fmtLeft(ms: Long): String {
        val s = (ms.coerceAtLeast(0) + 999) / 1000
        val hh = s / 3600
        val mm = (s % 3600) / 60
        val ss = s % 60
        return if (hh > 0) "%d:%02d:%02d".format(hh, mm, ss) else "%02d:%02d".format(mm, ss)
    }

    private fun render() {
        val s = cur ?: return
        val left = s.at - System.currentTimeMillis()
        val clock = SimpleDateFormat("HH:mm", Locale.JAPAN).format(Date(s.at))
        bubble?.text = "⏱ " + fmtLeft(left)
        val bg = bubble?.background as? GradientDrawable
        bg?.setColor(
            when {
                left <= 60_000L -> Color.argb(230, 200, 30, 30)
                left <= 5 * 60_000L -> Color.argb(230, 200, 120, 0)
                else -> Color.argb(200, 20, 20, 20)
            }
        )
        title?.text = "「$curLabel」終了 $clock\n残り ${fmtLeft(left)}"
        if (armed != null && System.currentTimeMillis() > armedUntil) disarm()
    }

    private fun build() {
        val r = LinearLayout(svc)
        r.orientation = LinearLayout.VERTICAL
        r.gravity = Gravity.END

        val b = TextView(svc)
        b.textSize = 15f
        b.setTextColor(Color.WHITE)
        b.setPadding(dp(12), dp(6), dp(12), dp(6))
        val g = GradientDrawable()
        g.cornerRadius = dp(18).toFloat()
        g.setColor(Color.argb(200, 20, 20, 20))
        b.background = g
        r.addView(b)
        bubble = b

        val d = LinearLayout(svc)
        d.orientation = LinearLayout.VERTICAL
        d.setPadding(dp(10), dp(8), dp(10), dp(8))
        val dg = GradientDrawable()
        dg.cornerRadius = dp(12).toFloat()
        dg.setColor(Color.argb(235, 30, 30, 30))
        d.background = dg
        val t = TextView(svc)
        t.setTextColor(Color.WHITE)
        t.textSize = 14f
        d.addView(t)
        title = t

        fun row(): LinearLayout {
            val rw = LinearLayout(svc)
            rw.orientation = LinearLayout.HORIZONTAL
            d.addView(rw)
            return rw
        }
        fun btn(parent: LinearLayout, text: String, onClick: (Button) -> Unit): Button {
            val bt = Button(svc)
            bt.text = text
            bt.textSize = 13f
            bt.isAllCaps = false
            bt.minWidth = 0
            bt.minimumWidth = 0
            bt.setPadding(dp(8), 0, dp(8), 0)
            bt.setOnClickListener { onClick(bt) }
            parent.addView(bt)
            return bt
        }
        val r1 = row()
        for (m in listOf(-10, -5, 5, 10, 30)) {
            btn(r1, if (m > 0) "+$m" else "$m") { change(m) }
        }
        val r2 = row()
        confirmBtns["now"] = btn(r2, "今すぐ終了") { confirm("now", it) }
        confirmBtns["skip"] = btn(r2, "取消") { confirm("skip", it) }
        val r3 = row()
        btn(r3, "隠す") {
            val s = cur
            if (s != null) {
                hiddenKey = "${s.key}:${s.at}"
                showHiddenNotif(curLabel, s.at)
            }
            expanded = false
            update()
        }
        btn(r3, "たたむ") { setExpanded(false) }
        d.visibility = View.GONE
        r.addView(d)
        detail = d

        val l = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        l.gravity = Gravity.TOP or Gravity.END
        l.x = prefs.getInt("float_x", dp(8))
        l.y = prefs.getInt("float_y", dp(120))

        // 吹き出しはドラッグで移動、軽くタップで開閉
        var sx = 0f
        var sy = 0f
        var ox = 0
        var oy = 0
        var moved = false
        b.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    sx = e.rawX
                    sy = e.rawY
                    ox = l.x
                    oy = l.y
                    moved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - sx
                    val dy = e.rawY - sy
                    if (abs(dx) > dp(8) || abs(dy) > dp(8)) moved = true
                    if (moved) {
                        l.x = (ox - dx.toInt()).coerceAtLeast(0) // 右寄せなので左に動かすと x が増える
                        l.y = (oy + dy.toInt()).coerceAtLeast(0)
                        try {
                            wm.updateViewLayout(r, l)
                        } catch (_: Exception) {
                        }
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (moved) {
                        prefs.edit().putInt("float_x", l.x).putInt("float_y", l.y).apply()
                    } else {
                        setExpanded(!expanded)
                    }
                }
            }
            true
        }

        try {
            wm.addView(r, l)
            root = r
            lp = l
        } catch (_: Exception) {
            root = null
        }
        setExpanded(expanded)
    }

    private fun setExpanded(on: Boolean) {
        expanded = on
        detail?.visibility = if (on) View.VISIBLE else View.GONE
        if (!on) disarm()
        val r = root ?: return
        val l = lp ?: return
        try {
            wm.updateViewLayout(r, l)
        } catch (_: Exception) {
        }
    }

    private fun change(min: Int) {
        val s = cur ?: return
        val now = System.currentTimeMillis()
        val at = (s.at + min * 60_000L).coerceAtLeast(now + 60_000L)
        if (Scheduler.setStopTime(svc, s.id, s.daily, at)) {
            val clock = SimpleDateFormat("HH:mm", Locale.JAPAN).format(Date(at))
            Store.log(svc, "「$curLabel」の終了を${if (min > 0) "+" else ""}${min}分 → $clock")
            cur = s.copy(at = at)
            render()
        }
    }

    /** 「今すぐ終了」「取消」は、2回押しで確定（誤タップ防止）。 */
    private fun confirm(what: String, b: Button) {
        if (armed != what) {
            disarm()
            armed = what
            armedUntil = System.currentTimeMillis() + 3000
            b.text = "もう一度で確定"
            return
        }
        disarm()
        val s = cur ?: return
        if (what == "now") {
            Store.log(svc, "「$curLabel」をフローティングから終了")
            Scheduler.fireStopNow(svc, s.id, s.daily)
        } else {
            Scheduler.skipStop(svc, s.id, s.daily)
            Store.log(svc, "「$curLabel」の今回の終了を取り消し")
        }
        expanded = false
        update()
    }

    private fun disarm() {
        armed = null
        confirmBtns["now"]?.text = "今すぐ終了"
        confirmBtns["skip"]?.text = "取消"
    }

    private fun remove() {
        val r = root ?: return
        try {
            wm.removeView(r)
        } catch (_: Exception) {
        }
        root = null
        lp = null
        bubble = null
        detail = null
        title = null
        confirmBtns.clear()
        expanded = false
        armed = null
    }

    /** 通知の「表示する」から呼ばれる。隠していた窓をもう一度出す。 */
    fun unhide() {
        h.post {
            hiddenKey = null
            cancelHiddenNotif()
            try {
                update()
            } catch (_: Exception) {
            }
        }
    }

    private fun showHiddenNotif(label: String, at: Long) {
        try {
            val nm = svc.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel("timer_float", "フローティングを隠している間", NotificationManager.IMPORTANCE_LOW)
            )
            val pi = PendingIntent.getBroadcast(
                svc, HIDDEN_NOTIF_ID, Intent(svc, UnhideReceiver::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val clock = SimpleDateFormat("HH:mm", Locale.JAPAN).format(Date(at))
            val n = Notification.Builder(svc, "timer_float")
                .setSmallIcon(android.R.drawable.ic_menu_recent_history)
                .setContentTitle("⏱「$label」終了 $clock（非表示中）")
                .setContentText("タップでフローティングを表示に戻す")
                .setContentIntent(pi)
                .addAction(Notification.Action.Builder(null, "表示する", pi).build())
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
            nm.notify(HIDDEN_NOTIF_ID, n)
        } catch (_: Exception) {
        }
    }

    private fun cancelHiddenNotif() {
        try {
            svc.getSystemService(NotificationManager::class.java).cancel(HIDDEN_NOTIF_ID)
        } catch (_: Exception) {
        }
    }

    fun refresh() {
        h.post {
            try {
                update()
            } catch (_: Exception) {
            }
        }
    }
}
