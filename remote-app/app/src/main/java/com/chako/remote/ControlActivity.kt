package com.chako.remote

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import java.net.URLEncoder
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/** 操作する側。相手の画面を1秒ごとに取って表示し、タッチを相手に送る。 */
class ControlActivity : Activity() {

    private lateinit var host: String
    private lateinit var screen: ScreenView
    private lateinit var info: TextView
    private lateinit var padPanel: LinearLayout
    private lateinit var adjustPanel: LinearLayout
    private val wake = Semaphore(0)
    @Volatile private var running = false

    // PINパッドの位置（画面に対する割合 0〜100）: 左端, 右端, 上端, 下端
    private val padPos = intArrayOf(12, 88, 52, 95)
    private val padLabels = arrayOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "✕", "0", "✓")

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun padPoint(index: Int): Pair<Float, Float> {
        val c = index % 3
        val r = index / 3
        val l = padPos[0] / 100f
        val rr = padPos[1] / 100f
        val t = padPos[2] / 100f
        val b = padPos[3] / 100f
        return Pair(l + (rr - l) * (c + 0.5f) / 3f, t + (b - t) * (r + 0.5f) / 4f)
    }

    inner class ScreenView(ctx: Context) : View(ctx) {
        var bmp: Bitmap? = null
        var showGuide = false
        private val dest = RectF()
        private var dx = 0f
        private var dy = 0f
        private var dt = 0L
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        private fun calcDest() {
            val b = bmp
            if (b == null) {
                dest.set(0f, 0f, width.toFloat(), height.toFloat())
                return
            }
            val s = minOf(width.toFloat() / b.width, height.toFloat() / b.height)
            val w = b.width * s
            val h = b.height * s
            dest.set((width - w) / 2, (height - h) / 2, (width + w) / 2, (height + h) / 2)
        }

        override fun onDraw(c: Canvas) {
            c.drawColor(Color.BLACK)
            calcDest()
            bmp?.let { c.drawBitmap(it, null, dest, null) }
            if (showGuide) {
                paint.textAlign = Paint.Align.CENTER
                paint.textSize = dp(14).toFloat()
                for (i in 0 until 12) {
                    val (fx, fy) = padPoint(i)
                    val px = dest.left + dest.width() * fx
                    val py = dest.top + dest.height() * fy
                    paint.style = Paint.Style.STROKE
                    paint.color = Color.rgb(0, 200, 180)
                    c.drawCircle(px, py, dp(14).toFloat(), paint)
                    paint.style = Paint.Style.FILL
                    c.drawText(padLabels[i], px, py + dp(5), paint)
                }
            }
        }

        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.action) {
                MotionEvent.ACTION_DOWN -> { dx = e.x; dy = e.y; dt = e.eventTime }
                MotionEvent.ACTION_UP -> {
                    calcDest()
                    if (dest.width() <= 0f) return true
                    val dur = e.eventTime - dt
                    val moved = Math.hypot((e.x - dx).toDouble(), (e.y - dy).toDouble()) > dp(16)
                    val x1 = (dx - dest.left) / dest.width()
                    val y1 = (dy - dest.top) / dest.height()
                    val x2 = (e.x - dest.left) / dest.width()
                    val y2 = (e.y - dest.top) / dest.height()
                    if (x1 < 0 || x1 > 1 || y1 < 0 || y1 > 1) return true
                    if (moved) {
                        send("/swipe?x1=$x1&y1=$y1&x2=$x2&y2=$y2&d=${dur.coerceIn(100, 1500)}")
                    } else {
                        send("/tap?x=$x1&y=$y1&d=${dur.coerceIn(50, 1500)}")
                    }
                }
            }
            return true
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        host = intent.getStringExtra("host") ?: ""

        val prefs = getSharedPreferences("remote", MODE_PRIVATE)
        for (i in 0 until 4) padPos[i] = prefs.getInt("pad$i", padPos[i])

        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(Color.BLACK)

        info = TextView(this)
        info.setTextColor(Color.LTGRAY)
        info.textSize = 12f
        info.setPadding(dp(8), dp(4), dp(8), dp(4))
        info.text = "接続中… $host"
        root.addView(info)

        screen = ScreenView(this)
        root.addView(screen, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        // ---- PINパッド ----
        padPanel = LinearLayout(this)
        padPanel.orientation = LinearLayout.VERTICAL
        padPanel.visibility = View.GONE

        val grid = GridLayout(this)
        grid.columnCount = 3
        for (i in 0 until 12) {
            val b = Button(this)
            b.text = padLabels[i]
            b.textSize = 18f
            b.isAllCaps = false
            b.setOnClickListener {
                val (fx, fy) = padPoint(i)
                send("/tap?x=$fx&y=$fy&d=60")
            }
            val lp = GridLayout.LayoutParams(
                GridLayout.spec(i / 3, 1f),
                GridLayout.spec(i % 3, 1f)
            )
            lp.width = 0
            lp.height = dp(46)
            grid.addView(b, lp)
        }
        padPanel.addView(grid, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        val adjBtn = Button(this)
        adjBtn.text = "位置を調整"
        adjBtn.isAllCaps = false
        padPanel.addView(adjBtn)

        adjustPanel = LinearLayout(this)
        adjustPanel.orientation = LinearLayout.VERTICAL
        adjustPanel.visibility = View.GONE
        val names = arrayOf("左端", "右端", "上端", "下端")
        for (i in 0 until 4) {
            val rowL = LinearLayout(this)
            rowL.orientation = LinearLayout.HORIZONTAL
            rowL.gravity = Gravity.CENTER_VERTICAL
            val tv = TextView(this)
            tv.text = names[i]
            tv.setTextColor(Color.LTGRAY)
            tv.textSize = 12f
            rowL.addView(tv, LinearLayout.LayoutParams(dp(44), LinearLayout.LayoutParams.WRAP_CONTENT))
            val sb = SeekBar(this)
            sb.max = 100
            sb.progress = padPos[i]
            sb.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(s: SeekBar?, p: Int, fromUser: Boolean) {
                    padPos[i] = p
                    prefs.edit().putInt("pad$i", p).apply()
                    screen.invalidate()
                }
                override fun onStartTrackingTouch(s: SeekBar?) {}
                override fun onStopTrackingTouch(s: SeekBar?) {}
            })
            rowL.addView(sb, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            adjustPanel.addView(rowL)
        }
        padPanel.addView(adjustPanel)
        adjBtn.setOnClickListener {
            adjustPanel.visibility = if (adjustPanel.visibility == View.GONE) View.VISIBLE else View.GONE
        }
        root.addView(padPanel)

        // ---- 下のボタン ----
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER
        fun rb(label: String, f: () -> Unit) {
            val b = Button(this)
            b.text = label
            b.textSize = 12f
            b.isAllCaps = false
            b.setPadding(0, 0, 0, 0)
            b.setOnClickListener { f() }
            row.addView(b, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        rb("点灯") { send("/wake") }
        rb("戻る") { send("/key?k=back") }
        rb("ホーム") { send("/key?k=home") }
        rb("履歴") { send("/key?k=recents") }
        rb("アプリ") { showApps() }
        rb("PIN") {
            val show = padPanel.visibility == View.GONE
            padPanel.visibility = if (show) View.VISIBLE else View.GONE
            screen.showGuide = show
            screen.invalidate()
        }
        root.addView(row)
        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        running = true
        Thread {
            while (running) {
                val data = Net.get(host, "/screen")
                if (data != null) {
                    val b = BitmapFactory.decodeByteArray(data, 0, data.size)
                    runOnUiThread {
                        if (b != null) {
                            screen.bmp = b
                            screen.invalidate()
                        }
                        info.text = "接続中 $host"
                    }
                    wake.tryAcquire(700, TimeUnit.MILLISECONDS)
                } else {
                    val alive = Net.get(host, "/ping", 2000) != null
                    runOnUiThread {
                        info.text = if (alive) "画面が取れません（PIN入力画面など）。操作は届きます"
                        else "つながりません（相手のリモコンがオンか、Tailscaleを確認）"
                    }
                    wake.tryAcquire(if (alive) 1000 else 2000, TimeUnit.MILLISECONDS)
                }
            }
        }.start()
    }

    override fun onPause() {
        running = false
        wake.release()
        super.onPause()
    }

    private fun send(path: String) {
        Thread {
            Net.get(host, path)
            Thread.sleep(350)
            wake.release()
        }.start()
    }

    private fun showApps() {
        Thread {
            val data = Net.get(host, "/apps", 8000)
            runOnUiThread {
                if (data == null) {
                    Toast.makeText(this, "アプリ一覧を取れませんでした", Toast.LENGTH_SHORT).show()
                    return@runOnUiThread
                }
                val apps = String(data, Charsets.UTF_8).lines()
                    .filter { it.contains('\t') }
                    .map { Pair(it.substringBefore('\t'), it.substringAfter('\t')) }
                AlertDialog.Builder(this)
                    .setTitle("起動するアプリ")
                    .setItems(apps.map { it.second }.toTypedArray()) { _, i ->
                        Thread {
                            val r = Net.get(host, "/launch?pkg=" + URLEncoder.encode(apps[i].first, "UTF-8"))
                            runOnUiThread {
                                Toast.makeText(this, r?.let { String(it) } ?: "送れませんでした", Toast.LENGTH_SHORT).show()
                            }
                            Thread.sleep(1200)
                            wake.release()
                        }.start()
                    }
                    .show()
            }
        }.start()
    }
}
