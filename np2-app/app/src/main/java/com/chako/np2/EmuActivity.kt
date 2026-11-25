package com.chako.np2

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.text.InputType
import android.os.SystemClock
import android.view.inputmethod.BaseInputConnection
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.ListView
import android.widget.TextView
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Toast
import java.io.File
import kotlin.math.abs

/** 4:3 の比率で画面いっぱいに表示する SurfaceView */
class AspectSurfaceView(c: Context) : SurfaceView(c) {
    var aspect = 4f / 3f
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val mw = MeasureSpec.getSize(widthMeasureSpec)
        val mh = MeasureSpec.getSize(heightMeasureSpec)
        var w = mw
        var h = (mw / aspect).toInt()
        if (h > mh) {
            h = mh
            w = (mh * aspect).toInt()
        }
        setMeasuredDimension(w, h)
    }
}

/** エミュレータの画面。別プロセス（:emu）で動く */
class EmuActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var sv: AspectSurfaceView
    private lateinit var keyPanel: LinearLayout
    private lateinit var imeView: View
    private var stateKey = "default"
    private val ui = Handler(Looper.getMainLooper())
    private val ffLevels = intArrayOf(1, 2, 4, 8, 99)
    private var ffIdx = 0
    private var boosting = false
    private var rootView: FrameLayout? = null
    private var launcher: View? = null
    private var bootAt = 0L
    private var firstPath = ""
    private fun ffLabel() = if (ffLevels[ffIdx] >= 99) "最大" else "×${ffLevels[ffIdx]}"
    private var menuOpen = false
    private var quitting = false

    // --- タッチ → マウス ---
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var downTime = 0L
    private var moved = false
    private var twoFinger = false
    private var longPressed = false
    private var remX = 0f
    private var remY = 0f
    private val longPress = Runnable {
        if (!moved && !twoFinger) {
            longPressed = true
            click(1)
        }
    }

    // --- 十字 ---
    private val dir = BooleanArray(4) // 上 下 左 右

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 28) {
            window.attributes = window.attributes.also {
                it.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        immersive()

        val root = FrameLayout(this).apply { setBackgroundColor(0xFF000000.toInt()) }
        sv = AspectSurfaceView(this)
        sv.holder.addCallback(this)
        sv.setOnTouchListener { v, e -> onScreenTouch(v, e) }
        root.addView(sv, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))

        keyPanel = buildKeyPanel()
        keyPanel.visibility = View.GONE
        root.addView(
            keyPanel,
            FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM)
        )

        val toggle = smallButton("⌨") { keyPanel.visibility = if (keyPanel.visibility == View.VISIBLE) View.GONE else View.VISIBLE }
        root.addView(toggle, FrameLayout.LayoutParams(dp(60), dp(50), Gravity.END or Gravity.TOP))
        // 普段のキーボード（Gboard等）を出すための見えない入力窓。キー入力をエミュに流す
        imeView = object : View(this) {
            override fun onCheckIsTextEditor() = true
            override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
                // 普通の文字入力として受ける（フリック・貼り付けが使える）。変換候補は出さない
                // 自動で大文字にしない・全角に変えない・変換候補を出さない（パスワード欄と同じ扱い）
                outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
                return TextBridge(this)
            }
        }.apply { isFocusable = true; isFocusableInTouchMode = true }
        root.addView(imeView, FrameLayout.LayoutParams(1, 1, Gravity.START or Gravity.BOTTOM))
        val ime = smallButton("A") {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imeView.requestFocus()
            imm.restartInput(imeView)
            imm.showSoftInput(imeView, 0)
        }
        root.addView(ime, FrameLayout.LayoutParams(dp(60), dp(50), Gravity.END or Gravity.TOP).also { it.rightMargin = dp(64) })
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        // ⏩: 押すたびに最大早送りの ON/OFF（メニューの早送り設定とは別に、すぐ切り替える用）
        lateinit var boost: Button
        boost = smallButton("⏩") {
            boosting = !boosting
            Native.nFastForward(if (boosting) 99 else ffLevels[ffIdx])
            boost.setBackgroundColor(if (boosting) 0xCC3388CC.toInt() else 0x55000000)
        }
        root.addView(boost, FrameLayout.LayoutParams(dp(60), dp(50), Gravity.END or Gravity.TOP).also { it.rightMargin = dp(128) })
        val menu = smallButton("≡") { showMenu() }
        root.addView(menu, FrameLayout.LayoutParams(dp(60), dp(50), Gravity.START or Gravity.TOP))
        dragRoot = root
        dragButtons["menu"] = menu
        dragButtons["kbd"] = toggle
        dragButtons["ime"] = ime
        dragButtons["boost"] = boost
        for ((k, v) in dragButtons) makeDraggable(v, k)
        addFloatKeys(root)
        root.post { restoreButtonPositions() }

        setContentView(root)
        rootView = root

        val path1 = intent.getStringExtra("path") ?: run { finish(); return }
        // 2台目があるときは `"1台目" "2台目"` の形で渡す（コア側が引用符で分けて読む）
        stateKey = File(path1).name
        firstPath = path1
        var path = path1
        intent.getStringExtra("path2")?.let { path += "\" \"$it" }
        intent.getStringExtra("path3")?.let { path += "\" \"$it" }
        Thread {
            val sys = File(filesDir, "system").also { File(it, "np2kai").mkdirs() }
            val save = File(filesDir, "save").also { it.mkdirs() }
            val core = applicationInfo.nativeLibraryDir + "/libnp2kai_core.so"
            val ok = Native.nInit(core, sys.absolutePath, save.absolutePath) && Native.nLoad(path)
            val pf = getSharedPreferences("np2", Context.MODE_PRIVATE)
            turboDisk = pf.getBoolean("turboDisk", true)
            turboDraw = pf.getBoolean("turboDraw", true)
            applyTurbo(false)
            if (ok) {
                Native.nStart()
                bootAt = SystemClock.uptimeMillis()
                val ar = intent.getStringExtra("autorun")
                ui.post { if (ar != null) runAutorun(ar) else showLauncher() }
            } else {
                ui.post {
                    Toast.makeText(this, "起動に失敗しました", Toast.LENGTH_LONG).show()
                }
            }
        }.start()
    }

    // ---------------- 画面 ----------------
    override fun surfaceCreated(holder: SurfaceHolder) {
        Native.nSetSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Native.nSetSurface(null)
    }

    @Suppress("DEPRECATION")
    private fun immersive() {
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) immersive()
    }

    override fun onPause() {
        super.onPause()
        Native.nPause(true)
    }

    override fun onResume() {
        super.onResume()
        if (!menuOpen) Native.nPause(false)
    }

    override fun onDestroy() {
        super.onDestroy()
        quit()
    }

    private fun quit() {
        if (quitting) return
        quitting = true
        try {
            Native.nStop()
        } catch (_: Throwable) {
        }
        Process.killProcess(Process.myPid())
    }

    // ---------------- メニュー ----------------
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        showMenu()
    }

    // DOS のプロンプトで `copy con autoexec.bat` を打ち、中身を打ち込んで Ctrl+Z で保存する
    private fun askAutoexec() {
        val prefs = getSharedPreferences("np2", Context.MODE_PRIVATE)
        val edit = android.widget.EditText(this).apply {
            setText(prefs.getString("autoexec", "@echo off\n"))
            hint = "例:\n@echo off\ncd \\GAME\ngame"
            setTextColor(0xFF000000.toInt())
            minLines = 6
            gravity = Gravity.TOP
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        }
        val d = AlertDialog.Builder(this)
            .setTitle("autoexec.bat の中身")
            .setMessage("DOS のプロンプト（A> など）の状態で押してください。今いるドライブに作ります（同名があれば上書き）")
            .setView(edit)
            .setPositiveButton("打ち込む") { _, _ ->
                val body = edit.text.toString().replace("\r", "").trimEnd('\n')
                prefs.edit().putString("autoexec", body).apply()
                typeFree = maxOf(typeFree, SystemClock.uptimeMillis() + 700)  // メニューを閉じて再開するのを待つ
                typeAutoexec(body, "autoexec.bat")
            }
            .setNegativeButton("やめる", null)
            .create()
        d.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE)
        d.setOnDismissListener { immersive() }
        d.show()
    }

    // autoexec.bat を DOS の copy con で打ち込んで保存する（Ctrl+Z → Enter）
    private fun typeAutoexec(body: String, target: String) {
        typeText("copy con $target\n$body\n")
        val t = typeFree
        ui.postAtTime({ Native.nKey(306, true); Native.nKey(122, true) }, t)
        ui.postAtTime({ Native.nKey(122, false); Native.nKey(306, false) }, t + 60)
        typeFree = t + 150
        pressKey(13)
    }

    // ステート（途中セーブ）。ディスクごとに3スロット。メニューを開いている間は一時停止中
    private fun stateFile(slot: Int): File {
        val dir = File(filesDir, "states").also { it.mkdirs() }
        return File(dir, "${stateKey}.st$slot")
    }

    private fun askState(save: Boolean) {
        val labels = (1..3).map { n ->
            val f = stateFile(n)
            if (f.exists()) "スロット$n（" + java.text.SimpleDateFormat("M/d HH:mm", java.util.Locale.JAPAN).format(java.util.Date(f.lastModified())) + "）"
            else "スロット$n（空）"
        }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(if (save) "ステートセーブ" else "ステートロード")
            .setItems(labels) { _, i ->
                val f = stateFile(i + 1)
                if (save) {
                    val ok = Native.nSaveState(f.absolutePath)
                    Toast.makeText(this, if (ok) "セーブしました（スロット${i + 1}）" else "セーブに失敗しました", Toast.LENGTH_SHORT).show()
                } else if (!f.exists()) {
                    Toast.makeText(this, "このスロットは空です", Toast.LENGTH_SHORT).show()
                } else {
                    val ok = Native.nLoadState(f.absolutePath)
                    Toast.makeText(this, if (ok) "ロードしました（スロット${i + 1}）" else "ロードに失敗しました", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("やめる", null)
            .setOnDismissListener { immersive() }
            .show()
    }

    private var turboDisk = true
    private var turboDraw = true

    private fun applyTurbo(save: Boolean) {
        val prefs = getSharedPreferences("np2", Context.MODE_PRIVATE)
        if (save) prefs.edit().putBoolean("turboDisk", turboDisk).putBoolean("turboDraw", turboDraw).apply()
        val hooked = Native.nSetTurbo(turboDisk, turboDraw)
        if (save) {
            val msg = "ディスク高速化 ${if (turboDisk) "ON" else "OFF"} / 描画間引き ${if (turboDraw) "ON" else "OFF"}" +
                if (turboDisk && !hooked) "\n（このコアではディスク高速化は使えません）" else ""
            Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        }
    }

    // ゲーム一覧から来たとき：DOS が立ち上がるのを待って、ドライブ移動 → フォルダ移動 → 実行 を打ち込む
    private fun runAutorun(spec: String) {
        val p = spec.split("|")
        if (p.size < 3) return
        val drive = p[0]; val dir = p[1]; val name = p[2]
        val fast = intent.getBooleanExtra("fastboot", false)
        val key = intent.getStringExtra("bootkey") ?: stateKey
        val bootState = File(File(filesDir, "states").also { it.mkdirs() }, "boot_${key}.st")

        var loaded = false
        if (fast && bootState.exists()) {
            // 前に保存した「DOSが立ち上がった状態」から始める
            Native.nPause(true)
            loaded = Native.nLoadState(bootState.absolutePath)
            Native.nPause(false)
            if (loaded) typeFree = maxOf(typeFree, SystemClock.uptimeMillis() + 600)
            else Toast.makeText(this, "保存した起動状態を読めなかったので、通常どおり起動します", Toast.LENGTH_SHORT).show()
        }
        if (!loaded) {
            // DOS が立ち上がるまでは最大早送りで進める。文字を打つ間は等速に戻す（早送りのままだとキーが連打になる）
            val wait = bootAt + (if (intent.getStringExtra("path2") != null) 8000 else 5000)  // フロッピーからの起動は少し長め
            boosting = true
            Native.nFastForward(99)
            ui.postAtTime({
                boosting = false
                Native.nFastForward(ffLevels[ffIdx])
            }, wait)
            typeFree = maxOf(typeFree, wait)
            typeText("\n\n")                   // 日付・時刻の入力待ちがあれば抜ける
            if (fast) {
                // プロンプトが出たところを保存して、次回からはここから始める
                val at = typeFree + 1500
                ui.postAtTime({
                    Native.nPause(true)
                    val ok = Native.nSaveState(bootState.absolutePath)
                    Native.nPause(false)
                    if (ok) Toast.makeText(this, "起動状態を保存しました（次回から速く始まります）", Toast.LENGTH_SHORT).show()
                }, at)
                typeFree = at + 700
            }
        }
        if (drive != "A") typeText(drive.lowercase() + ":\n")
        typeText("cd $dir\n")
        typeText(name + "\n")
        Toast.makeText(this, if (loaded) "$name を実行します…" else "DOSを早送りで起動して $name を実行します…", Toast.LENGTH_SHORT).show()
    }

    // ---------------- ランチャー（ディスクの中身から実行ファイルを選ぶ） ----------------
    private fun showLauncher() {
        if (launcher != null) return
        val root = rootView ?: return
        Thread {
            val d = DiskReader.open(firstPath)
            val vols = d?.volumes() ?: emptyList()
            ui.post {
                if (d == null || vols.isEmpty()) {
                    d?.close()
                    Toast.makeText(this, "このディスクの中身は一覧にできません（DOSで操作してください）", Toast.LENGTH_LONG).show()
                } else {
                    buildLauncher(root, d, vols)
                }
            }
        }.start()
    }

    private fun buildLauncher(root: FrameLayout, disk: DiskReader, vols: List<DiskReader.Volume>) {
        var volIdx = 0
        val names = ArrayList<String>()           // 今いるフォルダの名前（ルートから）
        val clusters = ArrayList<Int>()           // 同じくクラスタ番号
        var showAll = false
        var shown: List<DiskReader.Entry> = emptyList()

        val title = TextView(this).apply { setTextColor(0xFFFFFFFF.toInt()); textSize = 15f; setPadding(dp(8), dp(6), dp(8), dp(6)) }
        val list = ListView(this)
        val labels = ArrayList<String>()
        val adapter = object : ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, labels) {
            override fun getView(position: Int, convertView: View?, parent: android.view.ViewGroup): View {
                val v = super.getView(position, convertView, parent) as TextView
                v.setTextColor(0xFFFFFFFF.toInt()); v.textSize = 16f
                return v
            }
        }
        list.adapter = adapter

        fun isRunnable(n: String): Boolean {
            val e = n.substringAfterLast('.', "").uppercase()
            return e == "EXE" || e == "COM" || e == "BAT"
        }

        fun reload() {
            val fat = vols[volIdx].fat
            val all = fat.list(if (clusters.isEmpty()) 0 else clusters.last())
            shown = all.filter { it.isDir || showAll || isRunnable(it.name) }
                .sortedWith(compareBy({ !it.isDir }, { it.name }))
            labels.clear()
            if (names.isNotEmpty()) labels.add("⬆ 上のフォルダへ")
            for (e in shown) labels.add((if (e.isDir) "📁 " else if (isRunnable(e.name)) "▶ " else "　") + e.name)
            adapter.notifyDataSetChanged()
            val vn = if (vols.size > 1) "[${vols[volIdx].name}] " else ""
            title.text = vn + "\\" + names.joinToString("\\") + "　（長押し＝autoexecにする）"
        }

        fun close() {
            root.removeView(launcher)
            launcher = null
            disk.close()
        }

        fun launchEntry(entryName: String) {
            // DOS が立ち上がる前に打つと取りこぼすので、起動から一定時間は待つ
            val wait = bootAt + 9000
            val now = SystemClock.uptimeMillis()
            if (wait > now) Toast.makeText(this, "DOSの起動を待ってから実行します…", Toast.LENGTH_SHORT).show()
            typeFree = maxOf(typeFree, wait)
            typeText("cd \\" + names.joinToString("\\") + "\n")
            typeText(entryName + "\n")
            close()
        }

        list.setOnItemClickListener { _, _, pos, _ ->
            var p = pos
            if (names.isNotEmpty()) {
                if (p == 0) {
                    names.removeAt(names.size - 1); clusters.removeAt(clusters.size - 1)
                    reload(); return@setOnItemClickListener
                }
                p -= 1
            }
            val e = shown[p]
            if (e.isDir) {
                names.add(e.name); clusters.add(e.cluster); reload()
            } else {
                launchEntry(e.name)
            }
        }

        // 長押し：そのファイルを起動する autoexec.bat を作る（ルートに上書き）
        list.setOnItemLongClickListener { _, _, pos, _ ->
            var p = pos
            if (names.isNotEmpty()) { if (p == 0) return@setOnItemLongClickListener true; p -= 1 }
            val e = shown[p]
            if (e.isDir || !isRunnable(e.name)) {
                Toast.makeText(this, "実行ファイル（EXE/COM/BAT）を長押ししてください", Toast.LENGTH_SHORT).show()
                return@setOnItemLongClickListener true
            }
            val dirPath = "\\" + names.joinToString("\\")
            val body = "@echo off\ncd $dirPath\n" + e.name
            AlertDialog.Builder(this)
                .setTitle("autoexec.bat にする")
                .setMessage("次の内容で、ディスクのルートの autoexec.bat を作ります（同名があれば上書き）。次回の起動から自動で実行されます。\n\n$body")
                .setPositiveButton("作る") { _, _ ->
                    val wait = bootAt + 9000
                    typeFree = maxOf(typeFree, wait, SystemClock.uptimeMillis() + 700)
                    typeText("cd \\\n")
                    typeAutoexec(body, "autoexec.bat")
                    Toast.makeText(this, "autoexec.bat を作ります", Toast.LENGTH_SHORT).show()
                    close()
                }
                .setNegativeButton("やめる", null)
                .setOnDismissListener { immersive() }
                .show()
            true
        }

        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun barBtn(t: String, f: () -> Unit) = Button(this).apply {
            text = t; textSize = 13f; isAllCaps = false; setOnClickListener { f() }
        }
        if (vols.size > 1) {
            bar.addView(barBtn("ドライブ切替") {
                volIdx = (volIdx + 1) % vols.size; names.clear(); clusters.clear(); reload()
            })
        }
        bar.addView(barBtn("全ファイル表示") { showAll = !showAll; reload() })
        bar.addView(barBtn("閉じる（DOSで操作）") { close() })

        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xEE1A1F33.toInt())
            isClickable = true
            addView(title)
            addView(list, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(bar)
        }
        launcher = panel
        root.addView(panel, FrameLayout.LayoutParams(-1, -1).also {
            it.setMargins(dp(60), dp(8), dp(60), dp(8))
        })
        reload()
        // ボタン類より前に出す（メニュー等を押せるように）
        for (v in dragButtons.values) v.bringToFront()
        for (v in floatButtons.values) v.bringToFront()
    }

    // フロッピーの入れ替え（複数枚組のインストールなど）。B: に、登録済みのフロッピーを差し替える
    private fun askSwapFdd() {
        val dir = File(filesDir, "disks")
        val exts = listOf("fdi", "d88", "88d", "d98", "98d", "fdd", "xdf", "dup", "hdm", "tfd", "nfd", "img", "flp")
        val fds = (dir.listFiles() ?: emptyArray())
            .filter { it.extension.lowercase() in exts }
            .sortedBy { it.name.lowercase() }
        if (fds.isEmpty()) {
            Toast.makeText(this, "入れ替えできるフロッピーが登録されていません", Toast.LENGTH_LONG).show()
            return
        }
        val labels = (listOf("（取り出す）") + fds.map { it.name }).toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("B: に入れるフロッピー")
            .setItems(labels) { _, i ->
                val ok = Native.nSetFdd(1, if (i == 0) "" else fds[i - 1].absolutePath)
                Toast.makeText(this, if (!ok) "入れ替えに失敗しました" else if (i == 0) "B: を取り出しました" else "B: に ${fds[i - 1].name} を入れました", Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton("やめる", null)
            .setOnDismissListener { immersive() }
            .show()
    }

    // 起動中の HDD のシステムを、移し先ドライブへコピー（DOS の `sys x:` を打ち込む）
    private fun askSys() {
        val prefs = getSharedPreferences("np2", Context.MODE_PRIVATE)
        val letters = ('A'..'F').toList()
        val last = prefs.getString("sysdrive", "B")!!
        val labels = letters.map { "$it:" + if (it.toString() == last) "（前回）" else "" }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("システムの移し先ドライブ（DOSのプロンプトで／先に dir x: で確認）")
            .setItems(labels) { _, i ->
                val d = letters[i].toString()
                prefs.edit().putString("sysdrive", d).apply()
                typeFree = maxOf(typeFree, SystemClock.uptimeMillis() + 700)
                typeText("sys ${d.lowercase()}:\n")
            }
            .setNegativeButton("やめる", null)
            .setOnDismissListener { immersive() }
            .show()
    }

    private fun showMenu() {
        if (menuOpen) return
        menuOpen = true
        Native.nPause(true)
        val items = arrayOf(
            "再開",
            "リセット",
            "早送り: ${ffLabel()}（タップで切り替え）",
            "autoexec.bat を作る（DOSに打ち込む）",
            "ステートセーブ",
            "ステートロード",
            "ディスクアクセス高速化: ${if (turboDisk) "ON" else "OFF"}",
            "描画を軽く（間引き）: ${if (turboDraw) "ON" else "OFF"}",
            "ランチャー（実行ファイルを選ぶ）",
            "システムを2台目へコピー（sys）",
            "ボタンの位置を元に戻す",
            "フロッピーを入れ替える（B:）",
            "終了"
        )
        AlertDialog.Builder(this)
            .setTitle("メニュー")
            .setItems(items) { _, which ->
                when (which) {
                    1 -> Native.nReset()
                    2 -> {
                        ffIdx = (ffIdx + 1) % ffLevels.size
                        if (!boosting) Native.nFastForward(ffLevels[ffIdx])
                        Toast.makeText(this, "早送り ${ffLabel()}", Toast.LENGTH_SHORT).show()
                    }
                    3 -> askAutoexec()
                    4 -> askState(true)
                    5 -> askState(false)
                    6 -> { turboDisk = !turboDisk; applyTurbo(true) }
                    7 -> { turboDraw = !turboDraw; applyTurbo(true) }
                    8 -> showLauncher()
                    9 -> askSys()
                    10 -> resetButtonPositions()
                    11 -> askSwapFdd()
                    12 -> {
                        finish()
                    }
                }
            }
            .setOnDismissListener {
                menuOpen = false
                Native.nPause(false)
                immersive()
            }
            .show()
    }

    // ---------------- 画面上のボタン ----------------
    // ボタンをドラッグで好きな位置へ。位置は画面サイズに対する割合で保存
    private var dragRoot: FrameLayout? = null
    private val dragButtons = linkedMapOf<String, View>()

    private fun restoreButtonPositions() {
        val r = dragRoot ?: return
        if (r.width == 0 || r.height == 0) { r.post { restoreButtonPositions() }; return }
        val pf = getSharedPreferences("np2", Context.MODE_PRIVATE)
        for ((k, v) in dragButtons) {
            if (!pf.contains("btn_${k}_x")) continue
            v.x = (pf.getFloat("btn_${k}_x", 0f) * r.width).coerceIn(0f, (r.width - v.width).toFloat().coerceAtLeast(0f))
            v.y = (pf.getFloat("btn_${k}_y", 0f) * r.height).coerceIn(0f, (r.height - v.height).toFloat().coerceAtLeast(0f))
        }
        for ((k, v) in floatButtons) {
            if (pf.contains("btn_${k}_x")) {
                v.x = (pf.getFloat("btn_${k}_x", 0f) * r.width).coerceIn(0f, (r.width - v.width).toFloat().coerceAtLeast(0f))
                v.y = (pf.getFloat("btn_${k}_y", 0f) * r.height).coerceIn(0f, (r.height - v.height).toFloat().coerceAtLeast(0f))
            } else {
                val d = floatDefaults[k] ?: continue
                v.x = d.first(r.width, r.height)
                v.y = d.second(r.width, r.height)
            }
        }
    }

    private fun resetButtonPositions() {
        val pf = getSharedPreferences("np2", Context.MODE_PRIVATE).edit()
        for (k in dragButtons.keys) pf.remove("btn_${k}_x").remove("btn_${k}_y")
        for (k in floatButtons.keys) pf.remove("btn_${k}_x").remove("btn_${k}_y")
        pf.apply()
        for (v in dragButtons.values) { v.translationX = 0f; v.translationY = 0f }
        restoreButtonPositions()
    }

    private fun makeDraggable(v: View, key: String) {
        var downX = 0f; var downY = 0f; var startX = 0f; var startY = 0f
        var dragging = false
        val slop = dp(8).toFloat()
        v.setOnTouchListener { view, e ->
            val r = dragRoot ?: return@setOnTouchListener false
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY; startX = view.x; startY = view.y
                    dragging = false
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX; val dy = e.rawY - downY
                    if (!dragging && (kotlin.math.abs(dx) > slop || kotlin.math.abs(dy) > slop)) {
                        dragging = true
                        view.isPressed = false
                        view.parent.requestDisallowInterceptTouchEvent(true)
                    }
                    if (dragging) {
                        view.x = (startX + dx).coerceIn(0f, (r.width - view.width).toFloat().coerceAtLeast(0f))
                        view.y = (startY + dy).coerceIn(0f, (r.height - view.height).toFloat().coerceAtLeast(0f))
                    }
                    dragging
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragging) {
                        getSharedPreferences("np2", Context.MODE_PRIVATE).edit()
                            .putFloat("btn_${key}_x", view.x / r.width)
                            .putFloat("btn_${key}_y", view.y / r.height).apply()
                        dragging = false
                        true
                    } else false
                }
                else -> false
            }
        }
    }

    // ---------------- 画面の左右に置くキー（十字・Enter・Space・Esc・STOP・セーブ/ロード） ----------------
    // ドラッグで好きな位置へ動かせる（位置は他のボタンと同じく保存）。キーは押している間だけ押した扱い
    private val floatButtons = linkedMapOf<String, Button>()
    private val floatDefaults = HashMap<String, Pair<(Int, Int) -> Float, (Int, Int) -> Float>>()
    // 同じグループのキーは、1つをドラッグすると全部いっしょに動く（十字キー用）
    private val floatGroups = HashMap<String, ArrayList<String>>()

    private fun addFloatKeys(root: FrameLayout) {
        val u = dp(54).toFloat()
        val gap = dp(2).toFloat()
        val edge = dp(6).toFloat()
        val bw = dp(72).toFloat()
        // 左：十字
        val rowTop = { _: Int, h: Int -> h / 2f - 1.5f * u - gap }
        val rowMid = { _: Int, h: Int -> h / 2f - 0.5f * u }
        val rowBot = { _: Int, h: Int -> h / 2f + 0.5f * u + gap }
        val c0 = { _: Int, _: Int -> edge }
        val c1 = { _: Int, _: Int -> edge + u + gap }
        val c2 = { _: Int, _: Int -> edge + 2 * (u + gap) }
        floatKey(root, "f_up", "▲", u.toInt(), u.toInt(), 273, null, c1, rowTop, "dpad")
        floatKey(root, "f_left", "◀", u.toInt(), u.toInt(), 276, null, c0, rowMid, "dpad")
        floatKey(root, "f_right", "▶", u.toInt(), u.toInt(), 275, null, c2, rowMid, "dpad")
        floatKey(root, "f_down", "▼", u.toInt(), u.toInt(), 274, null, c1, rowBot, "dpad")
        // 右：2列×3行
        val colB = { w: Int, _: Int -> w - edge - bw }
        val colA = { w: Int, _: Int -> w - edge - 2 * bw - gap }
        val r1 = { _: Int, h: Int -> h / 2f - 1.5f * u - gap }
        val r2 = { _: Int, h: Int -> h / 2f - 0.5f * u }
        val r3 = { _: Int, h: Int -> h / 2f + 0.5f * u + gap }
        floatKey(root, "f_enter", "Enter", bw.toInt(), u.toInt(), 13, null, colA, r1)
        floatKey(root, "f_space", "Space", bw.toInt(), u.toInt(), 32, null, colB, r1)
        floatKey(root, "f_esc", "Esc", bw.toInt(), u.toInt(), 27, null, colA, r2)
        floatKey(root, "f_stop", "STOP", bw.toInt(), u.toInt(), 19, null, colB, r2)
        floatKey(root, "f_save", "保存", bw.toInt(), u.toInt(), -1, { quickState(true) }, colA, r3)
        floatKey(root, "f_load", "読込", bw.toInt(), u.toInt(), -1, { quickState(false) }, colB, r3)
    }

    private fun floatKey(
        root: FrameLayout, key: String, label: String, w: Int, h: Int, code: Int, action: (() -> Unit)?,
        fx: (Int, Int) -> Float, fy: (Int, Int) -> Float, group: String? = null
    ) {
        val b = Button(this).apply {
            text = label
            textSize = 17f
            isAllCaps = false
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(if (action != null) 0x66336688 else 0x66224466)
            minWidth = 0
            minHeight = 0
            setPadding(0, 0, 0, 0)
        }
        var downX = 0f; var downY = 0f
        var dragging = false
        var pressed = false
        val slop = dp(10).toFloat()
        // ドラッグ対象（グループなら全員）の開始位置
        var targets: List<Button> = listOf(b)
        var starts: List<Pair<Float, Float>> = emptyList()
        b.setOnTouchListener { view, e ->
            val r = dragRoot ?: return@setOnTouchListener false
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY
                    targets = (if (group != null) floatGroups[group]?.mapNotNull { floatButtons[it] } else null) ?: listOf(b)
                    starts = targets.map { Pair(it.x, it.y) }
                    dragging = false
                    view.isPressed = true
                    if (code >= 0) { pressed = true; Native.nKey(code, true) }
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX; val dy = e.rawY - downY
                    if (!dragging && (kotlin.math.abs(dx) > slop || kotlin.math.abs(dy) > slop)) {
                        dragging = true
                        view.isPressed = false
                        if (pressed) { pressed = false; Native.nKey(code, false) }   // 動かし始めたらキーは離す
                    }
                    if (dragging) {
                        // グループ全体が画面からはみ出さない範囲に収める
                        val minX = starts.minOf { it.first }
                        val maxX = targets.indices.maxOf { starts[it].first + targets[it].width }
                        val minY = starts.minOf { it.second }
                        val maxY = targets.indices.maxOf { starts[it].second + targets[it].height }
                        val ddx = dx.coerceIn(-minX, (r.width - maxX).coerceAtLeast(-minX))
                        val ddy = dy.coerceIn(-minY, (r.height - maxY).coerceAtLeast(-minY))
                        for (i in targets.indices) {
                            targets[i].x = starts[i].first + ddx
                            targets[i].y = starts[i].second + ddy
                        }
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    view.isPressed = false
                    if (pressed) { pressed = false; Native.nKey(code, false) }
                    if (dragging) {
                        val ed = getSharedPreferences("np2", Context.MODE_PRIVATE).edit()
                        for ((k2, v2) in floatButtons) {
                            if (targets.contains(v2)) ed.putFloat("btn_${k2}_x", v2.x / r.width).putFloat("btn_${k2}_y", v2.y / r.height)
                        }
                        ed.apply()
                        dragging = false
                    } else if (e.actionMasked == MotionEvent.ACTION_UP && action != null) {
                        action()
                    }
                }
            }
            true
        }
        floatButtons[key] = b
        floatDefaults[key] = Pair(fx, fy)
        if (group != null) floatGroups.getOrPut(group) { ArrayList() }.add(key)
        root.addView(b, FrameLayout.LayoutParams(w, h, Gravity.START or Gravity.TOP))
    }

    // 画面のボタンからのステート保存/読込（スロット1）
    private fun quickState(save: Boolean) {
        val f = stateFile(1)
        if (save) {
            val ok = Native.nSaveState(f.absolutePath)
            Toast.makeText(this, if (ok) "セーブしました（スロット1）" else "セーブに失敗しました", Toast.LENGTH_SHORT).show()
        } else if (!f.exists()) {
            Toast.makeText(this, "スロット1は空です", Toast.LENGTH_SHORT).show()
        } else {
            val ok = Native.nLoadState(f.absolutePath)
            Toast.makeText(this, if (ok) "ロードしました（スロット1）" else "ロードに失敗しました", Toast.LENGTH_SHORT).show()
        }
    }

    private fun smallButton(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 20f
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0x55000000)
            minWidth = 0
            minHeight = 0
            setPadding(0, 0, 0, 0)
            setOnClickListener { onClick() }
        }

    // Shift / Ctrl は「1回だけ押したことにする」ラッチ式。次に普通のキーを離したら自動で解除
    private val latched = mutableMapOf<Int, Button>()
    private val latchOn = mutableSetOf<Int>()

    private fun setLatch(code: Int, on: Boolean) {
        if (on) latchOn.add(code) else latchOn.remove(code)
        Native.nKey(code, on)
        latched[code]?.setBackgroundColor(if (on) 0xCC3388CC.toInt() else 0x99224466.toInt())
    }

    private fun releaseLatches() {
        for (c in latchOn.toList()) setLatch(c, false)
    }

    private fun keyBtn(label: String, code: Int, latch: Boolean = false): Button =
        Button(this).apply {
            text = label
            textSize = 13f
            isAllCaps = false
            setTextColor(0xFFFFFFFF.toInt())
            setBackgroundColor(0x99224466.toInt())
            minWidth = 0
            minHeight = 0
            setPadding(0, 0, 0, 0)
            if (latch) {
                latched[code] = this
                setOnTouchListener { _, e ->
                    if (e.actionMasked == MotionEvent.ACTION_DOWN) setLatch(code, code !in latchOn)
                    true
                }
            } else {
                setOnTouchListener { v, e ->
                    when (e.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            v.isPressed = true
                            Native.nKey(code, true)
                        }
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                            v.isPressed = false
                            Native.nKey(code, false)
                            releaseLatches()
                        }
                    }
                    true
                }
            }
        }

    // 横幅いっぱいに均等割りの1行。weight が大きいキーは幅広
    private fun row(vararg b: Pair<Button, Float>): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            for ((x, w) in b) addView(x, LinearLayout.LayoutParams(0, dp(34), w).also { it.setMargins(dp(1), dp(1), dp(1), dp(1)) })
        }

    private fun k(label: String, code: Int, w: Float = 1f) = keyBtn(label, code) to w
    private fun kc(c: Char) = k(c.toString(), c.code)

    private fun buildKeyPanel(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0x99000000.toInt())
            setPadding(dp(2), dp(2), dp(2), dp(2))
            addView(row(
                k("Esc", 27, 1.5f),
                *("1234567890-".map { kc(it) }.toTypedArray()),
                k("^", 61), k("\\", 92), k("BS", 8, 1.5f)
            ))
            addView(row(
                k("Tab", 9, 1.5f),
                *("qwertyuiop".map { kc(it) }.toTypedArray()),
                k("@", 64), k("[", 91), k("Del", 127, 1.5f)
            ))
            addView(row(
                keyBtn("Ctrl", 306, latch = true) to 1.8f,
                *("asdfghjkl".map { kc(it) }.toTypedArray()),
                k(";", 59), k(":", 39), k("]", 93), k("Enter", 13, 2f)
            ))
            addView(row(
                keyBtn("Shift", 304, latch = true) to 2.2f,
                *("zxcvbnm".map { kc(it) }.toTypedArray()),
                k(",", 44), k(".", 46), k("/", 47), k("_", 2),
                k("▲", 273, 1.5f)
            ))
            addView(row(
                k("F1", 282), k("F2", 283), k("F3", 284), k("F4", 285), k("F5", 286),
                k("Space", 32, 5f),
                k("◀", 276, 1.5f), k("▼", 274, 1.5f), k("▶", 275, 1.5f)
            ))
        }

    // ---------------- タッチ → マウス ----------------
    private fun click(btn: Int) {
        Native.nMouseBtn(btn, true)
        ui.postDelayed({ Native.nMouseBtn(btn, false) }, 60)
    }

    private fun onScreenTouch(v: View, e: MotionEvent): Boolean {
        val scale = 640f / v.width.coerceAtLeast(1) * 1.6f
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.getX(0); downY = e.getY(0)
                lastX = downX; lastY = downY
                downTime = e.eventTime
                moved = false; twoFinger = false; longPressed = false
                remX = 0f; remY = 0f
                ui.postDelayed(longPress, 500)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                ui.removeCallbacks(longPress)
                twoFinger = true
                click(1)
            }
            MotionEvent.ACTION_MOVE -> {
                val x = e.getX(0)
                val y = e.getY(0)
                if (abs(x - downX) > dp(10) || abs(y - downY) > dp(10)) {
                    moved = true
                    ui.removeCallbacks(longPress)
                }
                remX += (x - lastX) * scale
                remY += (y - lastY) * scale
                lastX = x; lastY = y
                val ix = remX.toInt()
                val iy = remY.toInt()
                if (ix != 0 || iy != 0) {
                    Native.nMouseMove(ix, iy)
                    remX -= ix; remY -= iy
                }
            }
            MotionEvent.ACTION_UP -> {
                ui.removeCallbacks(longPress)
                if (!moved && !twoFinger && !longPressed && e.eventTime - downTime < 300) click(0)
            }
            MotionEvent.ACTION_CANCEL -> ui.removeCallbacks(longPress)
        }
        return true
    }

    // ---------------- コントローラ・キーボード ----------------
    private val padMap = mapOf(
        KeyEvent.KEYCODE_DPAD_UP to 4,
        KeyEvent.KEYCODE_DPAD_DOWN to 5,
        KeyEvent.KEYCODE_DPAD_LEFT to 6,
        KeyEvent.KEYCODE_DPAD_RIGHT to 7,
        KeyEvent.KEYCODE_BUTTON_A to 0,   // 下ボタン → libretro の B
        KeyEvent.KEYCODE_BUTTON_B to 8,   // 右ボタン → libretro の A
        KeyEvent.KEYCODE_BUTTON_X to 1,
        KeyEvent.KEYCODE_BUTTON_Y to 9,
        KeyEvent.KEYCODE_BUTTON_L1 to 10,
        KeyEvent.KEYCODE_BUTTON_R1 to 11,
        KeyEvent.KEYCODE_BUTTON_L2 to 12,
        KeyEvent.KEYCODE_BUTTON_R2 to 13,
        KeyEvent.KEYCODE_BUTTON_THUMBL to 14,
        KeyEvent.KEYCODE_BUTTON_THUMBR to 15,
        KeyEvent.KEYCODE_BUTTON_SELECT to 2,
        KeyEvent.KEYCODE_BUTTON_START to 3
    )

    private fun retroKey(kc: Int): Int = when (kc) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> 'a'.code + (kc - KeyEvent.KEYCODE_A)
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> '0'.code + (kc - KeyEvent.KEYCODE_0)
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> 13
        KeyEvent.KEYCODE_ESCAPE -> 27
        KeyEvent.KEYCODE_SPACE -> 32
        KeyEvent.KEYCODE_DEL -> 8
        KeyEvent.KEYCODE_TAB -> 9
        KeyEvent.KEYCODE_DPAD_UP -> 273
        KeyEvent.KEYCODE_DPAD_DOWN -> 274
        KeyEvent.KEYCODE_DPAD_RIGHT -> 275
        KeyEvent.KEYCODE_DPAD_LEFT -> 276
        KeyEvent.KEYCODE_COMMA -> 44
        KeyEvent.KEYCODE_MINUS -> 45
        KeyEvent.KEYCODE_PERIOD -> 46
        KeyEvent.KEYCODE_SLASH -> 47
        KeyEvent.KEYCODE_SEMICOLON -> 59
        KeyEvent.KEYCODE_EQUALS -> 61
        KeyEvent.KEYCODE_LEFT_BRACKET -> 91
        KeyEvent.KEYCODE_BACKSLASH -> 92
        KeyEvent.KEYCODE_RIGHT_BRACKET -> 93
        KeyEvent.KEYCODE_APOSTROPHE -> 39
        KeyEvent.KEYCODE_GRAVE -> 96
        KeyEvent.KEYCODE_AT -> 64
        KeyEvent.KEYCODE_FORWARD_DEL -> 127
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 303
        KeyEvent.KEYCODE_SHIFT_LEFT -> 304
        KeyEvent.KEYCODE_CTRL_RIGHT -> 305
        KeyEvent.KEYCODE_CTRL_LEFT -> 306
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> 282 + (kc - KeyEvent.KEYCODE_F1)
        else -> -1
    }

    private fun isPad(src: Int) =
        (src and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD ||
                (src and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK ||
                (src and InputDevice.SOURCE_DPAD) == InputDevice.SOURCE_DPAD

    // 入力された文字（フリック・貼り付け）を PC-98 のキー操作に変換して順番に打つ
    private var typeFree = 0L

    // 全角の記号・英数（日本語キーボードの「：」「￥」など）は半角にそろえてから変換する
    private fun keyFor(c0: Char): Pair<Int, Boolean>? {
        val c = when {
            c0 in '\uFF01'..'\uFF5E' -> (c0.code - 0xFEE0).toChar()
            c0 == '\uFFE5' -> '\\'
            else -> c0
        }
        return keyForAscii(c)
    }

    private fun keyForAscii(c: Char): Pair<Int, Boolean>? = when (c) {
        in 'a'..'z' -> c.code to false
        in 'A'..'Z' -> c.lowercaseChar().code to true
        in '0'..'9' -> c.code to false
        '!' -> 49 to true; '"' -> 50 to true; '#' -> 51 to true; '$' -> 52 to true
        '%' -> 53 to true; '&' -> 54 to true; '\'' -> 55 to true; '(' -> 56 to true; ')' -> 57 to true
        '-' -> 45 to false; '=' -> 45 to true
        '^' -> 61 to false; '~' -> 61 to true
        '@' -> 64 to false; '`' -> 64 to true
        '[' -> 91 to false; '{' -> 91 to true
        ']' -> 93 to false; '}' -> 93 to true
        ';' -> 59 to false; '+' -> 59 to true
        ':' -> 39 to false; '*' -> 39 to true
        ',' -> 44 to false; '<' -> 44 to true
        '.' -> 46 to false; '>' -> 46 to true
        '/' -> 47 to false; '?' -> 47 to true
        '_' -> 2 to false
        '\\', '¥' -> 92 to false; '|' -> 92 to true
        ' ', '　' -> 32 to false
        '\n' -> 13 to false
        '\t' -> 9 to false
        else -> null   // 日本語など DOS に打てない文字は読み飛ばす
    }

    fun typeText(text: CharSequence) {
        var t = maxOf(SystemClock.uptimeMillis(), typeFree)
        for (ch in text) {
            val (rk, shift) = keyFor(ch) ?: continue
            ui.postAtTime({ if (shift) Native.nKey(304, true); Native.nKey(rk, true) }, t)
            ui.postAtTime({ Native.nKey(rk, false); if (shift) Native.nKey(304, false) }, t + 45)
            t += 90
        }
        typeFree = t
    }

    fun pressKey(rk: Int) {
        val t = maxOf(SystemClock.uptimeMillis(), typeFree)
        ui.postAtTime({ Native.nKey(rk, true) }, t)
        ui.postAtTime({ Native.nKey(rk, false) }, t + 45)
        typeFree = t + 90
    }

    private inner class TextBridge(v: View) : BaseInputConnection(v, false) {
        private var pending = ""
        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
            pending = ""
            if (text != null) typeText(text)
            return true
        }
        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
            pending = text?.toString() ?: ""
            return true
        }
        override fun finishComposingText(): Boolean {
            if (pending.isNotEmpty()) typeText(pending)
            pending = ""
            return true
        }
        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            if (pending.isNotEmpty()) { pending = ""; return true }
            repeat(maxOf(beforeLength, 1)) { pressKey(8) }
            return true
        }
        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (event.action == KeyEvent.ACTION_DOWN) {
                when (event.keyCode) {
                    KeyEvent.KEYCODE_ENTER -> pressKey(13)
                    KeyEvent.KEYCODE_DEL -> pressKey(8)
                    else -> softKey(event)
                }
            }
            return true
        }
        override fun performEditorAction(actionCode: Int): Boolean { pressKey(13); return true }
    }

    // 画面キーボード(IME)のキー: 押して60ms後に離す。Shift は修飾状態から、: と _ は専用キーへ
    private fun softKey(e: KeyEvent) {
        val ch = e.unicodeChar.toChar()
        var shift = e.isShiftPressed
        var rk = retroKey(e.keyCode)
        when (ch) {
            ':' -> { rk = 39; shift = false }
            '_' -> { rk = 2; shift = false }
            '^' -> { rk = 61; shift = false }
            '@' -> { rk = 64; shift = false }
        }
        if (rk < 0) return
        if (shift) Native.nKey(304, true)
        Native.nKey(rk, true)
        ui.postDelayed({
            Native.nKey(rk, false)
            if (shift) Native.nKey(304, false)
        }, 60)
    }

    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        if (e.keyCode == KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(e)
        val down = e.action == KeyEvent.ACTION_DOWN
        if (e.repeatCount > 0) {
            // 長押しの連続イベントは無視（押しっぱなしの状態は保持される）
            if (isPad(e.source) && padMap.containsKey(e.keyCode)) return true
            if (retroKey(e.keyCode) >= 0) return true
        }
        if ((e.flags and KeyEvent.FLAG_SOFT_KEYBOARD) != 0) {
            if (down) softKey(e)
            return true   // 離す側は softKey が自分で処理する
        }
        val pad = padMap[e.keyCode]
        if (pad != null && isPad(e.source)) {
            Native.nJoy(pad, down)
            return true
        }
        if ((e.source and InputDevice.SOURCE_KEYBOARD) == InputDevice.SOURCE_KEYBOARD) {
            val rk = retroKey(e.keyCode)
            if (rk >= 0) {
                Native.nKey(rk, down)
                return true
            }
        }
        return super.dispatchKeyEvent(e)
    }

    override fun onGenericMotionEvent(e: MotionEvent): Boolean {
        if ((e.source and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK &&
            e.action == MotionEvent.ACTION_MOVE
        ) {
            val hx = e.getAxisValue(MotionEvent.AXIS_HAT_X)
            val hy = e.getAxisValue(MotionEvent.AXIS_HAT_Y)
            val x = if (abs(hx) > 0.5f) hx else e.getAxisValue(MotionEvent.AXIS_X)
            val y = if (abs(hy) > 0.5f) hy else e.getAxisValue(MotionEvent.AXIS_Y)
            setDir(y < -0.5f, y > 0.5f, x < -0.5f, x > 0.5f)
            return true
        }
        return super.onGenericMotionEvent(e)
    }

    private fun setDir(up: Boolean, down: Boolean, left: Boolean, right: Boolean) {
        val now = booleanArrayOf(up, down, left, right)
        for (i in 0..3) {
            if (now[i] != dir[i]) {
                dir[i] = now[i]
                Native.nJoy(4 + i, now[i])
            }
        }
    }
}
