package com.chako.timer

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.graphics.Color
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.hypot
import kotlin.math.roundToInt
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * アクセシビリティサービス。
 * ・バックグラウンドからのアプリ起動（Android 10以降の制限を避けるため）
 * ・マクロ（タップ・スワイプ・戻る・文字タップ）の実行
 */
class MacroService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: MacroService? = null
    }

    private val handler = Handler(Looper.getMainLooper())
    private var gen = 0

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    fun runJob(job: Job, force: Boolean) {
        gen++
        val myGen = gen
        if (!force && job.skipIfRunning) {
            if (!hasUsageAccess()) {
                Store.log(this, "「${job.label}」使用状況アクセス未許可のため、起動中チェックなしで続行")
            } else if (Usage.isForeground(this, job.pkg)) {
                Store.log(this, "「${job.label}」すでに起動中のためスルー")
                return
            }
        }
        wakeScreen()
        val km = getSystemService(android.app.KeyguardManager::class.java)
        if (km.isKeyguardLocked && !km.isKeyguardSecure) {
            // 「スワイプだけ」のロックなら、上にスワイプして解除してから起動する
            Store.log(this, "ロック画面をスワイプで解除します")
            handler.postDelayed({
                val dm = resources.displayMetrics
                val p = Path()
                p.moveTo(dm.widthPixels / 2f, dm.heightPixels * 0.85f)
                p.lineTo(dm.widthPixels / 2f, dm.heightPixels * 0.25f)
                gesture(p, 300) {
                    handler.postDelayed({ launchAndMacro(job, force, myGen) }, 800)
                }
            }, 1200)
        } else if (km.isKeyguardLocked && PinStore.usable(this)) {
            Store.log(this, "PINでロックを解除します")
            handler.postDelayed({
                swipeUp {
                    handler.postDelayed({ unlockWithPin(job, force, myGen) }, 1200)
                }
            }, 1200)
        } else {
            if (km.isKeyguardLocked) {
                val why = if (PinStore.stoppedByFails(this)) "PIN自動入力は停止中" else "PIN未登録"
                Store.log(this, "ロック中（$why）: 起動はしますが、解除までアプリは見えません")
            }
            launchAndMacro(job, force, myGen)
        }
    }

    private fun swipeUp(done: () -> Unit) {
        val dm = resources.displayMetrics
        val p = Path()
        p.moveTo(dm.widthPixels / 2f, dm.heightPixels * 0.85f)
        p.lineTo(dm.widthPixels / 2f, dm.heightPixels * 0.25f)
        gesture(p, 300, done)
    }

    private fun unlockWithPin(job: Job, force: Boolean, myGen: Int) {
        if (myGen != gen) return
        val pin = PinStore.load(this)
        if (pin.isNullOrEmpty()) {
            Store.log(this, "PINを読み出せませんでした（再登録してください）")
            launchAndMacro(job, force, myGen)
            return
        }
        typeDigits(pin, 0) { typedAll ->
            if (!typedAll) {
                Store.log(this, "PIN入力画面が見つかりません（解除せず続行）")
                launchAndMacro(job, force, myGen)
            } else {
                handler.postDelayed({ pressEnter() }, 300)
                handler.postDelayed({
                    val km = getSystemService(android.app.KeyguardManager::class.java)
                    if (!km.isKeyguardLocked) {
                        PinStore.recordResult(this, true)
                        Store.log(this, "PINで解除しました")
                    } else {
                        PinStore.recordResult(this, false)
                        Store.log(this, "PINで解除できませんでした" +
                            if (PinStore.stoppedByFails(this)) "（連続失敗のため自動入力を停止）" else "")
                    }
                    launchAndMacro(job, force, myGen)
                }, 2200)
            }
        }
    }

    private fun typeDigits(pin: String, i: Int, done: (Boolean) -> Unit) {
        if (i >= pin.length) {
            done(true)
            return
        }
        if (!clickKey(pin[i].toString())) {
            done(false)
            return
        }
        handler.postDelayed({ typeDigits(pin, i + 1, done) }, 300)
    }

    private fun pressEnter() {
        for (label in listOf("Enter", "入力", "OK", "決定", "確認")) {
            if (clickKey(label)) return
        }
    }

    private fun allRoots(): List<AccessibilityNodeInfo> {
        val out = mutableListOf<AccessibilityNodeInfo>()
        try {
            for (w in windows) {
                val r = w.root
                if (r != null) out.add(r)
            }
        } catch (_: Exception) {
        }
        val a = rootInActiveWindow
        if (a != null) out.add(a)
        return out
    }

    private fun findExact(n: AccessibilityNodeInfo?, label: String, depth: Int): AccessibilityNodeInfo? {
        if (n == null || depth > 14) return null
        val t = n.text?.toString()
        val d = n.contentDescription?.toString()
        if (t == label || d == label || d?.startsWith("$label ") == true) return n
        for (i in 0 until n.childCount) {
            val r = findExact(n.getChild(i), label, depth + 1)
            if (r != null) return r
        }
        return null
    }

    private fun clickKey(label: String): Boolean {
        for (r in allRoots()) {
            val n = findExact(r, label, 0) ?: continue
            var c: AccessibilityNodeInfo? = n
            while (c != null) {
                if (c.isClickable && c.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
                c = c.parent
            }
            val b = Rect()
            n.getBoundsInScreen(b)
            if (!b.isEmpty) {
                val p = Path()
                p.moveTo(b.exactCenterX(), b.exactCenterY())
                gesture(p, 60) {}
                return true
            }
        }
        return false
    }

    private fun launchAndMacro(job: Job, force: Boolean, myGen: Int) {
        if (myGen != gen) return
        if (!launch(job.pkg)) {
            Store.log(this, "「${job.label}」起動に失敗")
            Notifier.fallback(this, job)
            return
        }
        Store.log(this, "「${job.label}」を起動" + if (force) "（テスト）" else "")
        Scheduler.scheduleStop(this, job)
        val steps = Macro.parse(job.macro)
        if (steps.isNotEmpty()) {
            // 起動直後は画面が整っていないので、少し待ってからマクロ開始
            handler.postDelayed({ waitUnlockThenRun(steps, myGen, 0) }, 4000)
        }
    }

    /** ロックが解除されるまで（最大2分）待ってからマクロを始める。 */
    private fun waitUnlockThenRun(steps: List<Step>, myGen: Int, tries: Int) {
        if (myGen != gen) return
        val km = getSystemService(android.app.KeyguardManager::class.java)
        if (!km.isKeyguardLocked) {
            runSteps(steps, 0, myGen)
            return
        }
        if (tries == 0) Store.log(this, "画面ロック中のため、解除を待ってからマクロを実行します")
        if (tries >= 60) {
            Store.log(this, "ロックが解除されなかったので、マクロは中止しました")
            return
        }
        handler.postDelayed({ waitUnlockThenRun(steps, myGen, tries + 1) }, 2000)
    }

    /** 前面にいたらホームに戻してから、アプリのプロセスを閉じる。 */
    fun stopApp(pkg: String, label: String) {
        gen++ // 動いているマクロがあれば止める
        val am = getSystemService(android.app.ActivityManager::class.java)
        val fg = hasUsageAccess() && Usage.isForeground(this, pkg)
        if (fg) {
            performGlobalAction(GLOBAL_ACTION_HOME)
        } else if (!hasUsageAccess()) {
            Store.log(this, "使用状況アクセスが未許可のため、前面にいる場合は閉じられません")
        }
        handler.postDelayed({
            try {
                am.killBackgroundProcesses(pkg)
                Store.log(this, "「$label」を終了しました")
            } catch (e: Exception) {
                Store.log(this, "「$label」の終了に失敗")
            }
        }, if (fg) 1500L else 0L)
    }

    private fun hasUsageAccess(): Boolean {
        val ops = getSystemService(android.app.AppOpsManager::class.java)
        val mode = ops.checkOpNoThrow(
            "android:get_usage_stats", android.os.Process.myUid(), packageName
        )
        return mode == android.app.AppOpsManager.MODE_ALLOWED
    }

    @Suppress("DEPRECATION")
    private fun wakeScreen() {
        try {
            val pm = getSystemService(PowerManager::class.java)
            val wl = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "timer:launch"
            )
            wl.acquire(20000)
        } catch (_: Exception) {
        }
    }

    private fun launch(pkg: String): Boolean {
        val intent = packageManager.getLaunchIntentForPackage(pkg) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // 見えない1pxのオーバーレイを出して「前面にウィンドウがある」状態にしてから起動する
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val v = View(this)
        var added = false
        try {
            val lp = WindowManager.LayoutParams(
                1, 1,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
                PixelFormat.TRANSLUCENT
            )
            wm.addView(v, lp)
            added = true
        } catch (_: Exception) {
        }
        val ok = try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
        if (added) {
            handler.postDelayed({
                try {
                    wm.removeView(v)
                } catch (_: Exception) {
                }
            }, 3000)
        }
        return ok
    }

    private fun runSteps(steps: List<Step>, i: Int, myGen: Int) {
        if (myGen != gen) return // 新しい実行が始まったので中断
        if (i >= steps.size) {
            Store.log(this, "マクロ完了（${steps.size}手順）")
            return
        }
        val s = steps[i]
        val next: () -> Unit = {
            handler.postDelayed({ runSteps(steps, i + 1, myGen) }, 600L)
        }
        when (s.cmd) {
            "wait" -> handler.postDelayed(
                { runSteps(steps, i + 1, myGen) }, (s.n(0) * 1000).toLong()
            )
            "tap" -> {
                val p = Path()
                p.moveTo(s.n(0), s.n(1))
                gesture(p, 60, next)
            }
            "long" -> {
                val p = Path()
                p.moveTo(s.n(0), s.n(1))
                gesture(p, 800, next)
            }
            "swipe" -> {
                val p = Path()
                p.moveTo(s.n(0), s.n(1))
                p.lineTo(s.n(2), s.n(3))
                val dur = if (s.args.size >= 5) s.n(4).toLong().coerceAtLeast(50) else 400L
                gesture(p, dur, next)
            }
            "back" -> {
                performGlobalAction(GLOBAL_ACTION_BACK)
                next()
            }
            "text" -> {
                val t = s.args.joinToString(" ")
                if (!clickText(t)) Store.log(this, "文字「$t」が見つかりません")
                next()
            }
        }
    }

    private fun gesture(path: Path, dur: Long, done: () -> Unit) {
        val g = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, dur))
            .build()
        val ok = dispatchGesture(g, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                done()
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                done()
            }
        }, null)
        if (!ok) done()
    }

    // ---------------- ティーチング（操作を覚えさせる） ----------------
    private var teachView: View? = null
    private var teachLp: WindowManager.LayoutParams? = null
    private var panelView: View? = null
    private var teachJob: Job? = null
    private val rec = StringBuilder()
    private var recCount = 0
    private var lastEnd = 0L
    private var downX = 0f
    private var downY = 0f
    private var downT = 0L
    private var endBtn: Button? = null

    fun isTeaching(): Boolean = teachView != null || panelView != null

    /**
     * launchApp=true : アプリを起動して、少し待ってから記録を始める
     * launchApp=false: 起動はせず、ホームに戻る。自分でアプリを開いて「記録開始」を押すと始まる
     */
    fun startTeaching(job: Job, launchApp: Boolean = true) {
        if (isTeaching()) return
        gen++ // 動いているマクロがあれば止める
        wakeScreen()
        if (launchApp) {
            if (!launch(job.pkg)) {
                Store.log(this, "「${job.label}」起動に失敗（ティーチング中止）")
                return
            }
            teachJob = job
            rec.setLength(0)
            recCount = 0
            // アプリが立ち上がるのを少し待ってから、記録レイヤーを出す
            handler.postDelayed({ showTeachOverlay() }, 3000)
        } else {
            teachJob = job
            rec.setLength(0)
            recCount = 0
            showReadyPanel()
            performGlobalAction(GLOBAL_ACTION_HOME)
        }
    }

    /** 「記録開始」を押すまでは何も記録しない待機パネル。 */
    private fun showReadyPanel() {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val panel = LinearLayout(this)
        panel.orientation = LinearLayout.HORIZONTAL
        panel.setBackgroundColor(Color.argb(220, 0, 0, 0))
        fun btn(text: String, onClick: () -> Unit) {
            val b = Button(this)
            b.text = text
            b.textSize = 13f
            b.setOnClickListener { onClick() }
            panel.addView(b)
        }
        btn("● 記録開始") {
            try {
                wm.removeView(panel)
            } catch (_: Exception) {
            }
            panelView = null
            showTeachOverlay()
        }
        btn("中止") { stopTeaching(false) }
        val plp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        initPanelPos(plp)
        addHandle(panel, plp)
        wm.addView(panel, plp)
        panelView = panel
        Store.log(this, "ティーチング待機中（アプリを開いて「記録開始」）")
    }

    private fun showTeachOverlay() {
        if (teachJob == null) return
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val v = object : View(this) {
            override fun onTouchEvent(e: MotionEvent): Boolean {
                handleTouch(e)
                return true
            }
        }
        v.setBackgroundColor(Color.argb(40, 255, 0, 0)) // 薄い赤＝記録中
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        wm.addView(v, lp)
        teachView = v
        teachLp = lp

        val panel = LinearLayout(this)
        panel.orientation = LinearLayout.HORIZONTAL
        panel.setBackgroundColor(Color.argb(220, 0, 0, 0))
        fun btn(text: String, onClick: () -> Unit): Button {
            val b = Button(this)
            b.text = text
            b.textSize = 13f
            b.setOnClickListener { onClick() }
            panel.addView(b)
            return b
        }
        btn("戻る") { teachBack() }
        endBtn = btn("終了 0") { stopTeaching(true) }
        btn("中止") { stopTeaching(false) }
        val plp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        initPanelPos(plp)
        addHandle(panel, plp)
        wm.addView(panel, plp)
        panelView = panel
        lastEnd = SystemClock.uptimeMillis()
        Store.log(this, "ティーチング開始")
    }

    private var panelX = -1
    private var panelY = -1

    private fun initPanelPos(lp: WindowManager.LayoutParams) {
        val dm = resources.displayMetrics
        if (panelX < 0) {
            panelX = dm.widthPixels / 5
            panelY = (dm.density * 160).toInt()
        }
        lp.gravity = Gravity.TOP or Gravity.START
        lp.x = panelX
        lp.y = panelY
    }

    /** パネルの左端に「✥」の持ち手を付け、ドラッグで好きな場所へ動かせるようにする。 */
    private fun addHandle(panel: LinearLayout, lp: WindowManager.LayoutParams) {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val h = TextView(this)
        h.text = "✥"
        h.textSize = 24f
        h.setTextColor(Color.WHITE)
        h.setBackgroundColor(Color.parseColor("#555555"))
        h.gravity = Gravity.CENTER
        val pad = (12 * resources.displayMetrics.density).toInt()
        h.setPadding(pad, 0, pad, 0)
        var sx = 0f
        var sy = 0f
        var ox = 0
        var oy = 0
        h.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    sx = e.rawX
                    sy = e.rawY
                    ox = lp.x
                    oy = lp.y
                }
                MotionEvent.ACTION_MOVE -> {
                    lp.x = ox + (e.rawX - sx).toInt()
                    lp.y = oy + (e.rawY - sy).toInt()
                    panelX = lp.x
                    panelY = lp.y
                    try {
                        wm.updateViewLayout(panel, lp)
                    } catch (_: Exception) {
                    }
                }
            }
            true
        }
        panel.addView(h, 0, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.MATCH_PARENT
        ))
    }

    private fun appendWait(nowT: Long) {
        val w = ((nowT - lastEnd) / 1000f).roundToInt()
        if (w >= 1) rec.append("待つ $w\n")
    }

    private fun countUp() {
        recCount++
        endBtn?.text = "終了 $recCount"
    }

    private fun handleTouch(e: MotionEvent) {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.rawX
                downY = e.rawY
                downT = SystemClock.uptimeMillis()
            }
            MotionEvent.ACTION_UP -> {
                val x = e.rawX
                val y = e.rawY
                val now = SystemClock.uptimeMillis()
                val dur = now - downT
                val dist = hypot(x - downX, y - downY)
                appendWait(downT)
                val path = Path()
                path.moveTo(downX, downY)
                val gd: Long
                if (dist < 30f) {
                    if (dur >= 600) {
                        rec.append("長押し ${downX.toInt()} ${downY.toInt()}\n")
                        gd = 800L
                    } else {
                        rec.append("タップ ${downX.toInt()} ${downY.toInt()}\n")
                        gd = 60L
                    }
                } else {
                    path.lineTo(x, y)
                    gd = dur.coerceIn(100L, 2000L)
                    rec.append(
                        "スワイプ ${downX.toInt()} ${downY.toInt()} ${x.toInt()} ${y.toInt()} $gd\n"
                    )
                }
                countUp()
                lastEnd = now
                replayToApp(path, gd)
            }
        }
    }

    /** 記録レイヤーが受け取った操作を、そのまま下のアプリに送り直す。 */
    private fun replayToApp(path: Path, dur: Long) {
        val v = teachView ?: return
        val lp = teachLp ?: return
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        lp.flags = lp.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        try {
            wm.updateViewLayout(v, lp)
        } catch (_: Exception) {
        }
        handler.postDelayed({
            gesture(path, dur) {
                val v2 = teachView
                if (v2 != null) {
                    lp.flags = lp.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
                    try {
                        wm.updateViewLayout(v2, lp)
                    } catch (_: Exception) {
                    }
                }
            }
        }, 50)
    }

    private fun teachBack() {
        appendWait(SystemClock.uptimeMillis())
        rec.append("戻る\n")
        countUp()
        lastEnd = SystemClock.uptimeMillis()
        performGlobalAction(GLOBAL_ACTION_BACK)
    }

    private fun stopTeaching(save: Boolean) {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val job = teachJob
        if (save && job != null && recCount > 0) {
            val list = Store.load(this)
            list.firstOrNull { it.id == job.id }?.macro = rec.toString().trim()
            Store.save(this, list)
            Store.log(this, "「${job.label}」ティーチング完了（${recCount}手順を保存）")
        } else {
            Store.log(this, "ティーチング中止")
        }
        val i = Intent(this, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        try {
            startActivity(i)
        } catch (_: Exception) {
        }
        for (v in listOf(teachView, panelView)) {
            if (v != null) {
                try {
                    wm.removeView(v)
                } catch (_: Exception) {
                }
            }
        }
        teachView = null
        panelView = null
        teachLp = null
        teachJob = null
        endBtn = null
    }

    private fun clickText(t: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val nodes = root.findAccessibilityNodeInfosByText(t) ?: return false
        for (n in nodes) {
            var c: AccessibilityNodeInfo? = n
            while (c != null) {
                if (c.isClickable) return c.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                c = c.parent
            }
        }
        return false
    }
}
