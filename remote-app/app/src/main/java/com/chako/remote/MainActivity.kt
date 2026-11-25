package com.chako.remote

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var peer: EditText

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun btn(label: String, onClick: () -> Unit): Button {
        val b = Button(this)
        b.text = label
        b.isAllCaps = false
        b.setOnClickListener { onClick() }
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.topMargin = dp(8)
        b.layoutParams = lp
        return b
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(16), dp(24), dp(16), dp(16))

        val title = TextView(this)
        title.text = "リモコン"
        title.textSize = 24f
        title.setTextColor(Color.WHITE)
        root.addView(title)

        status = TextView(this)
        status.textSize = 14f
        status.setTextColor(Color.LTGRAY)
        status.setPadding(0, dp(12), 0, dp(8))
        root.addView(status)

        val sec1 = TextView(this)
        sec1.text = "【操作される側の設定】"
        sec1.setTextColor(Color.rgb(128, 203, 196))
        sec1.setPadding(0, dp(8), 0, 0)
        root.addView(sec1)
        root.addView(btn("① ユーザー補助を開く（リモコンをオン）") {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        })
        root.addView(btn("② 他のアプリの上に重ねて表示を許可") {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        })
        root.addView(btn("③ 電池の最適化を外す") {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        })

        val sec2 = TextView(this)
        sec2.text = "【操作する側】相手のTailscaleアドレス（100.…）"
        sec2.setTextColor(Color.rgb(128, 203, 196))
        sec2.setPadding(0, dp(20), 0, 0)
        root.addView(sec2)
        peer = EditText(this)
        peer.setTextColor(Color.WHITE)
        peer.setHintTextColor(Color.GRAY)
        peer.hint = "例 100.64.1.2"
        peer.setSingleLine(true)
        peer.setText(getSharedPreferences("remote", MODE_PRIVATE).getString("peer", ""))
        root.addView(peer)
        root.addView(btn("相手を操作する") {
            val host = peer.text.toString().trim()
            if (host.isEmpty()) {
                Toast.makeText(this, "アドレスを入れてください", Toast.LENGTH_SHORT).show()
            } else {
                getSharedPreferences("remote", MODE_PRIVATE).edit().putString("peer", host).apply()
                startActivity(Intent(this, ControlActivity::class.java).putExtra("host", host))
            }
        })

        val sv = ScrollView(this)
        sv.addView(root)
        setContentView(sv)
    }

    override fun onResume() {
        super.onResume()
        val acc = if (RemoteService.instance != null) "オン（待ち受け中）" else "オフ"
        val ov = if (Settings.canDrawOverlays(this)) "許可済み" else "未許可"
        status.text = "このスマホ\n・ユーザー補助: $acc\n・重ねて表示: $ov\n・アドレス: ${myAddresses()}"
    }

    private fun myAddresses(): String {
        val list = ArrayList<String>()
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                for (a in ni.inetAddresses) {
                    if (a is Inet4Address && !a.isLoopbackAddress) list.add(a.hostAddress ?: "")
                }
            }
        } catch (_: Exception) {}
        // Tailscale（100.x）を先頭に
        list.sortBy { if (it.startsWith("100.")) 0 else 1 }
        return if (list.isEmpty()) "なし" else list.joinToString(" / ")
    }
}
