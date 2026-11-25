package com.chako.testserver

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.InputType
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.CookieManager
import android.webkit.JsResult
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.EditText
import android.widget.FrameLayout
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONTokener

/** サービスから WebView の JS を呼ぶための入口 */
object Bridge {
    @Volatile
    var web: WebView? = null

    fun js(code: String) {
        val w = web ?: return
        w.post { w.evaluateJavascript(code, null) }
    }
}

/**
 * ページが読み込まれる前に差し込む JS。
 *  - navigator.mediaSession の登録内容(次へ/前へ等)を控えておき、通知のボタンから呼べるようにする
 *  - いま鳴っている audio/video を控えておき、再生/停止ボタンの判定に使う
 */
private const val DOC_START_JS = """
(function(){
  try{
    var ms=navigator.mediaSession;
    if(ms&&!window.__msh){
      window.__msh={};
      var o=ms.setActionHandler.bind(ms);
      ms.setActionHandler=function(a,f){window.__msh[a]=f;return o(a,f)};
    }
    var P=HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play=function(){
      var el=this;
      if(!el.__w){el.__w=1;el.addEventListener('playing',function(){window.__cur=el})}
      return P.apply(this,arguments)
    };
  }catch(e){}
})();
"""

class MainActivity : Activity() {
    private lateinit var root: FrameLayout
    private lateinit var web: WebView
    private var customView: View? = null
    private var customCb: WebChromeClient.CustomViewCallback? = null
    private var errorDialog: AlertDialog? = null
    private var stoppedAt = 0L
    private val prefs by lazy { getSharedPreferences("app", MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = 0xFF000000.toInt()
        window.navigationBarColor = 0xFF000000.toInt()

        root = FrameLayout(this)
        root.setBackgroundColor(0xFF000000.toInt())
        web = WebView(this)
        root.addView(
            web,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        setContentView(root)

        setupWebView()
        web.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
        Bridge.web = web

        val url = prefs.getString("url", null)
        if (url == null) askUrl() else web.loadUrl(url)

        requestPerms()
    }

    @Suppress("SetJavaScriptEnabled")
    private fun setupWebView() {
        val s = web.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        s.mediaPlaybackRequiresUserGesture = false
        s.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        s.allowFileAccess = false
        s.setSupportZoom(false)
        CookieManager.getInstance().setAcceptCookie(true)
        web.setBackgroundColor(0xFF000000.toInt())

        web.setDownloadListener { url, _, _, _, _ ->
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            } catch (_: Exception) {
            }
        }

        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(web, DOC_START_JS, setOf("*"))
        }

        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest
            ): Boolean {
                val cur = Uri.parse(prefs.getString("url", "") ?: "")
                val u = request.url
                if (u.host == cur.host) return false
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, u))
                } catch (_: Exception) {
                }
                return true
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError
            ) {
                if (request.isForMainFrame) showError(error.description?.toString() ?: "")
            }

            override fun onRenderProcessGone(
                view: WebView,
                detail: RenderProcessGoneDetail
            ): Boolean {
                runOnUiThread { recreate() }
                return true
            }
        }

        web.webChromeClient = object : WebChromeClient() {
            override fun onShowCustomView(view: View, callback: WebChromeClient.CustomViewCallback) {
                if (customView != null) {
                    callback.onCustomViewHidden()
                    return
                }
                customView = view
                customCb = callback
                web.visibility = View.GONE
                root.addView(
                    view,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    )
                )
                immersive(true)
            }

            override fun onHideCustomView() {
                hideCustom()
            }

            // ページ側の alert / confirm（削除の確認など）を表示する
            override fun onJsAlert(
                view: WebView,
                url: String,
                message: String,
                result: JsResult
            ): Boolean {
                AlertDialog.Builder(this@MainActivity)
                    .setMessage(message)
                    .setPositiveButton("OK") { _, _ -> result.confirm() }
                    .setOnCancelListener { result.cancel() }
                    .show()
                return true
            }

            override fun onJsConfirm(
                view: WebView,
                url: String,
                message: String,
                result: JsResult
            ): Boolean {
                AlertDialog.Builder(this@MainActivity)
                    .setMessage(message)
                    .setPositiveButton("OK") { _, _ -> result.confirm() }
                    .setNegativeButton("キャンセル") { _, _ -> result.cancel() }
                    .setOnCancelListener { result.cancel() }
                    .show()
                return true
            }
        }
    }

    private fun hideCustom() {
        val v = customView ?: return
        root.removeView(v)
        customView = null
        customCb?.onCustomViewHidden()
        customCb = null
        web.visibility = View.VISIBLE
        immersive(false)
    }

    @Suppress("DEPRECATION")
    private fun immersive(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 30) {
            val c = window.insetsController ?: return
            if (on) {
                c.hide(WindowInsets.Type.systemBars())
                c.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            } else {
                c.show(WindowInsets.Type.systemBars())
            }
        } else {
            window.decorView.systemUiVisibility = if (on) {
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            } else {
                View.SYSTEM_UI_FLAG_VISIBLE
            }
        }
    }

    private fun savedUrl(): String = prefs.getString("url", "") ?: ""

    private fun showError(msg: String) {
        if (errorDialog?.isShowing == true) return
        errorDialog = AlertDialog.Builder(this)
            .setTitle("サーバーに接続できません")
            .setMessage("Tailscale が ON か、アドレスが合っているか確認してください。\n\n$msg")
            .setPositiveButton("再読み込み") { _, _ -> web.loadUrl(savedUrl()) }
            .setNegativeButton("アドレス変更") { _, _ -> askUrl() }
            .show()
    }

    private fun askUrl() {
        val et = EditText(this)
        et.setText(prefs.getString("url", "http://"))
        et.hint = "http://100.x.x.x:5000/"
        et.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        et.setSingleLine()
        AlertDialog.Builder(this)
            .setTitle("サーバーのアドレス")
            .setMessage("例: http://100.x.x.x:5000/ （Tailscale の IP とポート）")
            .setView(et)
            .setCancelable(false)
            .setPositiveButton("OK") { _, _ ->
                var u = et.text.toString().trim()
                if (u.isEmpty()) {
                    askUrl()
                } else {
                    if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://$u"
                    prefs.edit().putString("url", u).apply()
                    web.loadUrl(u)
                }
            }
            .show()
    }

    private fun requestPerms() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        } else {
            afterPerms()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        afterPerms()
    }

    private fun afterPerms() {
        // 背景でも止まらないよう、通知付きのサービスで常駐させる
        startForegroundService(Intent(this, KeepAliveService::class.java))

        // バッテリー最適化の除外（背景再生が止められにくくなる）を、最初の1回だけ頼む
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(packageName) && !prefs.getBoolean("batAsked", false)) {
            prefs.edit().putBoolean("batAsked", true).apply()
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (_: Exception) {
            }
        }
    }

    override fun onStop() {
        stoppedAt = System.currentTimeMillis()
        super.onStop()
    }

    override fun onStart() {
        super.onStart()
        val t = stoppedAt
        stoppedAt = 0L
        if (t > 0 && System.currentTimeMillis() - t > 3000) showDebug()
    }

    /** 画面に戻ったとき、ボタンの記録とプレーヤーのログを表示する（原因調べ用） */
    private fun showDebug() {
        web.evaluateJavascript(
            "JSON.stringify([localStorage.getItem('app.dbg'),localStorage.getItem('v.dbg')])"
        ) { v ->
            try {
                val outer = JSONArray(JSONTokener(v).nextValue() as String)
                val sb = StringBuilder()
                val titles = arrayOf("【ボタン】", "【再生】")
                for (i in 0 until 2) {
                    if (outer.isNull(i)) continue
                    val a = JSONArray(outer.getString(i))
                    if (a.length() == 0) continue
                    sb.append(titles[i]).append('\n')
                    for (j in 0 until a.length()) sb.append(a.getString(j)).append('\n')
                }
            } catch (_: Exception) {
            }
        }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onBackPressed() {
        when {
            customView != null -> hideCustom()
            web.canGoBack() -> web.goBack()
            else -> moveTaskToBack(true)   // 閉じずに裏へ回す（再生は続く）
        }
    }

    override fun onDestroy() {
        Bridge.web = null
        web.destroy()
        if (isFinishing) stopService(Intent(this, KeepAliveService::class.java))
        super.onDestroy()
    }
}
