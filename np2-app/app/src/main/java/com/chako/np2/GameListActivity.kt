package com.chako.np2

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import java.io.File

/** 登録した全ディスクから実行ファイル（EXE/COM/BAT）を集めて一覧にし、選ぶとそのゲームを起動する */
class GameListActivity : Activity() {
    private class Game(
        val disk: File, val volIdx: Int, val dir: String, val name: String,
        val selfBoot: Boolean, val floppy: Boolean
    )

    private class DiskInfo(val file: File, val hasSystem: Boolean, val volCount: Int, val floppy: Boolean)

    private val games = ArrayList<Game>()
    private val disks = ArrayList<DiskInfo>()
    // 一覧は「ディスク＝ゲーム」。1つのディスクに入っている実行ファイルをまとめる
    private class Group(val disk: File, val items: List<Game>)
    private val shown = ArrayList<Group>()
    private lateinit var adapter: ArrayAdapter<String>
    private lateinit var info: TextView
    private lateinit var sysBtn: Button
    private var filter = ""

    private fun disksDir() = File(filesDir, "disks").also { it.mkdirs() }
    // エミュ（別プロセス）の設定ファイル "np2" とは分ける。同じファイルを両方のプロセスで書くと、片方が古い内容で上書きして消してしまう
    private fun prefs() = getSharedPreferences("np2_main", Context.MODE_PRIVATE)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 3, pad, pad)
        }
        root.addView(TextView(this).apply {
            text = "ゲーム一覧"
            textSize = 22f
            setTextColor(0xFFFFFFFF.toInt())
        })
        info = TextView(this).apply { setTextColor(0xFFAAAAAA.toInt()); text = "読み込み中…" }
        root.addView(info)
        sysBtn = Button(this).apply {
            isAllCaps = false
            textSize = 13f
            setOnClickListener { chooseSystem(null) }
        }
        root.addView(sysBtn)
        val instBtn = Button(this).apply { isAllCaps = false; textSize = 13f }
        fun instLabel() {
            val n = prefs().getString("installdisk", null)
            instBtn.text = "インストール先HDD: " + (if (n != null && File(disksDir(), n).exists()) n else "なし（タップで選ぶ）")
        }
        instBtn.setOnClickListener {
            val hds = disks.filter { !it.floppy }
            val names = (listOf("なし") + hds.map { it.file.name }).toTypedArray()
            AlertDialog.Builder(this)
                .setTitle("フロッピーのゲームを起動するとき、一緒につなぐHDD（インストール先）")
                .setItems(names) { _, i ->
                    prefs().edit().apply { if (i == 0) remove("installdisk") else putString("installdisk", hds[i - 1].file.name) }.apply()
                    instLabel()
                }
                .setNegativeButton("やめる", null)
                .show()
        }
        instLabel()
        root.addView(instBtn)
        val fastBtn = Button(this).apply { isAllCaps = false; textSize = 13f }
        fun fastLabel() { fastBtn.text = "起動済み状態から始める（実験）: " + if (prefs().getBoolean("fastboot", false)) "ON" else "OFF" }
        fastBtn.setOnClickListener {
            prefs().edit().putBoolean("fastboot", !prefs().getBoolean("fastboot", false)).apply()
            fastLabel()
        }
        fastBtn.setOnLongClickListener {
            val n = (File(filesDir, "states").listFiles() ?: emptyArray()).filter { it.name.startsWith("boot_") }
            n.forEach { it.delete() }
            Toast.makeText(this, "保存した起動状態を消しました（${n.size}件）", Toast.LENGTH_SHORT).show()
            true
        }
        fastLabel()
        root.addView(fastBtn)
        val edit = EditText(this).apply {
            hint = "名前で絞り込み"
            setTextColor(0xFFFFFFFF.toInt())
            setHintTextColor(0xFF888888.toInt())
            setSingleLine()
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    filter = s?.toString()?.lowercase() ?: ""
                    applyFilter()
                }
            })
        }
        root.addView(edit)
        val list = ListView(this)
        adapter = object : ArrayAdapter<String>(this, android.R.layout.simple_list_item_2, android.R.id.text1, ArrayList<String>()) {
            override fun getCount() = shown.size
            override fun getView(position: Int, convertView: android.view.View?, parent: android.view.ViewGroup): android.view.View {
                val v = convertView ?: layoutInflater.inflate(android.R.layout.simple_list_item_2, parent, false)
                val gr = shown[position]
                val t1 = v.findViewById<TextView>(android.R.id.text1)
                val t2 = v.findViewById<TextView>(android.R.id.text2)
                t1.text = "▶ " + gr.disk.name.substringBeforeLast('.')
                t1.setTextColor(0xFFFFFFFF.toInt())
                val last = lastGame(gr)
                t2.text = if (last != null) "前回: " + last.name + "（長押しで変更）"
                          else "実行ファイル ${gr.items.size}個（タップで選ぶ）"
                t2.setTextColor(0xFFAAAAAA.toInt())
                return v
            }
        }
        list.adapter = adapter
        list.setOnItemClickListener { _, _, pos, _ ->
            val gr = shown[pos]
            val last = lastGame(gr)
            when {
                last != null -> launch(last)
                gr.items.size == 1 -> launch(gr.items[0])
                else -> pickGame(gr)
            }
        }
        list.setOnItemLongClickListener { _, _, pos, _ -> pickGame(shown[pos]); true }
        root.addView(list, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        scan()
    }

    private fun scan() {
        Thread {
            val g = ArrayList<Game>()
            val d = ArrayList<DiskInfo>()
            val files = (disksDir().listFiles() ?: emptyArray()).sortedBy { it.name.lowercase() }
            for (f in files) {
                val rd = DiskReader.open(f.absolutePath) ?: continue
                try {
                    val vols = rd.volumes()
                    if (vols.isEmpty()) continue
                    val ext = f.name.substringAfterLast('.', "").lowercase()
                    val floppy = ext != "hdi"
                    var hasSys = false
                    val found = ArrayList<Game>()
                    for ((vi, v) in vols.withIndex()) {
                        val root = v.fat.list(0)
                        val sys = root.any { it.name.uppercase() == "IO.SYS" }
                        if (vi == 0) hasSys = sys
                        var budget = 4000
                        fun walk(cluster: Int, path: String, depth: Int) {
                            if (budget <= 0) return
                            val es = if (cluster == 0 && depth == 0) root else v.fat.list(cluster)
                            budget -= es.size
                            for (e in es) {
                                if (e.isDir) {
                                    val up = e.name.uppercase()
                                    if (depth < 4 && up != "DOS" && up != "COMMANDS") walk(e.cluster, path + (if (path == "\\") "" else "\\") + e.name, depth + 1)
                                } else {
                                    val up = e.name.uppercase()
                                    val x = up.substringAfterLast('.', "")
                                    if ((x == "EXE" || x == "COM" || x == "BAT") && up != "COMMAND.COM" && up != "AUTOEXEC.BAT") {
                                        found.add(Game(f, vi, path, e.name, sys, floppy))
                                    }
                                }
                            }
                        }
                        walk(0, "\\", 0)
                    }
                    d.add(DiskInfo(f, hasSys, vols.size, floppy))
                    g.addAll(found)
                } catch (e: Exception) {
                    // 読めないディスクは飛ばす
                } finally {
                    rd.close()
                }
            }
            g.sortWith(compareBy({ it.name.lowercase() }, { it.disk.name.lowercase() }))
            runOnUiThread {
                games.clear(); games.addAll(g)
                disks.clear(); disks.addAll(d)
                info.text = "${d.size}個のディスク（タップで起動／長押しで実行ファイルを選び直す）"
                updateSysBtn()
                applyFilter()
            }
        }.start()
    }

    private fun applyFilter() {
        shown.clear()
        val boot = currentSystem()?.file
        val byDisk = LinkedHashMap<File, ArrayList<Game>>()
        for (g in games) byDisk.getOrPut(g.disk) { ArrayList() }.add(g)
        for ((disk, items) in byDisk) {
            if (disk == boot) continue            // 起動用フロッピーは一覧に出さない
            val hit = filter.isEmpty() || disk.name.lowercase().contains(filter) || items.any { it.name.lowercase().contains(filter) }
            if (hit) shown.add(Group(disk, items))
        }
        // 最近遊んだ順、そのあと名前順
        shown.sortWith(compareBy({ -prefs().getLong("played_" + it.disk.name, 0L) }, { it.disk.name.lowercase() }))
        adapter.notifyDataSetChanged()
    }

    private fun lastGame(gr: Group): Game? {
        val v = prefs().getString("last_" + gr.disk.name, null) ?: return null
        val p = v.split("|")
        if (p.size < 3) return null
        return gr.items.firstOrNull { it.volIdx.toString() == p[0] && it.dir == p[1] && it.name == p[2] }
    }

    // 実行ファイルを選ぶ（選んだものは次回からタップだけで起動）
    private fun pickGame(gr: Group) {
        val items = gr.items.sortedWith(compareBy({ it.dir.lowercase() }, { it.name.lowercase() }))
        AlertDialog.Builder(this)
            .setTitle(gr.disk.name.substringBeforeLast('.') + " の起動ファイル")
            .setItems(items.map { it.name + "   " + it.dir }.toTypedArray()) { _, i -> launch(items[i]) }
            .setNegativeButton("やめる", null)
            .show()
    }

    // 起動用は、システム入りのフロッピー（fdi など）に固定
    private fun sysDisks() = disks.filter { it.hasSystem && it.floppy }

    private fun currentSystem(): DiskInfo? {
        val sd = sysDisks()
        val n = prefs().getString("sysdisk", null)
        return sd.firstOrNull { it.file.name == n } ?: if (sd.size == 1) sd[0] else null
    }

    private fun updateSysBtn() {
        val s = currentSystem()
        sysBtn.text = "起動用フロッピー: " + (s?.file?.name ?: "未設定（タップで選ぶ）")
    }

    private fun chooseSystem(then: ((DiskInfo) -> Unit)?) {
        val sd = sysDisks()
        if (sd.isEmpty()) {
            Toast.makeText(this, "システム入り（IO.SYS がある）のフロッピー（fdi）がありません。先に追加してください", Toast.LENGTH_LONG).show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("起動用フロッピー（システム入り）を選ぶ")
            .setItems(sd.map { it.file.name }.toTypedArray()) { _, i ->
                prefs().edit().putString("sysdisk", sd[i].file.name).apply()
                updateSysBtn()
                then?.invoke(sd[i])
            }
            .setNegativeButton("やめる", null)
            .show()
    }

    private fun launch(g: Game) {
        prefs().edit()
            .putString("last_" + g.disk.name, g.volIdx.toString() + "|" + g.dir + "|" + g.name)
            .putLong("played_" + g.disk.name, System.currentTimeMillis())
            .apply()
        if (g.selfBoot) {
            start(g.disk, null, ('A' + g.volIdx).toString(), g)
            return
        }
        val s = currentSystem()
        if (s == null) {
            chooseSystem { start(it.file, g.disk, driveFor(it, g), g) }
        } else {
            start(s.file, g.disk, driveFor(s, g), g)
        }
    }

    // フロッピーから起動すると、フロッピーが A:・B:、HDD は C: から。ゲームがフロッピー(fdi)なら B:
    private fun driveFor(sys: DiskInfo, g: Game): String =
        if (g.floppy) "B" else ('C' + g.volIdx).toString()

    private fun start(first: File, second: File?, drive: String, g: Game) {
        // フロッピーのゲーム（インストーラなど）には、設定したHDDを一緒につなぐ（C: になる）
        val inst = if (g.floppy && second != null) prefs().getString("installdisk", null)?.let { File(disksDir(), it) }?.takeIf { it.exists() } else null
        val i = Intent(this, EmuActivity::class.java)
            .putExtra("path", first.absolutePath)
            .putExtra("autorun", drive + "|" + g.dir + "|" + g.name)
            .putExtra("fastboot", prefs().getBoolean("fastboot", false))
            .putExtra("bootkey", first.name + "+" + (second?.name ?: "") + (if (inst != null) "+" + inst.name else ""))
        if (second != null) i.putExtra("path2", second.absolutePath)
        if (inst != null) i.putExtra("path3", inst.absolutePath)
        startActivity(i)
    }
}
