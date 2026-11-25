package com.chako.msx_app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast

class MainActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var root: FrameLayout
    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private var customView: View? = null
    private var customCb: WebChromeClient.CustomViewCallback? = null
    private var lastBack = 0L

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 28) {
            val lp = window.attributes
            lp.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            window.attributes = lp
        }

        root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)

        web = WebView(this)
        web.setBackgroundColor(Color.BLACK)
        web.overScrollMode = View.OVER_SCROLL_NEVER
        val s = web.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        s.allowFileAccess = true
        s.allowContentAccess = true
        s.mediaPlaybackRequiresUserGesture = false
        web.webViewClient = WebViewClient()
        web.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(
                w: WebView?,
                cb: ValueCallback<Array<Uri>>?,
                params: FileChooserParams?
            ): Boolean {
                fileCallback?.onReceiveValue(null)
                fileCallback = cb
                val i = Intent(Intent.ACTION_GET_CONTENT)
                i.addCategory(Intent.CATEGORY_OPENABLE)
                i.type = "*/*"
                return try {
                    startActivityForResult(Intent.createChooser(i, "ファイルを選択"), 1001)
                    true
                } catch (e: Exception) {
                    fileCallback = null
                    false
                }
            }

            override fun onShowCustomView(view: View?, cb: CustomViewCallback?) {
                if (customView != null || view == null) {
                    cb?.onCustomViewHidden()
                    return
                }
                customView = view
                customCb = cb
                web.visibility = View.GONE
                root.addView(
                    view,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT
                    )
                )
            }

            override fun onHideCustomView() {
                hideCustom()
            }
        }
        root.addView(
            web,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        setContentView(root)
        web.loadUrl("file:///android_asset/msx.html")
    }

    private fun hideCustom() {
        val v = customView ?: return
        root.removeView(v)
        customView = null
        web.visibility = View.VISIBLE
        customCb?.onCustomViewHidden()
        customCb = null
    }

    @Suppress("DEPRECATION")
    private fun immersive() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) immersive()
    }

    override fun onPause() {
        super.onPause()
        web.onPause()
    }

    override fun onResume() {
        super.onResume()
        web.onResume()
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 1001) {
            val r = WebChromeClient.FileChooserParams.parseResult(resultCode, data)
            fileCallback?.onReceiveValue(r)
            fileCallback = null
        } else {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (customView != null) {
            hideCustom()
            return
        }
        val now = System.currentTimeMillis()
        if (now - lastBack < 2000) {
            super.onBackPressed()
        } else {
            lastBack = now
            Toast.makeText(this, "もう一度押すと終了します", Toast.LENGTH_SHORT).show()
        }
    }
}
