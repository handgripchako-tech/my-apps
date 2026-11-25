package com.chako.launcher

import android.app.Activity
import android.app.Dialog
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.ActivityManager
import android.content.res.ColorStateList
import android.os.BatteryManager
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.graphics.Bitmap
import android.graphics.Canvas
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.SoundPool
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.StateListDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import android.provider.Settings
import android.text.Editable
import android.text.Spanned
import android.text.SpannableString
import android.text.TextUtils
import android.text.TextWatcher
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.util.LruCache
import android.util.TypedValue
import android.view.DragEvent
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.BaseAdapter
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.GridView
import android.widget.ImageView
import android.widget.ListView
import android.widget.TextClock
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject

/**
 * PC98風の軽量ホームアプリ。
 * ・依存ライブラリなし（標準の View だけ）
 * ・文字だけの一覧なので軽い。アイコン読み込みなし
 * ・常駐処理・定期更新なし（時計は TextClock が表示中だけ更新）
 */
class MainActivity : Activity() {

    private class App(val label: String, val pkg: String, val cn: ComponentName)

    // kind: 0=アプリ 1=ディレクトリ 2=.. 3=新規作成 4=隠しアプリ
    private class Row(val kind: Int, val text: String, val app: App? = null, val dir: String? = null)

    private companion object {
        const val HIDDEN = "@hidden"
        const val DIAL = "@dial"
        const val FKEYS = 10
        const val C_WHITE = Color.WHITE
        const val C_CYAN = 0xFF00FFFF.toInt()
        const val C_YELLOW = 0xFFFFFF00.toInt()
        const val C_GREEN = 0xFF00FF00.toInt()
        const val C_BLUE = 0xFF0000FF.toInt()
        const val C_RED = 0xFFFF3030.toInt()
        const val VER = "1.53"
    }

    private var all: List<App> = emptyList()
    private var rows: List<Row> = emptyList()
    private var cur: String? = null // null=ルート

    private lateinit var list: GridView
    private lateinit var search: EditText
    private lateinit var prompt: TextView
    private lateinit var fbar: LinearLayout

    // ドット風フォント（music-app と同じ DotGothic16）。見つからなければ等幅で代用
    private val pc98: Typeface by lazy {
        try {
            Typeface.createFromAsset(assets, "fonts/DotGothic16-Regular.ttf")
        } catch (e: Exception) {
            Typeface.MONOSPACE
        }
    }

    /** DotGothic16 は 16px 格子のフォント。16の整数倍の大きさにするとドットがくっきりする */
    private fun fpx(sp: Float): Float {
        val px = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, resources.displayMetrics)
        return 16f * maxOf(1, Math.round(px / 16f))
    }

    /** ドット風の文字にする（フォント・整数倍サイズ・ギザギザのまま＝アンチエイリアスなし） */
    private fun TextView.dot(sp: Float) {
        typeface = pc98
        setTextSize(TypedValue.COMPLEX_UNIT_PX, fpx(sp))
        paintFlags = paintFlags and Paint.ANTI_ALIAS_FLAG.inv() and Paint.SUBPIXEL_TEXT_FLAG.inv()
    }

    // 押している間は白地に黒文字（反転表示）にするための文字色
    private fun revColors(normal: Int) = ColorStateList(
        arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()),
        intArrayOf(Color.BLACK, normal)
    )

    private val prefs by lazy { getSharedPreferences("launcher", MODE_PRIVATE) }
    private val ui = Handler(Looper.getMainLooper())
    private val reload = Runnable { loadApps() }

    // ---------- ピッ音（PC98の2kHzくらいの矩形波） ----------

    private var pool: SoundPool? = null
    private var beepId = 0
    private var beepReady = false

    private fun beepOn() = prefs.getBoolean("beep", true)

    private var pipoId = 0

    /** 矩形波の短い音（周波数Hz, 長さms の並び）を WAV にして SoundPool に読み込む */
    private fun wavFile(name: String, segs: List<Pair<Int, Int>>): File {
        val rate = 22050
        val out = java.io.ByteArrayOutputStream()
        for ((hz, ms) in segs) {
            val n = rate * ms / 1000
            val period = rate / hz
            for (i in 0 until n) {
                val v = if (i % period < period / 2) 9000 else -9000
                out.write(v and 0xFF)
                out.write((v shr 8) and 0xFF)
            }
        }
        val pcm = out.toByteArray()
        val h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
        h.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        h.putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        h.put("data".toByteArray()).putInt(pcm.size)
        val f = File(cacheDir, name)
        f.outputStream().use {
            it.write(h.array())
            it.write(pcm)
        }
        return f
    }

    private fun initBeep() {
        try {
            val sp = SoundPool.Builder()
                .setMaxStreams(3)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .build()
            sp.setOnLoadCompleteListener { _, _, status -> if (status == 0) beepReady = true }
            beepId = sp.load(wavFile("beep.wav", listOf(2000 to 45)).path, 1)
            // 起動時の「ピポッ」（高い音のあとに低い音）
            pipoId = sp.load(wavFile("pipo.wav", listOf(2000 to 70, 1000 to 110)).path, 1)
            pool = sp
        } catch (e: Exception) {
        }
    }

    private fun pipo() {
        if (!beepOn() || !beepReady) return
        try {
            pool?.play(pipoId, 1f, 1f, 1, 0, 1f)
        } catch (e: Exception) {
        }
    }

    private fun beep() {
        if (!beepOn() || !beepReady) return
        try {
            pool?.play(beepId, 1f, 1f, 1, 0, 1f)
        } catch (e: Exception) {
        }
    }

    /** 本体の「タッチ操作音」が重なって鳴らないよう、この画面の部品は標準のクリック音を消す */
    private fun quiet(v: View) {
        v.isSoundEffectsEnabled = false
        if (v is ViewGroup) for (i in 0 until v.childCount) quiet(v.getChildAt(i))
    }

    // ---------- 起動画面（コールドスタート時だけ、タップで飛ばせる） ----------

    private var bootView: View? = null
    private var bootStep = 0
    private var bootHead = ""
    private val bootRun = object : Runnable {
        override fun run() {
            val ov = bootView as? LinearLayout ?: return
            val tv = ov.getChildAt(0) as TextView
            val s = bootStep++
            var wait = 40L
            when {
                s == 0 -> {
                    bootHead = "CHAKO-98 BIOS  Ver$VER\n"
                    wait = 150
                }
                s == 1 -> {
                    bootHead += "(C) 2026 CHAKO\n\n"
                    wait = 150
                }
                s in 2..11 -> bootHead.let { tv.text = it + "MEMORY CHECK  ${(s - 1) * 64}KB" }
                s == 12 -> {
                    bootHead += "MEMORY CHECK  640KB OK\n\n"
                    tv.text = bootHead
                    pipo()
                    wait = 150
                }
                s == 13 -> {
                    bootHead += "FD  A: ... OK\n"
                    tv.text = bootHead
                    wait = 150
                }
                s == 14 -> {
                    tv.text = bootHead + "Loading HOME.EXE█"
                    wait = 250
                }
                else -> {
                    endBoot()
                    return
                }
            }
            ui.postDelayed(this, wait)
        }
    }

    private fun showBoot() {
        val host = findViewById<ViewGroup>(android.R.id.content)
        val ov = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            setPadding(dp(14), dp(40), dp(14), dp(14))
            isClickable = true
            setOnClickListener { endBoot() }
        }
        ov.addView(TextView(this).apply {
            dot(15f)
            setTextColor(C_WHITE)
            text = ""
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        host.addView(ov, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        bootView = ov
        bootStep = 0
        ui.post(bootRun)
    }

    private fun endBoot() {
        ui.removeCallbacks(bootRun)
        val v = bootView ?: return
        bootView = null
        (v.parent as? ViewGroup)?.removeView(v)
    }

    // ---------- 行の高さ（一覧の空きに合わせて、詰めた高さの1.8倍まで伸ばす） ----------

    private fun iconPx() = 16 * maxOf(1, dp(20) / 16)

    private fun rowH(): Int {
        val base = iconPx() + dp(8)
        val n = (rows.size + 1) / 2
        val avail = if (::list.isInitialized) list.height else 0
        if (n <= 0 || avail <= 0) return base
        return (avail / n).coerceIn(base, (base * 1.8f).toInt())
    }

    // ---------- SYSTEM 窓（電池・メモリ・空き容量・稼働時間） ----------

    private lateinit var sysInfo: TextView
    private val sysRun = object : Runnable {
        override fun run() {
            updateSys()
            updateHoliday()
            ui.postDelayed(this, 30000)
        }
    }

    private fun bar(frac: Float): String {
        val n = Math.round(frac.coerceIn(0f, 1f) * 10)
        return "[" + "#".repeat(n) + "-".repeat(10 - n) + "]"
    }

    private fun gb(b: Long) = String.format("%.1f", b / 1073741824.0)

    private fun updateSys() {
        try {
            val sb = android.text.SpannableStringBuilder()
            fun line(label: String, rest: String, color: Int) {
                val st = sb.length
                sb.append(label)
                sb.setSpan(ForegroundColorSpan(C_CYAN), st, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                val st2 = sb.length
                sb.append(rest).append("\n")
                sb.setSpan(ForegroundColorSpan(color), st2, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            // 電池
            val bi = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val lv = bi?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val sc = bi?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val stt = bi?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val chg = stt == BatteryManager.BATTERY_STATUS_CHARGING || stt == BatteryManager.BATTERY_STATUS_FULL
            if (lv >= 0) {
                val pct = lv * 100 / maxOf(1, sc)
                line("BATT ", "${bar(pct / 100f)} $pct%" + if (chg) " CHG" else "", if (pct <= 20 && !chg) C_YELLOW else C_WHITE)
            }
            // メモリ
            val mi = ActivityManager.MemoryInfo()
            (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(mi)
            line("MEM  ", "${bar(1f - mi.availMem.toFloat() / mi.totalMem)} ${gb(mi.availMem)}G free", C_WHITE)
            // 保存領域
            val sf = StatFs(Environment.getDataDirectory().path)
            line("DISK ", "${bar(1f - sf.availableBytes.toFloat() / sf.totalBytes)} ${gb(sf.availableBytes)}G free", C_WHITE)
            // 起動してからの時間
            val up = SystemClock.elapsedRealtime() / 60000
            line("UP   ", String.format("%dd %02d:%02d", up / 1440, (up / 60) % 24, up % 60), C_WHITE)
            if (sb.isNotEmpty()) sb.delete(sb.length - 1, sb.length)
            sysInfo.text = sb
        } catch (e: Exception) {
        }
    }

    override fun onResume() {
        super.onResume()
        ui.removeCallbacks(sysRun)
        ui.post(sysRun)
    }

    override fun onPause() {
        ui.removeCallbacks(sysRun)
        super.onPause()
    }

    // ---------- タイトル ----------

    private lateinit var titleBar: TextView

    private fun setTitleText() {
        titleBar.text = " CHAKO-98 HOME  Ver$VER  SND:" + if (beepOn()) "ON" else "OFF"
    }

    private val adapter = object : BaseAdapter() {
        override fun getCount() = rows.size
        override fun getItem(position: Int) = rows[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val cell = (convertView as? LinearLayout) ?: makeRowCell()
            cell.minimumHeight = rowH()
            val icon = cell.getChildAt(0) as ImageView
            val tv = cell.getChildAt(1) as TextView
            val r = rows[position]
            // ドラッグ中、指の下にある行（落とせる相手）を青地で光らせる（8色のうちの青）
            if (position == dragOver) cell.setBackgroundColor(C_BLUE) else cell.background = pressBg()
            tv.text = r.text
            val bmp = when (r.kind) {
                0 -> r.app?.let { pixelIcon(it) }
                1, 2 -> folderIcon
                else -> null
            }
            if (bmp != null) {
                icon.setImageDrawable(pixelDrawable(bmp))
                icon.visibility = View.VISIBLE
            } else {
                icon.visibility = View.INVISIBLE // 文字の位置をそろえる
            }
            val base = when (r.kind) {
                1, 2 -> C_YELLOW
                3 -> C_GREEN
                4 -> C_CYAN
                else -> C_WHITE
            }
            tv.setTextColor(revColors(base))
            return cell
        }
    }

    // ---------- ドット絵アイコン（16x16・原色8色） ----------

    private val pal = intArrayOf(
        0xFF000000.toInt(), 0xFF0000FF.toInt(), 0xFFFF0000.toInt(), 0xFFFF00FF.toInt(),
        0xFF00FF00.toInt(), 0xFF00FFFF.toInt(), 0xFFFFFF00.toInt(), 0xFFFFFFFF.toInt()
    )
    private val pixCache = LruCache<String, Bitmap>(200)

    private val folderIcon: Bitmap by lazy {
        val b = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888)
        b.eraseColor(Color.BLACK)
        for (x in 1..6) for (y in 3..4) b.setPixel(x, y, C_YELLOW)
        for (x in 1..14) for (y in 5..13) b.setPixel(x, y, C_YELLOW)
        for (x in 2..13) b.setPixel(x, 7, Color.BLACK) // 蓋の線
        b
    }

    private fun nearest(r: Int, g: Int, b: Int): Int {
        var best = pal[0]
        var bd = Int.MAX_VALUE
        for (c in pal) {
            val dr = r - Color.red(c)
            val dg = g - Color.green(c)
            val db = b - Color.blue(c)
            val d = dr * dr + dg * dg + db * db
            if (d < bd) {
                bd = d
                best = c
            }
        }
        return best
    }

    /** 48x48 に描く。fgOnly=true なら、背景の層を捨てて前景（絵の部分）だけを黒地に描く */
    private fun renderIcon(d: Drawable, fgOnly: Boolean): Bitmap {
        val big = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
        val cv = Canvas(big)
        cv.drawColor(Color.BLACK)
        val fg = if (fgOnly && d is AdaptiveIconDrawable) d.foreground else null
        if (fg != null) {
            // 前景レイヤーは 108dp 中央の 72dp が見える範囲 → 48px に合わせて拡大
            fg.setBounds(-12, -12, 60, 60)
            fg.draw(cv)
        } else {
            d.setBounds(0, 0, 48, 48)
            d.draw(cv)
        }
        return big
    }

    /** 3x3 の平均で 16x16 に縮小（r,g,b を並べた配列） */
    private fun shrink(big: Bitmap): IntArray {
        val avg = IntArray(16 * 16 * 3)
        for (y in 0 until 16) for (x in 0 until 16) {
            var r = 0
            var g = 0
            var b = 0
            for (dy in 0 until 3) for (dx in 0 until 3) {
                val px = big.getPixel(x * 3 + dx, y * 3 + dy)
                r += Color.red(px)
                g += Color.green(px)
                b += Color.blue(px)
            }
            val i = (y * 16 + x) * 3
            avg[i] = r / 9
            avg[i + 1] = g / 9
            avg[i + 2] = b / 9
        }
        big.recycle()
        return avg
    }

    /** アプリのアイコンを 16x16 に縮小して8色に減らす（結果は小さいのでキャッシュ） */
    private fun pixelIcon(app: App): Bitmap? {
        pixCache.get(app.pkg)?.let { return it }
        return try {
            val d = packageManager.getActivityIcon(app.cn)
            // まず背景なし（前景だけ）で作る。暗すぎて何も見えなければ元の絵を使う
            var avg = shrink(renderIcon(d, true))
            if (avg.max() < 90) avg = shrink(renderIcon(d, false))
            val maxV = avg.max()
            // 明るさ補正（弱め）
            val scale = if (maxV in 1..254) 255f / maxV else 1f
            fun lift(v: Int): Int {
                val n = minOf(255f, v * scale) / 255f
                return (255.0 * Math.pow(n.toDouble(), 0.75)).toInt()
            }
            val out = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888)
            for (y in 0 until 16) for (x in 0 until 16) {
                val i = (y * 16 + x) * 3
                out.setPixel(x, y, nearest(lift(avg[i]), lift(avg[i + 1]), lift(avg[i + 2])))
            }
            pixCache.put(app.pkg, out)
            out
        } catch (e: Exception) {
            null
        }
    }

    /** ぼかさずに拡大（ドットをくっきり見せる） */
    private fun pixelDrawable(b: Bitmap) = BitmapDrawable(resources, b).apply {
        paint.isFilterBitmap = false
        paint.isAntiAlias = false
    }

    // 押している間は白地に黒文字（反転表示）
    private fun pressBg() = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), ColorDrawable(Color.WHITE))
        addState(intArrayOf(), ColorDrawable(Color.TRANSPARENT))
    }

    private fun makeRowCell(): LinearLayout {
        val cell = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(6), dp(4), dp(6), dp(4))
            background = pressBg()
            isSoundEffectsEnabled = false
        }
        val px = iconPx() // 整数倍で拡大
        cell.addView(
            ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_XY },
            LinearLayout.LayoutParams(px, px).apply { marginEnd = dp(8) }
        )
        cell.addView(
            TextView(this).apply {
                dot(17f)
                includeFontPadding = false
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        return cell
    }

    private val pkgReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            ui.removeCallbacks(reload)
            ui.postDelayed(reload, 600)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initBeep()
        buildUi()
        if (savedInstanceState == null) showBoot()
        val f = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(pkgReceiver, f, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(pkgReceiver, f)
        }
        loadApps()
    }

    override fun onDestroy() {
        ui.removeCallbacks(reload)
        ui.removeCallbacks(bootRun)
        ui.removeCallbacks(sysRun)
        unregisterReceiver(pkgReceiver)
        pool?.release()
        pool = null
        super.onDestroy()
    }

    // ホームボタンを押されたとき: ルートに戻って検索を消す
    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        resetView()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        when {
            search.text.isNotEmpty() -> search.setText("")
            cur != null -> enter(null)
            else -> resetView()
        }
    }

    private fun resetView() {
        search.requestFocus()
        hideKeyboard()
        if (search.text.isNotEmpty()) search.setText("")
        enter(null)
    }

    private fun hideKeyboard() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(search.windowToken, 0)
    }

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics
    ).toInt()

    // ---------- 画面 ----------

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
        val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        val match = ViewGroup.LayoutParams.MATCH_PARENT

        // 画面枠（二重線）。タイトル・時計・一覧はこの中に入る
        val frame = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val outer = GradientDrawable().apply {
                setColor(Color.BLACK)
                setStroke(dp(1), C_WHITE)
            }
            val inner = GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(dp(1), C_WHITE)
            }
            background = LayerDrawable(arrayOf(outer, inner)).apply {
                setLayerInset(1, dp(4), dp(4), dp(4), dp(4))
            }
            setPadding(dp(9), dp(9), dp(9), dp(6))
        }

        // タイトルバー（白地に黒文字）
        titleBar = TextView(this).apply {
            dot(14f)
            setTextColor(Color.BLACK)
            setBackgroundColor(Color.WHITE)
            setPadding(dp(6), dp(2), dp(6), dp(2))
            // 長押しでピッ音の入/切
            setOnLongClickListener {
                prefs.edit().putBoolean("beep", !beepOn()).apply()
                setTitleText()
                beep()
                true
            }
        }
        setTitleText()
        frame.addView(titleBar, LinearLayout.LayoutParams(match, wrap).apply { bottomMargin = dp(4) })

        // 時計（左に時刻、右に日付と曜日。横並びで背を低くする。TextClock は表示中だけ自動更新される）
        val clockBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(2), dp(8), dp(6))
        }
        clockBox.addView(TextClock(this).apply {
            format24Hour = "HH:mm"
            format12Hour = "HH:mm"
            dot(38f)
            setTextColor(C_CYAN)
        }, LinearLayout.LayoutParams(wrap, wrap))
        val dateCol = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        dateCol.addView(TextClock(this).apply {
            format24Hour = "yyyy/MM/dd"
            format12Hour = "yyyy/MM/dd"
            dot(14f)
            setTextColor(C_WHITE)
        }, LinearLayout.LayoutParams(wrap, wrap))
        val wdRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        wdRow.addView(TextClock(this).apply {
            format24Hour = "EEEE"
            format12Hour = "EEEE"
            dot(14f)
            setTextColor(C_YELLOW)
        }, LinearLayout.LayoutParams(wrap, wrap))
        val hv = TextView(this).apply {
            dot(14f)
            setTextColor(C_RED)
            maxLines = 1
        }
        holidayView = hv
        wdRow.addView(hv, LinearLayout.LayoutParams(wrap, wrap).apply { marginStart = dp(6) })
        dateCol.addView(wdRow, LinearLayout.LayoutParams(wrap, wrap))
        // 日付をタップ → カレンダー（祝日つき）
        dateCol.setOnClickListener {
            beep()
            showCalendar()
        }
        clockBox.addView(dateCol, LinearLayout.LayoutParams(wrap, wrap).apply { marginStart = dp(14) })
        // 時計をタップ → 時計アプリのアラーム画面
        clockBox.setOnClickListener {
            beep()
            openClock()
        }
        clockBox.setOnLongClickListener { pickClockApp(); true } // 開くアプリを自分で指定
        frame.addView(clockBox, LinearLayout.LayoutParams(match, wrap))
        frame.addView(View(this).apply { setBackgroundColor(C_WHITE) }, LinearLayout.LayoutParams(match, dp(1)).apply { bottomMargin = dp(2) })

        // 一覧（2列）
        list = GridView(this).apply {
            numColumns = 2
            stretchMode = GridView.STRETCH_COLUMN_WIDTH
            selector = ColorDrawable(Color.TRANSPARENT)
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            adapter = this@MainActivity.adapter
            setOnItemClickListener { _, _, pos, _ -> onRowClick(rows[pos]) }
            setOnItemLongClickListener { _, v, pos, _ -> startRowDrag(v, pos); true }
            setOnDragListener { _, e -> onGridDrag(e) }
        }
        frame.addView(list, LinearLayout.LayoutParams(match, 0, 1f))
        // 一覧が伸びたときに高さを取り直す
        list.addOnLayoutChangeListener { _, _, t, _, b, _, ot, _, ob ->
            if (b - t != ob - ot) adapter.notifyDataSetChanged()
        }
        frame.addView(View(this).apply { setBackgroundColor(C_WHITE) }, LinearLayout.LayoutParams(match, dp(1)).apply { topMargin = dp(2) })
        frame.addView(TextView(this).apply {
            text = " SYSTEM"
            dot(12f)
            setTextColor(Color.BLACK)
            setBackgroundColor(C_WHITE)
            setPadding(dp(4), 0, dp(4), 0)
        }, LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(6); bottomMargin = dp(4) })
        sysInfo = TextView(this).apply {
            dot(14f)
            setTextColor(C_WHITE)
            setPadding(dp(6), dp(2), dp(6), dp(4))
        }
        frame.addView(sysInfo, LinearLayout.LayoutParams(match, wrap))
        root.addView(frame, LinearLayout.LayoutParams(match, 0, 1f).apply { bottomMargin = dp(4) })

        // コマンド行（入力すると絞り込み）
        val cmd = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(2), dp(8), dp(2))
        }
        prompt = TextView(this).apply {
            dot(17f)
            setTextColor(C_GREEN)
        }
        cmd.addView(prompt, LinearLayout.LayoutParams(wrap, wrap))
        val fw = fpx(17f).toInt()
        search = EditText(this).apply {
            dot(17f)
            setTextColor(C_WHITE)
            background = null
            // 入力中のカーソルも、細い線ではなくブロックにする
            if (Build.VERSION.SDK_INT >= 29) {
                setTextCursorDrawable(GradientDrawable().apply {
                    setColor(C_WHITE)
                    setSize(fw / 2, -1)
                })
            }
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_GO
            setPadding(dp(4), dp(6), dp(4), dp(6))
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) = buildRows()
            })
            hint = " ? で質問" // 先頭の空白ぶんだけ、ブロックカーソルの右から始める
            setHintTextColor(C_CYAN)
            setOnEditorActionListener { _, _, _ ->
                onEnter()
                true
            }
        }
        cmd.addView(search, LinearLayout.LayoutParams(0, wrap, 1f))
        root.addView(cmd, LinearLayout.LayoutParams(match, wrap))

        // Fキー（2段×5）
        fbar = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(fbar, LinearLayout.LayoutParams(match, wrap))

        quiet(root)
        setContentView(root)
    }

    private fun buildFkeys() {
        fbar.removeAllViews()
        for (line in 0..1) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (c in 0..4) {
                val i = line * 5 + c
                val label = fLabel(fkey(i))
                // 番号は白地に黒文字（反転）、押すと全体が反転する
                val cell = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_HORIZONTAL
                    minimumHeight = dp(54)
                    setPadding(dp(2), dp(4), dp(2), dp(3))
                    background = StateListDrawable().apply {
                        addState(
                            intArrayOf(android.R.attr.state_pressed),
                            GradientDrawable().apply {
                                setColor(C_WHITE)
                                setStroke(dp(1), C_WHITE)
                            }
                        )
                        addState(
                            intArrayOf(),
                            GradientDrawable().apply {
                                setColor(Color.BLACK)
                                setStroke(dp(1), C_WHITE)
                            }
                        )
                    }
                    setOnClickListener {
                        beep()
                        runF(i)
                    }
                    setOnLongClickListener { pickForF(i); true }
                }
                val num = TextView(this).apply {
                    text = "F${i + 1}"
                    dot(12f)
                    gravity = Gravity.CENTER
                    setTextColor(
                        ColorStateList(
                            arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()),
                            intArrayOf(C_WHITE, Color.BLACK)
                        )
                    )
                    background = StateListDrawable().apply {
                        addState(intArrayOf(android.R.attr.state_pressed), ColorDrawable(Color.BLACK))
                        addState(intArrayOf(), ColorDrawable(Color.WHITE))
                    }
                    setPadding(dp(4), 0, dp(4), 0)
                }
                val lab = TextView(this).apply {
                    text = label
                    dot(12f)
                    gravity = Gravity.CENTER
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    setTextColor(revColors(C_WHITE))
                }
                cell.addView(num, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                cell.addView(lab, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                quiet(cell)
                row.addView(cell, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
            fbar.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
    }

    // ---------- データ ----------

    private fun loadFolders(): LinkedHashMap<String, MutableList<String>> {
        val m = LinkedHashMap<String, MutableList<String>>()
        try {
            val o = JSONObject(prefs.getString("folders", "{}") ?: "{}")
            for (k in o.keys()) {
                val a = o.getJSONArray(k)
                val l = mutableListOf<String>()
                for (i in 0 until a.length()) l.add(a.getString(i))
                m[k] = l
            }
        } catch (e: Exception) {
        }
        return m
    }

    private fun saveFolders(m: Map<String, List<String>>) {
        val o = JSONObject()
        for ((k, v) in m) o.put(k, JSONArray(v))
        prefs.edit().putString("folders", o.toString()).apply()
    }

    private fun hiddenSet(): MutableSet<String> =
        HashSet(prefs.getStringSet("hidden", emptySet()) ?: emptySet())

    private fun saveHidden(s: Set<String>) {
        prefs.edit().putStringSet("hidden", HashSet(s)).apply()
    }

    private fun fkey(i: Int): String = prefs.getString("f$i", "") ?: ""

    private fun setFkey(i: Int, v: String) {
        prefs.edit().putString("f$i", v).apply()
        buildFkeys()
    }

    private fun fLabel(v: String): String = when {
        v.isEmpty() -> ""
        v == DIAL -> "電話"
        else -> all.firstOrNull { it.pkg == v }?.label ?: "----"
    }

    // ---------- アプリ一覧 ----------

    private fun loadApps() {
        Thread {
            val pm = packageManager
            val q = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val l = pm.queryIntentActivities(q, 0)
                .filter { it.activityInfo.packageName != packageName }
                .map {
                    App(
                        it.loadLabel(pm).toString(),
                        it.activityInfo.packageName,
                        ComponentName(it.activityInfo.packageName, it.activityInfo.name)
                    )
                }
                .distinctBy { it.pkg }
                .sortedBy { it.label.lowercase() }
            runOnUiThread {
                all = l
                pixCache.evictAll()
                buildRows()
                buildFkeys()
            }
        }.start()
    }

    private fun buildRows() {
        val k = search.text.toString().trim()
        val hidden = hiddenSet()
        val folders = loadFolders()
        if (cur != null && cur != HIDDEN && !folders.containsKey(cur!!)) cur = null
        val c = cur
        val inFolder = folders.values.flatten().toSet()
        val out = ArrayList<Row>()

        fun appRow(a: App) = Row(0, a.label, a)

        if (k.isNotEmpty()) {
            all.filter { it.pkg !in hidden && it.label.contains(k, ignoreCase = true) }
                .forEach { out.add(appRow(it)) }
        } else when (c) {
            null -> {
                folders.keys.sorted().forEach { out.add(Row(1, "[$it]", dir = it)) }
                all.filter { it.pkg !in hidden && it.pkg !in inFolder }.forEach { out.add(appRow(it)) }
                out.add(Row(3, "[+] 新規作成"))
                val n = all.count { it.pkg in hidden }
                out.add(Row(4, "[隠] 隠し($n)", dir = HIDDEN))
            }
            HIDDEN -> {
                out.add(Row(2, "[..]"))
                all.filter { it.pkg in hidden }.forEach { out.add(appRow(it)) }
            }
            else -> {
                out.add(Row(2, "[..]"))
                val pk = folders[c] ?: emptyList<String>()
                all.filter { it.pkg in pk && it.pkg !in hidden }.forEach { out.add(appRow(it)) }
            }
        }
        rows = out
        adapter.notifyDataSetChanged()
        val name = when (cur) {
            null -> ""
            HIDDEN -> "HIDDEN"
            else -> cur!!.uppercase()
        }
        prompt.text = "A:\\$name>"
    }

    private fun enter(dir: String?) {
        cur = dir
        if (search.text.isNotEmpty()) search.setText("") else buildRows()
        list.setSelection(0)
    }

    // ---------- 操作 ----------

    private fun onRowClick(r: Row) {
        beep()
        when (r.kind) {
            0 -> r.app?.let { launch(it) }
            1, 4 -> enter(r.dir)
            2 -> enter(null)
            3 -> promptNewDir()
        }
    }

    private fun onRowLong(r: Row) {
        when (r.kind) {
            0 -> r.app?.let { showAppMenu(it) }
            1 -> showDirMenu(r.dir ?: return)
        }
    }

    // ---------- ドラッグでまとめる ----------

    private var dragPos = -1   // 持ち上げた行
    private var dragOver = -1  // 指の下の行（光らせる）
    private var scrollDir = 0  // 画面の端で自動スクロール（-1:上 1:下）
    private val scroller = object : Runnable {
        override fun run() {
            if (scrollDir == 0) return
            list.smoothScrollBy(scrollDir * dp(48), 80)
            ui.postDelayed(this, 80)
        }
    }

    /** 長押し。アプリ/ディレクトリはドラッグ開始、動かさずに離せば今までのメニュー */
    private fun startRowDrag(v: View, pos: Int) {
        val r = rows[pos]
        val canDrag = (r.kind == 0 || r.kind == 1) && search.text.isEmpty() && cur != HIDDEN
        if (!canDrag) {
            onRowLong(r)
            return
        }
        dragPos = pos
        dragOver = -1
        v.startDragAndDrop(ClipData.newPlainText("row", r.text), View.DragShadowBuilder(v), null, 0)
    }

    private fun setOver(p: Int) {
        if (p != dragOver) {
            dragOver = p
            adapter.notifyDataSetChanged()
        }
    }

    private fun onGridDrag(e: DragEvent): Boolean {
        when (e.action) {
            DragEvent.ACTION_DRAG_STARTED -> return dragPos >= 0 // 自分が始めたドラッグだけ受ける
            DragEvent.ACTION_DRAG_LOCATION -> {
                val pos = list.pointToPosition(e.x.toInt(), e.y.toInt())
                setOver(if (pos != dragPos && pos >= 0 && canDropOn(rows[dragPos], rows[pos])) pos else -1)
                val edge = dp(72)
                val dir = when {
                    e.y < edge -> -1
                    e.y > list.height - edge -> 1
                    else -> 0
                }
                if (dir != scrollDir) {
                    scrollDir = dir
                    ui.removeCallbacks(scroller)
                    if (dir != 0) ui.post(scroller)
                }
            }
            DragEvent.ACTION_DROP -> {
                val pos = list.pointToPosition(e.x.toInt(), e.y.toInt())
                val from = dragPos
                endDrag()
                if (from in rows.indices) {
                    if (pos == from) onRowLong(rows[from]) // 動かさず離した → メニュー
                    else if (pos >= 0) dropOn(rows[from], rows[pos])
                }
            }
            DragEvent.ACTION_DRAG_EXITED -> setOver(-1)
            DragEvent.ACTION_DRAG_ENDED -> endDrag()
        }
        return true
    }

    private fun endDrag() {
        scrollDir = 0
        ui.removeCallbacks(scroller)
        dragPos = -1
        setOver(-1)
    }

    /** アプリ→アプリ（フォルダ作成） / アプリ→ディレクトリ（入れる） / アプリ→[..]（外へ出す） */
    private fun canDropOn(from: Row, to: Row): Boolean = from.kind == 0 && (
        (to.kind == 0 && cur == null) || to.kind == 1 || (to.kind == 2 && cur != null)
        )

    private fun dropOn(from: Row, to: Row) {
        if (!canDropOn(from, to)) return
        val fa = from.app ?: return
        when (to.kind) {
            0 -> promptFolderFor(fa, to.app ?: return)
            1 -> moveApp(fa, to.dir)
            2 -> moveApp(fa, null)
        }
    }

    /** アプリを、名前で指定したディレクトリへ（null ならルートへ） */
    private fun moveApp(app: App, dir: String?) {
        val m = loadFolders()
        m.values.forEach { it.remove(app.pkg) }
        if (dir != null) m[dir]?.add(app.pkg)
        saveFolders(m)
        buildRows()
    }

    /** 2つのアプリを重ねた → 新しいディレクトリを作って両方入れる */
    private fun promptFolderFor(a: App, b: App) {
        pcInput("ディレクトリ名（${a.label} + ${b.label}）", "新規", "", "作る") { base ->
            val m = loadFolders()
            if (base.isNotEmpty() && base != ".." && !base.startsWith("@")) {
                var name = base
                var n = 2
                while (m.containsKey(name)) name = base + n++ // 同名があれば番号を付ける
                m.values.forEach { it.remove(a.pkg); it.remove(b.pkg) }
                m[name] = mutableListOf(a.pkg, b.pkg)
                saveFolders(m)
                buildRows()
            }
        }
    }

    /** Enter: 「?」で始まる or 合うアプリがない → Claude に質問 / 合うアプリあり → 先頭を起動 */
    private fun onEnter() {
        val t = search.text.toString().trim()
        if (t.isEmpty()) return
        if (t.startsWith("?") || t.startsWith("？")) {
            ask(t.substring(1).trim())
            return
        }
        val a = rows.firstOrNull { it.kind == 0 }?.app
        if (a != null) launch(a) else ask(t)
    }

    /** Claude アプリ（なければブラウザ）を、質問を入れた状態で新規チャットとして開く */
    private fun ask(q: String) {
        if (q.isEmpty()) return
        // 入力欄に入らなかった場合に備えて、質問をコピーしておく
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("question", q))
        val base = Intent(Intent.ACTION_VIEW, Uri.parse("https://claude.ai/new?q=" + Uri.encode(q)))
        try {
            startActivity(Intent(base).setPackage("com.anthropic.claude"))
        } catch (e: Exception) {
            try {
                startActivity(base)
            } catch (e2: Exception) {
            }
        }
        hideKeyboard()
        search.setText("")
    }

    private fun launch(app: App) {
        try {
            startActivity(
                Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .setComponent(app.cn)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            )
        } catch (e: Exception) {
        }
    }

    /** 時計タップ: 指定アプリ → 標準のアラーム画面 → 「時計」っぽいアプリ → 選択画面 */
    private fun openClock() {
        val saved = prefs.getString("clockapp", "") ?: ""
        if (saved.isNotEmpty()) {
            val a = all.firstOrNull { it.pkg == saved }
            if (a != null) {
                launch(a)
                return
            }
        }
        try {
            startActivity(Intent(AlarmClock.ACTION_SHOW_ALARMS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        } catch (e: Exception) {
        }
        val guess = all.firstOrNull {
            it.label.contains("時計") || it.label.contains("clock", ignoreCase = true) ||
                it.pkg.contains("clock", ignoreCase = true)
        }
        if (guess != null) launch(guess) else {
            Toast.makeText(this, "時計アプリを選んでください", Toast.LENGTH_SHORT).show()
            pickClockApp()
        }
    }

    private fun pickClockApp() {
        val names = ArrayList<String>()
        names.add("(標準に戻す)")
        all.forEach { names.add(it.label) }
        pcMenu("時計で開くアプリ", names) { which ->
            prefs.edit().putString("clockapp", if (which == 0) "" else all[which - 1].pkg).apply()
        }
    }

    // ---------- カレンダー（日本の祝日つき） ----------

    private var holidayView: TextView? = null

    /** 今日が祝日なら、曜日の横に名前を出す */
    private fun updateHoliday() {
        val t = java.time.LocalDate.now()
        val n = Holidays.name(t.year, t.monthValue, t.dayOfMonth)
        holidayView?.text = if (n != null) "($n)" else ""
    }

    private fun showCalendar() {
        val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        val match = ViewGroup.LayoutParams.MATCH_PARENT
        val today = java.time.LocalDate.now()
        var y = today.year
        var m = today.monthValue
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        fun navBtn(t: String) = TextView(this).apply {
            text = t
            dot(20f)
            gravity = Gravity.CENTER
            setTextColor(revColors(C_WHITE))
            background = pressBg()
            isSoundEffectsEnabled = false
        }
        val prevY = navBtn("<<")
        val prev = navBtn("<")
        val next = navBtn(">")
        val nextY = navBtn(">>")
        val title = TextView(this).apply {
            dot(17f)
            gravity = Gravity.CENTER
            setTextColor(C_CYAN)
        }
        val navW = LinearLayout.LayoutParams(0, dp(44), 1f)
        head.addView(prevY, navW)
        head.addView(prev, LinearLayout.LayoutParams(0, dp(44), 1f))
        head.addView(title, LinearLayout.LayoutParams(0, dp(44), 3.2f))
        head.addView(next, LinearLayout.LayoutParams(0, dp(44), 1f))
        head.addView(nextY, LinearLayout.LayoutParams(0, dp(44), 1f))
        body.addView(head, LinearLayout.LayoutParams(match, wrap))
        val grid = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        body.addView(grid, LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(4) })
        val hl = TextView(this).apply {
            dot(14f)
            setTextColor(C_RED)
            setPadding(dp(6), dp(6), dp(6), dp(2))
        }
        body.addView(hl, LinearLayout.LayoutParams(match, wrap))
        val evView = TextView(this).apply {
            dot(14f)
            setTextColor(C_YELLOW)
            setPadding(dp(6), dp(2), dp(6), dp(2))
        }
        body.addView(evView, LinearLayout.LayoutParams(match, wrap))
        val d = pcFrame("CALENDAR", body)

        fun render() {
            title.text = "${y}/" + String.format("%02d", m)
            grid.removeAllViews()
            val wd = arrayOf("日", "月", "火", "水", "木", "金", "土")
            fun cell(t: String, color: Int, inv: Boolean) = TextView(this).apply {
                text = t
                dot(17f)
                gravity = Gravity.CENTER
                setPadding(0, dp(7), 0, dp(7))
                if (inv) {
                    setTextColor(Color.BLACK)
                    setBackgroundColor(C_WHITE)
                } else {
                    setTextColor(color)
                }
            }
            val hr = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (i in 0..6) {
                hr.addView(cell(wd[i], if (i == 0) C_RED else if (i == 6) C_CYAN else C_YELLOW, false),
                    LinearLayout.LayoutParams(0, wrap, 1f))
            }
            grid.addView(hr, LinearLayout.LayoutParams(match, wrap))
            grid.addView(View(this).apply { setBackgroundColor(C_WHITE) }, LinearLayout.LayoutParams(match, dp(1)))
            val first = java.time.LocalDate.of(y, m, 1)
            val lead = first.dayOfWeek.value % 7 // 日曜=0
            val len = first.lengthOfMonth()
            val names = ArrayList<String>()
            val monthEvs = Events.load(this).filter { it.date.year == y && it.date.monthValue == m }
            var day = 1 - lead
            while (day <= len) {
                val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
                for (i in 0..6) {
                    if (day < 1 || day > len) {
                        row.addView(cell("", C_WHITE, false), LinearLayout.LayoutParams(0, wrap, 1f))
                    } else {
                        val h = Holidays.name(y, m, day)
                        if (h != null) names.add("$m/$day $h")
                        val color = when {
                            h != null || i == 0 -> C_RED
                            i == 6 -> C_CYAN
                            else -> C_WHITE
                        }
                        val isToday = y == today.year && m == today.monthValue && day == today.dayOfMonth
                        val c = cell(day.toString(), color, isToday)
                        val dd = day
                        if (monthEvs.any { it.date.dayOfMonth == dd }) { // 予定のある日は下線
                            c.text = android.text.SpannableString(dd.toString()).apply {
                                setSpan(android.text.style.UnderlineSpan(), 0, length, 0)
                            }
                        }
                        c.isSoundEffectsEnabled = false
                        c.setOnClickListener {
                            beep()
                            dayMenu(java.time.LocalDate.of(y, m, dd)) { render() }
                        }
                        row.addView(c, LinearLayout.LayoutParams(0, wrap, 1f))
                    }
                    day++
                }
                grid.addView(row, LinearLayout.LayoutParams(match, wrap))
            }
            hl.text = if (names.isEmpty()) "祝日なし" else names.joinToString("\n")
            evView.text = if (monthEvs.isEmpty()) "予定なし（日付をタップで追加）"
            else monthEvs.joinToString("\n") { "${it.date.monthValue}/${it.date.dayOfMonth} ${it.time} ${it.title}" }
        }
        fun move(dm: Int) {
            val t = java.time.LocalDate.of(y, m, 1).plusMonths(dm.toLong())
            if (t.year < 1980 || t.year > 2099) return
            y = t.year
            m = t.monthValue
            beep()
            render()
        }
        prev.setOnClickListener { move(-1) }
        next.setOnClickListener { move(1) }
        prevY.setOnClickListener { move(-12) }
        nextY.setOnClickListener { move(12) }
        title.setOnClickListener { // タイトルをタップ → 今月に戻る
            y = today.year
            m = today.monthValue
            beep()
            render()
        }
        render()
        d.window?.decorView?.let { quiet(it) }
        d.show()
    }

    /** 日付をタップ → その日の予定一覧と追加 */
    private fun dayMenu(date: java.time.LocalDate, onChanged: () -> Unit) {
        val list = Events.load(this).filter { it.date == date }
        val h = Holidays.name(date.year, date.monthValue, date.dayOfMonth)
        val items = list.map { "${it.time} ${it.title}" } + "＋ 予定を追加"
        pcMenu("${date.monthValue}/${date.dayOfMonth}" + (if (h != null) " $h" else ""), items) { pos ->
            if (pos < list.size) {
                val e = list[pos]
                pcMenu("${e.time} ${e.title}", listOf("削除する", "戻る")) {
                    if (it == 0) {
                        Events.remove(this, e)
                        onChanged()
                    }
                }
            } else {
                addEvent(date, onChanged)
            }
        }
    }

    private fun parseTime(s: String): java.time.LocalTime? {
        val m = Regex("^(\\d{1,2})[:：]?(\\d{2})?$").find(s.trim()) ?: return null
        val hh = m.groupValues[1].toInt()
        val mm = m.groupValues[2].ifEmpty { "0" }.toInt()
        return if (hh in 0..23 && mm in 0..59) java.time.LocalTime.of(hh, mm) else null
    }

    private fun addEvent(date: java.time.LocalDate, onChanged: () -> Unit) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7)
        }
        pcInput("予定 ${date.monthValue}/${date.dayOfMonth}", "", "予定の内容", "次へ") { t ->
            if (t.isEmpty()) return@pcInput
            pcInput("時刻（24時間 例 09:30）", "09:00", "HH:MM", "追加") { s ->
                val tm = parseTime(s)
                if (tm == null) {
                    android.widget.Toast.makeText(this, "時刻が読めません", android.widget.Toast.LENGTH_SHORT).show()
                    return@pcInput
                }
                val ev = Events.Ev(date, tm, t.replace(Regex("[\\t\\n]"), " "))
                Events.add(this, ev)
                onChanged()
                android.widget.Toast.makeText(
                    this,
                    if (ev.at > System.currentTimeMillis()) "${tm} に通知します" else "過去の時刻なので通知されません",
                    android.widget.Toast.LENGTH_SHORT,
                ).show()
            }
        }
    }

    private fun runF(i: Int) {
        val v = fkey(i)
        try {
            when {
                v.isEmpty() -> pickForF(i) // 空のFキーをタップ → 割り当て画面
                v == DIAL -> startActivity(Intent(Intent.ACTION_DIAL))
                else -> all.firstOrNull { it.pkg == v }?.let { launch(it) }
            }
        } catch (e: Exception) {
        }
    }

    /** Fキーに割り当てるものを選ぶ（解除・電話・全アプリ） */
    private fun pickForF(i: Int) {
        val names = ArrayList<String>()
        names.add("(解除)")
        names.add("電話")
        all.forEach { names.add(it.label) }
        pcMenu("F${i + 1} に割り当て", names) { which ->
            when (which) {
                0 -> setFkey(i, "")
                1 -> setFkey(i, DIAL)
                else -> setFkey(i, all[which - 2].pkg)
            }
        }
    }

    private fun showAppMenu(app: App) {
        val isHidden = hiddenSet().contains(app.pkg)
        val items = arrayOf(
            "ディレクトリに移動",
            if (isHidden) "隠すのをやめる" else "隠す",
            "Fキーに割り当て",
            "アプリ情報",
            "アンインストール"
        )
        pcMenu(app.label, items.toList()) { which ->
            when (which) {
                0 -> moveTo(app)
                1 -> {
                    val h = hiddenSet()
                    if (isHidden) h.remove(app.pkg) else h.add(app.pkg)
                    saveHidden(h)
                    buildRows()
                }
                2 -> pickFkeyFor(app)
                3 -> startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${app.pkg}"))
                )
                4 -> startActivity(Intent(Intent.ACTION_DELETE, Uri.parse("package:${app.pkg}")))
            }
        }
    }

    private fun pickFkeyFor(app: App) {
        val names = Array(FKEYS) { i ->
            val l = fLabel(fkey(i))
            if (l.isEmpty()) "F${i + 1}" else "F${i + 1}  ($l)"
        }
        pcMenu("${app.label} を割り当てるFキー", names.toList()) { i -> setFkey(i, app.pkg) }
    }

    private fun moveTo(app: App) {
        val names = ArrayList<String>()
        names.add("(ルートに戻す)")
        names.addAll(loadFolders().keys.sorted())
        pcMenu("移動先", names) { i ->
            val m = loadFolders()
            m.values.forEach { it.remove(app.pkg) }
            if (i > 0) m[names[i]]?.add(app.pkg)
            saveFolders(m)
            buildRows()
        }
    }

    private fun promptNewDir() {
        pcInput("ディレクトリを作る", "", "ディレクトリ名", "作る") { name ->
            val m = loadFolders()
            if (name.isNotEmpty() && name != ".." && !name.startsWith("@") && !m.containsKey(name)) {
                m[name] = mutableListOf()
                saveFolders(m)
                buildRows()
            }
        }
    }

    private fun showDirMenu(name: String) {
        pcMenu(name, listOf("ディレクトリを削除（中のアプリはルートへ）")) {
            val m = loadFolders()
            m.remove(name)
            saveFolders(m)
            buildRows()
        }
    }

    // ---------- PC98風ダイアログ（二重線の枠・白帯のタイトル・反転選択） ----------

    /** 高さに上限をつけた一覧（長い一覧は中でスクロール） */
    private class CapList(c: Context, val maxH: Int) : ListView(c) {
        override fun onMeasure(widthSpec: Int, heightSpec: Int) {
            super.onMeasure(widthSpec, View.MeasureSpec.makeMeasureSpec(maxH, View.MeasureSpec.AT_MOST))
        }
    }

    private fun pcFrame(title: String, body: View): Dialog {
        val d = Dialog(this)
        d.requestWindowFeature(Window.FEATURE_NO_TITLE)
        val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        val match = ViewGroup.LayoutParams.MATCH_PARENT
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val outer = GradientDrawable().apply {
                setColor(Color.BLACK)
                setStroke(dp(1), C_WHITE)
            }
            val inner = GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(dp(1), C_WHITE)
            }
            background = LayerDrawable(arrayOf(outer, inner)).apply {
                setLayerInset(1, dp(3), dp(3), dp(3), dp(3))
            }
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }
        box.addView(TextView(this).apply {
            text = " $title"
            dot(14f)
            setTextColor(Color.BLACK)
            setBackgroundColor(C_WHITE)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(4), dp(2), dp(4), dp(2))
        }, LinearLayout.LayoutParams(match, wrap).apply { bottomMargin = dp(4) })
        box.addView(body, LinearLayout.LayoutParams(match, wrap))
        d.setContentView(box)
        d.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setLayout((resources.displayMetrics.widthPixels * 0.92f).toInt(), wrap)
        }
        return d
    }

    private fun pcMenu(title: String, items: List<String>, onPick: (Int) -> Unit) {
        val lv = CapList(this, (resources.displayMetrics.heightPixels * 0.62f).toInt()).apply {
            divider = null
            selector = ColorDrawable(Color.TRANSPARENT)
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
        }
        val d = pcFrame(title, lv)
        lv.adapter = object : BaseAdapter() {
            override fun getCount() = items.size
            override fun getItem(position: Int) = items[position]
            override fun getItemId(position: Int) = position.toLong()
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val t = (convertView as? TextView) ?: TextView(this@MainActivity).apply {
                    dot(17f)
                    setPadding(dp(8), dp(10), dp(8), dp(10))
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    setTextColor(revColors(C_WHITE))
                    background = pressBg()
                    isSoundEffectsEnabled = false
                }
                t.text = items[position]
                return t
            }
        }
        lv.setOnItemClickListener { _, _, pos, _ ->
            beep()
            d.dismiss()
            onPick(pos)
        }
        d.window?.decorView?.let { quiet(it) }
        d.show()
    }

    private fun pcInput(title: String, initial: String, hintText: String, ok: String, onOk: (String) -> Unit) {
        val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        val match = ViewGroup.LayoutParams.MATCH_PARENT
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val et = EditText(this).apply {
            dot(17f)
            setTextColor(C_WHITE)
            setHintTextColor(C_CYAN)
            background = GradientDrawable().apply {
                setColor(Color.BLACK)
                setStroke(dp(1), C_WHITE)
            }
            isSingleLine = true
            setText(initial)
            hint = hintText
            setSelectAllOnFocus(true)
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }
        col.addView(et, LinearLayout.LayoutParams(match, wrap))
        val d = pcFrame(title, col)
        fun btn(label: String, f: () -> Unit) = TextView(this).apply {
            this.text = "[$label]"
            dot(17f)
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(12), dp(8), dp(12))
            setTextColor(revColors(C_YELLOW))
            background = pressBg()
            setOnClickListener {
                beep()
                f()
            }
        }
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(btn("やめる") { d.dismiss() }, LinearLayout.LayoutParams(0, wrap, 1f))
        row.addView(btn(ok) {
            val t = et.text.toString().trim()
            d.dismiss()
            onOk(t)
        }, LinearLayout.LayoutParams(0, wrap, 1f))
        col.addView(row, LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(6) })
        d.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE)
        d.window?.decorView?.let { quiet(it) }
        d.show()
    }
}
