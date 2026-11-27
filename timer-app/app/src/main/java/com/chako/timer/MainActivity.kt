package com.chako.timer

import android.app.Activity
import android.app.AlertDialog
import android.app.AppOpsManager
import android.app.TimePickerDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {
    private lateinit var root: LinearLayout

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val sv = ScrollView(this)
        sv.fitsSystemWindows = true
        root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(14), dp(14), dp(14), dp(40))
        sv.addView(root)
        setContentView(sv)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onResume() {
        super.onResume()
        Scheduler.scheduleAll(this)
        render()
    }

    private fun tv(s: String, size: Float = 15f, color: Int = Color.WHITE): TextView {
        val t = TextView(this)
        t.text = s
        t.textSize = size
        t.setTextColor(color)
        return t
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    private fun isA11yOn(): Boolean {
        val s = Settings.Secure.getString(
            contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        )
        return s?.contains("$packageName/") == true
    }

    private fun hasUsage(): Boolean {
        val ops = getSystemService(AppOpsManager::class.java)
        return ops.checkOpNoThrow(
            "android:get_usage_stats", Process.myUid(), packageName
        ) == AppOpsManager.MODE_ALLOWED
    }

    private fun permRow(label: String, ok: Boolean, open: () -> Unit) {
        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL
        val t = tv((if (ok) "✅ " else "⚠️ ") + label, 13f, if (ok) Color.LTGRAY else Color.YELLOW)
        row.addView(t, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (!ok) {
            val b = Button(this)
            b.text = "設定"
            b.setOnClickListener { open() }
            row.addView(b)
        }
        root.addView(row)
    }

    private fun render() {
        root.removeAllViews()
        // 前回のクラッシュ内容があれば、いちばん上に出す（原因調べ用）
        val crash = getSharedPreferences("timer", MODE_PRIVATE).getString("crash", null)
        if (!crash.isNullOrEmpty()) {
            root.addView(tv("⚠️ 前回エラーで停止しました（この文を教えてください）", 13f, Color.YELLOW))
            val ct = tv(crash.take(1500), 10f, Color.RED)
            ct.setTextIsSelectable(true)
            root.addView(ct)
            val clr = Button(this)
            clr.text = "エラー表示を消す"
            clr.setOnClickListener {
                getSharedPreferences("timer", MODE_PRIVATE).edit().remove("crash").apply()
                render()
            }
            root.addView(clr)
        }
        try {
            renderMain()
        } catch (e: Exception) {
            root.addView(tv("画面の表示でエラー: " + android.util.Log.getStackTraceString(e).take(1200), 10f, Color.RED))
        }
    }

    private fun renderMain() {
        root.addView(tv("時限起動", 22f))
        root.addView(tv("毎日、決めた時刻にアプリを起動してマクロを実行します", 12f, Color.GRAY))
        root.addView(View(this), LinearLayout.LayoutParams(1, dp(8)))

        permRow("アクセシビリティ（起動とマクロに必要）", isA11yOn()) {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        permRow("使用状況へのアクセス（起動中スルーに必要）", hasUsage()) {
            startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
        }

        val pinRow = LinearLayout(this)
        pinRow.orientation = LinearLayout.HORIZONTAL
        pinRow.gravity = Gravity.CENTER_VERTICAL
        val pinText = when {
            PinStore.stoppedByFails(this) -> "⚠️ PIN自動解除: 連続失敗で停止中（再登録で再開）"
            PinStore.has(this) -> "✅ PIN自動解除: 登録済み"
            else -> "PIN自動解除: 未登録"
        }
        pinRow.addView(
            tv(pinText, 13f, Color.LTGRAY),
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        )
        val pinBtn = Button(this)
        pinBtn.text = if (PinStore.has(this)) "変更" else "登録"
        pinBtn.setOnClickListener { pinDialog() }
        pinRow.addView(pinBtn)
        if (PinStore.has(this)) {
            val del = Button(this)
            del.text = "削除"
            del.setOnClickListener {
                PinStore.clear(this)
                render()
            }
            pinRow.addView(del)
        }
        root.addView(pinRow)

        val flRow = LinearLayout(this)
        flRow.orientation = LinearLayout.HORIZONTAL
        flRow.gravity = Gravity.CENTER_VERTICAL
        flRow.addView(
            tv("終了予定をフローティング表示（ゲーム中も残り時間を表示・変更）", 13f, Color.LTGRAY),
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        )
        val flSw = Switch(this)
        flSw.isChecked = FloatingStop.enabled(this)
        flSw.setOnCheckedChangeListener { _, on ->
            FloatingStop.setEnabled(this, on)
            MacroService.instance?.refreshFloating()
        }
        flRow.addView(flSw)
        root.addView(flRow)

        root.addView(View(this), LinearLayout.LayoutParams(1, dp(12)))
        val jobs = Store.load(this).sortedWith(compareBy({ it.hour }, { it.minute }))
        if (jobs.isEmpty()) root.addView(tv("まだ登録がありません", 14f, Color.GRAY))
        for (j in jobs) root.addView(card(j))

        val add = Button(this)
        add.text = "＋ 追加"
        add.setOnClickListener { edit(null) }
        root.addView(add)

        root.addView(View(this), LinearLayout.LayoutParams(1, dp(16)))
        root.addView(tv("ログ（新しい順）", 13f, Color.GRAY))
        val log = Store.readLog(this).lines().filter { it.isNotBlank() }.reversed().joinToString("\n")
        root.addView(tv(if (log.isEmpty()) "（まだありません）" else log, 12f, Color.LTGRAY))
    }

    private fun card(j: Job): View {
        val c = LinearLayout(this)
        c.orientation = LinearLayout.VERTICAL
        c.setBackgroundColor(Color.parseColor("#1E1E1E"))
        c.setPadding(dp(12), dp(10), dp(12), dp(10))
        val lp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        )
        lp.bottomMargin = dp(10)
        c.layoutParams = lp

        val top = LinearLayout(this)
        top.orientation = LinearLayout.HORIZONTAL
        top.gravity = Gravity.CENTER_VERTICAL
        val title = tv(
            if (j.noLaunch && j.stopAt >= 0) "終了 %02d:%02d  %s".format(j.stopAt / 60, j.stopAt % 60, j.label)
            else "%02d:%02d  %s".format(j.hour, j.minute, j.label),
            18f
        )
        top.addView(title, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val sw = Switch(this)
        sw.isChecked = j.enabled
        sw.setOnCheckedChangeListener { _, on ->
            j.enabled = on
            if (on) j.onceStarted = false // 1回だけの予定は、ONにし直すと再び有効
            val list = Store.load(this)
            list.firstOrNull { it.id == j.id }?.let {
                it.enabled = on
                if (on) it.onceStarted = false
            }
            Store.save(this, list)
            Scheduler.schedule(this, j)
        }
        top.addView(sw)
        c.addView(top)

        val steps = Macro.parse(j.macro).size
        val info = (if (j.skipIfRunning) "起動中ならスルー" else "毎回起動") + " ／ マクロ ${steps}手順" +
            (if (j.once) " ／ 1回だけ" else "") +
            (if (j.stopMin > 0) " ／ ${j.stopMin}分後に終了" else "") +
            (if (j.stopAt >= 0 && !j.noLaunch) " ／ 毎日%02d:%02dに終了".format(j.stopAt / 60, j.stopAt % 60) else "")
        c.addView(tv(info, 12f, Color.GRAY))
        val pend = Stops.all(this).filter { it.id == j.id && it.at > System.currentTimeMillis() }
        for (s in pend) {
            val t = java.text.SimpleDateFormat("M/d HH:mm", java.util.Locale.JAPAN).format(java.util.Date(s.at))
            c.addView(tv("⏱ 次の終了予定: $t", 12f, Color.parseColor("#FFB74D")))
        }

        val btns = LinearLayout(this)
        btns.orientation = LinearLayout.HORIZONTAL
        val b1 = Button(this)
        b1.text = "編集"
        b1.setOnClickListener { edit(j) }
        val b2 = Button(this)
        b2.text = "テスト"
        b2.setOnClickListener {
            val s = MacroService.instance
            if (s == null) toast("先にアクセシビリティをONにしてください")
            else {
                s.runJob(j, true)
                toast("起動します")
            }
        }
        val b3 = Button(this)
        b3.text = "削除"
        b3.setOnClickListener {
            AlertDialog.Builder(this)
                .setMessage("「${j.label}」の予定を削除しますか？")
                .setPositiveButton("削除") { _, _ ->
                    Scheduler.cancel(this, j)
                    Store.save(this, Store.load(this).filter { it.id != j.id })
                    render()
                }
                .setNegativeButton("やめる", null)
                .show()
        }
        val b4 = Button(this)
        b4.text = "教える"
        b4.setOnClickListener {
            val s = MacroService.instance
            if (s == null) {
                toast("先にアクセシビリティをONにしてください")
            } else {
                AlertDialog.Builder(this)
                    .setTitle("どこから教えますか？")
                    .setItems(
                        arrayOf("アプリを起動して教える", "自分で開いたところから教える")
                    ) { _, which ->
                        val launchApp = which == 0
                        if (j.macro.isNotBlank()) {
                            AlertDialog.Builder(this)
                                .setMessage("今のマクロは消えて、新しく覚え直します。よろしいですか？")
                                .setPositiveButton("覚え直す") { _, _ -> teach(s, j, launchApp) }
                                .setNegativeButton("やめる", null)
                                .show()
                        } else {
                            teach(s, j, launchApp)
                        }
                    }
                    .show()
            }
        }
        for (b in listOf(b1, b4, b2, b3)) {
            b.textSize = 12f
            btns.addView(b, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        c.addView(btns)
        return c
    }

    private fun pinDialog() {
        val lay = LinearLayout(this)
        lay.orientation = LinearLayout.VERTICAL
        lay.setPadding(dp(16), dp(8), dp(16), dp(8))
        val et = EditText(this)
        et.inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
        et.hint = "端末のPIN（数字4桁以上）"
        lay.addView(et)
        lay.addView(
            tv(
                "・この端末の中で暗号化して保存します。通信はしません（このアプリはネット接続の権限を持っていません）\n" +
                    "・連続2回解除に失敗したら、ロックアウト防止のため自動入力を止めます\n" +
                    "・PINが長い／確定キーが要る機種では、うまく入らないことがあります",
                11f, Color.GRAY
            )
        )
        AlertDialog.Builder(this)
            .setTitle("PINを登録")
            .setView(lay)
            .setPositiveButton("保存") { _, _ ->
                val v = et.text.toString()
                if (v.length < 4 || !v.all { it.isDigit() }) {
                    toast("数字4桁以上で入力してください")
                } else {
                    PinStore.save(this, v)
                    render()
                }
            }
            .setNegativeButton("キャンセル", null)
            .show()
    }

    private fun teach(s: MacroService, j: Job, launchApp: Boolean) {
        if (launchApp) {
            toast("アプリが開いたら、いつも通り操作してください。終了ボタンで保存します")
        } else {
            toast("ホームに戻ります。アプリを開いて、右上の「記録開始」を押してください")
        }
        s.startTeaching(j, launchApp)
    }

    private fun pickApp(cb: (String, String) -> Unit) {
        val pm = packageManager
        val apps = pm.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0
        ).map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .distinctBy { it.first }
            .filter { it.first != packageName }
            .sortedBy { it.second }
        AlertDialog.Builder(this)
            .setTitle("起動するアプリ")
            .setItems(apps.map { it.second }.toTypedArray()) { _, i ->
                cb(apps[i].first, apps[i].second)
            }
            .show()
    }

    private fun edit(old: Job?) {
        val j = old?.copy() ?: Job(
            ((System.currentTimeMillis() / 1000) % 1_000_000_000L).toInt(),
            7, 0, "", "", true, true, ""
        )
        val lay = LinearLayout(this)
        lay.orientation = LinearLayout.VERTICAL
        lay.setPadding(dp(16), dp(8), dp(16), dp(8))

        val timeBtn = Button(this)
        fun upd() {
            timeBtn.text = "時刻  %02d:%02d".format(j.hour, j.minute)
        }
        upd()
        timeBtn.setOnClickListener {
            TimePickerDialog(this, { _, h, m ->
                j.hour = h
                j.minute = m
                upd()
            }, j.hour, j.minute, true).show()
        }

        val appBtn = Button(this)
        appBtn.text = if (j.pkg.isEmpty()) "アプリを選ぶ" else j.label
        appBtn.setOnClickListener {
            pickApp { pkg, label ->
                j.pkg = pkg
                j.label = label
                appBtn.text = label
            }
        }

        val skip = CheckBox(this)
        skip.text = "すでに前面で動いていたらスルー"
        skip.setTextColor(Color.WHITE)
        skip.isChecked = j.skipIfRunning

        val stopRow = LinearLayout(this)
        stopRow.orientation = LinearLayout.HORIZONTAL
        stopRow.gravity = Gravity.CENTER_VERTICAL
        stopRow.addView(tv("終了：起動から", 14f))
        val stopEt = EditText(this)
        stopEt.inputType = InputType.TYPE_CLASS_NUMBER
        stopEt.setText(if (j.stopMin > 0) j.stopMin.toString() else "")
        stopEt.hint = "0"
        stopEt.gravity = Gravity.CENTER
        stopEt.minWidth = dp(70)
        stopRow.addView(stopEt)
        stopRow.addView(tv("分後（空欄=終了しない）", 12f, Color.GRAY))

        val stopAtRow = LinearLayout(this)
        stopAtRow.orientation = LinearLayout.HORIZONTAL
        stopAtRow.gravity = Gravity.CENTER_VERTICAL
        val stopAtBtn = Button(this)
        fun updStopAt() {
            stopAtBtn.text =
                if (j.stopAt >= 0) "毎日の終了時刻  %02d:%02d".format(j.stopAt / 60, j.stopAt % 60)
                else "毎日の終了時刻  なし"
        }
        updStopAt()
        stopAtBtn.setOnClickListener {
            val cur = if (j.stopAt >= 0) j.stopAt else 8 * 60
            TimePickerDialog(this, { _, h, m ->
                j.stopAt = h * 60 + m
                updStopAt()
            }, cur / 60, cur % 60, true).show()
        }
        val stopAtClr = Button(this)
        stopAtClr.text = "解除"
        stopAtClr.setOnClickListener {
            j.stopAt = -1
            updStopAt()
        }
        stopAtRow.addView(stopAtBtn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        stopAtRow.addView(stopAtClr)
        val noLaunchCb = CheckBox(this)
        noLaunchCb.text = "起動はせず、終了だけ行う（自分で起動する場合）"
        noLaunchCb.setTextColor(Color.WHITE)
        noLaunchCb.isChecked = j.noLaunch

        val onceCb = CheckBox(this)
        onceCb.text = "1回だけ（実行したら自動でOFFになる）"
        onceCb.setTextColor(Color.WHITE)
        onceCb.isChecked = j.once

        val mac = EditText(this)
        mac.setText(j.macro)
        mac.hint = "マクロ（なくてもOK）\n例:\n待つ 5\nタップ 540 1200\n文字 開始"
        mac.minLines = 5
        mac.gravity = Gravity.TOP
        mac.typeface = Typeface.MONOSPACE
        mac.textSize = 13f
        mac.setHintTextColor(Color.GRAY)

        val help = tv(
            "1行1手順。起動の4秒後から順に実行します。\n" +
                "待つ 秒 ／ タップ x y ／ 長押し x y\n" +
                "スワイプ x1 y1 x2 y2 [ミリ秒]\n" +
                "戻る ／ 文字 ボタンの文字\n" +
                "座標は 開発者向けオプション→「ポインタの位置」で調べられます。\n" +
                "終了は、前面にいればホームに戻してからアプリを閉じます（使用状況アクセスが必要）。\n" +
                "「毎日の終了時刻」は、自分で起動したアプリでも、その時刻に閉じます。",
            11f, Color.GRAY
        )

        lay.addView(timeBtn)
        lay.addView(appBtn)
        lay.addView(skip)
        lay.addView(stopRow)
        lay.addView(stopAtRow)
        lay.addView(noLaunchCb)
        lay.addView(onceCb)
        lay.addView(mac)
        lay.addView(help)
        val sv = ScrollView(this)
        sv.addView(lay)

        AlertDialog.Builder(this)
            .setTitle(if (old == null) "追加" else "編集")
            .setView(sv)
            .setPositiveButton("保存") { _, _ ->
                if (j.pkg.isEmpty()) {
                    toast("アプリを選んでください")
                } else if (noLaunchCb.isChecked && j.stopAt < 0) {
                    toast("「終了だけ行う」には、毎日の終了時刻が必要です")
                } else {
                    j.noLaunch = noLaunchCb.isChecked
                    j.once = onceCb.isChecked
                    j.onceStarted = false
                    if (j.noLaunch) {
                        j.hour = j.stopAt / 60
                        j.minute = j.stopAt % 60
                    }
                    j.skipIfRunning = skip.isChecked
                    j.macro = mac.text.toString()
                    j.stopMin = stopEt.text.toString().toIntOrNull()?.coerceIn(0, 1440) ?: 0
                    val list = Store.load(this)
                    val idx = list.indexOfFirst { it.id == j.id }
                    if (idx >= 0) list[idx] = j else list.add(j)
                    Store.save(this, list)
                    Scheduler.schedule(this, j)
                    render()
                }
            }
            .setNegativeButton("キャンセル", null)
            .show()
    }
}
