package com.chako.timer

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** エラー内容を見せるだけの画面（別プロセスで動く）。 */
class CrashActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val trace = intent.getStringExtra("trace") ?: "(内容なし)"
        val pad = (14 * resources.displayMetrics.density).toInt()
        val lay = LinearLayout(this)
        lay.orientation = LinearLayout.VERTICAL
        lay.setPadding(pad, pad, pad, pad)
        lay.fitsSystemWindows = true

        val title = TextView(this)
        title.text = "時限起動がエラーで停止しました\nこの画面のスクショか、コピーした文を教えてください"
        title.setTextColor(Color.YELLOW)
        title.textSize = 14f
        lay.addView(title)

        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        val copy = Button(this)
        copy.text = "コピー"
        copy.setOnClickListener {
            val cm = getSystemService(ClipboardManager::class.java)
            cm.setPrimaryClip(ClipData.newPlainText("crash", trace))
            Toast.makeText(this, "コピーしました", Toast.LENGTH_SHORT).show()
        }
        val close = Button(this)
        close.text = "閉じる"
        close.setOnClickListener { finishAndRemoveTask() }
        row.addView(copy, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(close, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        lay.addView(row)

        val tv = TextView(this)
        tv.text = trace
        tv.setTextColor(Color.parseColor("#FF8A80"))
        tv.textSize = 10f
        tv.setTextIsSelectable(true)
        val sv = ScrollView(this)
        sv.addView(tv)
        lay.addView(sv)
        setContentView(lay)
    }
}
