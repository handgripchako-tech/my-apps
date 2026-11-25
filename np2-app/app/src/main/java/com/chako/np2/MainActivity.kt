package com.chako.np2

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import java.io.File

/** ディスクイメージ（hdi / fdi / d88 など）を選んで起動する一覧 */
class MainActivity : Activity() {
    private lateinit var list: ListView
    private lateinit var adapter: ArrayAdapter<String>
    private val files = ArrayList<File>()

    private fun disksDir() = File(filesDir, "disks").also { it.mkdirs() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 3, pad, pad)
        }
        root.addView(TextView(this).apply {
            text = "PC-98"
            textSize = 24f
            setTextColor(0xFFFFFFFF.toInt())
        })
        root.addView(Button(this).apply {
            text = "ゲーム一覧（全ディスクの実行ファイルから選ぶ）"
            setOnClickListener { startActivity(Intent(this@MainActivity, GameListActivity::class.java)) }
        })
        root.addView(Button(this).apply {
            text = "ディスクを追加（hdi / fdi / d88 など）"
            setOnClickListener { pick() }
        })
        root.addView(Button(this).apply {
            text = "空のHDD（hdi）を作る"
            setOnClickListener { askBlank() }
        })
        root.addView(Button(this).apply {
            text = "システムファイルを取り込む（フォント・リズム音源など）"
            setOnClickListener { pickSystem() }
        })
        root.addView(TextView(this).apply {
            text = "タップで起動 / 長押しで削除"
            setTextColor(0xFFAAAAAA.toInt())
        })
        list = ListView(this)
        adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, ArrayList<String>())
        list.adapter = adapter
        list.setOnItemClickListener { _, _, pos, _ -> launch(files[pos]) }
        list.setOnItemLongClickListener { _, _, pos, _ ->
            val f = files[pos]
            AlertDialog.Builder(this)
                .setTitle(f.name)
                .setItems(arrayOf("これを1台目、もう1台を2台目にして起動", "一覧から消す")) { _, which ->
                    if (which == 0) pickSecond(f) else confirmDelete(f)
                }
                .show()
            true
        }
        root.addView(list, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
    }

    // 中身が空の HDI を作る。パーティション作成（HDFORMAT）とフォーマット（FORMAT /S）は DOS 上でやる
    private fun askBlank() {
        val sizes = intArrayOf(20, 40, 80)
        AlertDialog.Builder(this)
            .setTitle("空のHDDの大きさ")
            .setItems(sizes.map { "${it}MB" }.toTypedArray()) { _, i -> createBlank(sizes[i]) }
            .setNegativeButton("やめる", null)
            .show()
    }

    private fun createBlank(mb: Int) {
        val ss = 512; val sec = 33; val hd = 8
        val cyl = (mb.toLong() * 1024 * 1024 / (ss.toLong() * sec * hd)).toInt()
        val dataSize = cyl.toLong() * sec * hd * ss
        val headSize = 4096
        var f = File(disksDir(), "blank_${mb}MB.hdi")
        var n = 2
        while (f.exists()) { f = File(disksDir(), "blank_${mb}MB_$n.hdi"); n++ }
        try {
            java.io.RandomAccessFile(f, "rw").use { raf ->
                val h = java.nio.ByteBuffer.allocate(headSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                h.putInt(0, 0)                    // dummy
                h.putInt(4, 0)                    // hddtype
                h.putInt(8, headSize)             // ヘッダーの大きさ
                h.putInt(12, dataSize.toInt())    // データの大きさ
                h.putInt(16, ss)                  // セクタの大きさ
                h.putInt(20, sec)                 // 1トラックのセクタ数
                h.putInt(24, hd)                  // ヘッド数
                h.putInt(28, cyl)                 // シリンダ数
                raf.write(h.array())
                raf.setLength(headSize + dataSize)  // 残りは 0 で埋まる
            }
            Toast.makeText(this, "作りました: ${f.name}", Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            Toast.makeText(this, "作れませんでした: ${e.message}", Toast.LENGTH_LONG).show()
        }
        refresh()
    }

    private fun confirmDelete(f: File) {
        AlertDialog.Builder(this)
            .setMessage("「${f.name}」を一覧から消しますか？")
            .setPositiveButton("消す") { _, _ ->
                f.delete()
                refresh()
            }
            .setNegativeButton("やめる", null)
            .show()
    }

    // 2台目（D: になる）を選んで起動。1台目から起動し、DOS の sys a: ではなく `sys c: d:` でシステムを移せる
    private fun pickSecond(first: File) {
        val others = files.filter { it != first }
        if (others.isEmpty()) {
            Toast.makeText(this, "2台目にするディスクがありません", Toast.LENGTH_LONG).show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("2台目を選ぶ")
            .setItems(others.map { it.name }.toTypedArray()) { _, i ->
                startActivity(
                    Intent(this, EmuActivity::class.java)
                        .putExtra("path", first.absolutePath)
                        .putExtra("path2", others[i].absolutePath)
                )
            }
            .show()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        files.clear()
        files.addAll((disksDir().listFiles() ?: emptyArray()).sortedBy { it.name.lowercase() })
        adapter.clear()
        adapter.addAll(files.map { "${it.name}  (${it.length() / 1024} KB)" })
        adapter.notifyDataSetChanged()
    }

    private fun launch(f: File) {
        startActivity(Intent(this, EmuActivity::class.java).putExtra("path", f.absolutePath))
    }

    private fun pick() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        @Suppress("DEPRECATION")
        startActivityForResult(i, 1)
    }

    private fun systemDir() = File(filesDir, "system/np2kai").also { it.mkdirs() }

    private fun pickSystem() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(i, 2)
    }

    private fun importSystem(data: Intent) {
        val uris = ArrayList<Uri>()
        data.clipData?.let { c -> for (n in 0 until c.itemCount) uris.add(c.getItemAt(n).uri) }
        data.data?.let { uris.add(it) }
        Toast.makeText(this, "取り込み中…", Toast.LENGTH_SHORT).show()
        Thread {
            val done = ArrayList<String>()
            var err: String? = null
            for (u in uris) {
                try {
                    val name = displayName(u) ?: continue
                    // エミュは小文字名で探すことが多いので小文字で保存（元の名前でも保存）
                    val bytes = contentResolver.openInputStream(u)!!.use { it.readBytes() }
                    File(systemDir(), name.lowercase()).writeBytes(bytes)
                    if (name != name.lowercase()) File(systemDir(), name).writeBytes(bytes)
                    done.add(name.lowercase())
                } catch (e: Exception) {
                    err = e.message
                }
            }
            val msg = "取り込み ${done.size}件: ${done.joinToString(", ")}" + (err?.let { "\n失敗: $it" } ?: "")
            runOnUiThread { Toast.makeText(this, msg, Toast.LENGTH_LONG).show() }
        }.start()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 2 && resultCode == RESULT_OK && data != null) { importSystem(data); return }
        val uri = data?.data ?: return
        if (requestCode != 1 || resultCode != RESULT_OK) return
        Toast.makeText(this, "取り込み中…", Toast.LENGTH_SHORT).show()
        Thread {
            val msg = try {
                val name = displayName(uri) ?: "disk.hdi"
                val out = File(disksDir(), name)
                contentResolver.openInputStream(uri)!!.use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
                "取り込みました: $name"
            } catch (e: Exception) {
                "取り込みに失敗: ${e.message}"
            }
            runOnUiThread {
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                refresh()
            }
        }.start()
    }

    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (i >= 0 && c.moveToFirst()) c.getString(i) else null
        }
}
