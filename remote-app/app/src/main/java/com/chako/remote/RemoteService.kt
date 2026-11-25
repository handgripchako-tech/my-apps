package com.chako.remote

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 受ける側。ユーザー補助サービスとして常駐し、小さなHTTPサーバーで指示を受け付ける。
 *   GET /ping
 *   GET /screen               画面のJPEG
 *   GET /apps                 起動できるアプリ一覧（"パッケージ名\t名前" を1行ずつ）
 *   GET /launch?pkg=...       アプリ起動
 *   GET /tap?x=0.5&y=0.5&d=50 タップ（x,y は 0〜1 の割合、d はミリ秒）
 *   GET /swipe?x1=&y1=&x2=&y2=&d=300
 *   GET /key?k=back|home|recents
 *   GET /wake                 画面を点ける
 * Tailscale のアドレス(100.64.0.0/10)と本機内からの接続だけ許可する。
 */
class RemoteService : AccessibilityService() {

    companion object {
        const val PORT = 8765
        @Volatile var instance: RemoteService? = null
    }

    private val pool = Executors.newCachedThreadPool()
    private val handler = Handler(Looper.getMainLooper())
    private var server: ServerSocket? = null

    @Volatile private var lastW = 0
    @Volatile private var lastH = 0

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        startServer()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onDestroy() {
        instance = null
        try { server?.close() } catch (_: Exception) {}
        server = null
        super.onDestroy()
    }

    private fun startServer() {
        try { server?.close() } catch (_: Exception) {}
        val ss = try { ServerSocket(PORT) } catch (e: Exception) { return }
        server = ss
        Thread {
            while (true) {
                val s = try { ss.accept() } catch (e: Exception) { break }
                pool.execute { handle(s) }
            }
        }.start()
    }

    private fun allowed(ip: InetAddress): Boolean {
        if (ip.isLoopbackAddress) return true
        val b = ip.address
        if (b.size == 4) {
            return (b[0].toInt() and 0xff) == 100 && (b[1].toInt() and 0xff) in 64..127
        }
        if (b.size == 16) {
            // Tailscale の IPv6 (fd7a:115c:a1e0::/48)
            val h = intArrayOf(0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0)
            return h.indices.all { (b[it].toInt() and 0xff) == h[it] }
        }
        return false
    }

    private fun handle(s: Socket) {
        try {
            s.soTimeout = 5000
            val reader = s.getInputStream().bufferedReader()
            val line = reader.readLine() ?: return
            while (true) {
                val h = reader.readLine()
                if (h.isNullOrEmpty()) break
            }
            val out = s.getOutputStream()
            if (!allowed(s.inetAddress)) {
                respond(out, 403, "text/plain", "forbidden".toByteArray())
                return
            }
            val target = line.split(" ").getOrNull(1) ?: return
            val path = target.substringBefore('?')
            val q = HashMap<String, String>()
            target.substringAfter('?', "").split("&").forEach {
                if (it.isNotEmpty()) {
                    q[URLDecoder.decode(it.substringBefore('='), "UTF-8")] =
                        URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
                }
            }
            when (path) {
                "/ping" -> respond(out, 200, "text/plain", "pong".toByteArray())
                "/screen" -> {
                    val jpg = screenshotJpeg()
                    if (jpg != null) respond(out, 200, "image/jpeg", jpg)
                    else respond(out, 503, "text/plain", "screenshot failed".toByteArray())
                }
                "/apps" -> respond(out, 200, "text/plain; charset=utf-8", appList().toByteArray())
                "/launch" -> respond(out, 200, "text/plain; charset=utf-8", launch(q["pkg"] ?: "").toByteArray())
                "/tap" -> {
                    val (x, y) = pos(q["x"], q["y"])
                    val d = (q["d"]?.toLongOrNull() ?: 50L).coerceIn(10L, 3000L)
                    val ok = gesture(x, y, x, y, d)
                    respond(out, 200, "text/plain", (if (ok) "ok" else "err").toByteArray())
                }
                "/swipe" -> {
                    val (x1, y1) = pos(q["x1"], q["y1"])
                    val (x2, y2) = pos(q["x2"], q["y2"])
                    val d = (q["d"]?.toLongOrNull() ?: 300L).coerceIn(50L, 3000L)
                    val ok = gesture(x1, y1, x2, y2, d)
                    respond(out, 200, "text/plain", (if (ok) "ok" else "err").toByteArray())
                }
                "/wake" -> {
                    wake()
                    respond(out, 200, "text/plain", "ok".toByteArray())
                }
                "/key" -> {
                    val act = when (q["k"]) {
                        "back" -> GLOBAL_ACTION_BACK
                        "home" -> GLOBAL_ACTION_HOME
                        "recents" -> GLOBAL_ACTION_RECENTS
                        else -> -1
                    }
                    val ok = act >= 0 && performGlobalAction(act)
                    respond(out, 200, "text/plain", (if (ok) "ok" else "err").toByteArray())
                }
                else -> respond(out, 404, "text/plain", "not found".toByteArray())
            }
        } catch (_: Exception) {
        } finally {
            try { s.close() } catch (_: Exception) {}
        }
    }

    private fun respond(o: OutputStream, code: Int, type: String, body: ByteArray) {
        val head = "HTTP/1.1 $code X\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
        o.write(head.toByteArray())
        o.write(body)
        o.flush()
    }

    // 0〜1 の割合 → 実際のピクセル
    private fun pos(xs: String?, ys: String?): Pair<Float, Float> {
        var w = lastW
        var h = lastH
        if (w <= 0 || h <= 0) {
            val b = (getSystemService(WINDOW_SERVICE) as WindowManager).maximumWindowMetrics.bounds
            w = b.width(); h = b.height()
        }
        val fx = (xs?.toFloatOrNull() ?: 0.5f).coerceIn(0f, 1f)
        val fy = (ys?.toFloatOrNull() ?: 0.5f).coerceIn(0f, 1f)
        return Pair(fx * w, fy * h)
    }

    private fun gesture(x1: Float, y1: Float, x2: Float, y2: Float, dur: Long): Boolean {
        val p = Path()
        p.moveTo(x1, y1)
        if (x1 != x2 || y1 != y2) p.lineTo(x2, y2)
        val g = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(p, 0, dur))
            .build()
        return dispatchGesture(g, null, null)
    }

    private fun screenshotJpeg(): ByteArray? {
        var result: ByteArray? = null
        val latch = CountDownLatch(1)
        takeScreenshot(Display.DEFAULT_DISPLAY, pool, object : TakeScreenshotCallback {
            override fun onSuccess(r: ScreenshotResult) {
                try {
                    val hb = r.hardwareBuffer
                    val hw = Bitmap.wrapHardwareBuffer(hb, r.colorSpace)
                    if (hw != null) {
                        val soft = hw.copy(Bitmap.Config.ARGB_8888, false)
                        lastW = soft.width
                        lastH = soft.height
                        val scale = minOf(1f, 1280f / maxOf(soft.width, soft.height))
                        val bmp = if (scale < 1f)
                            Bitmap.createScaledBitmap(soft, (soft.width * scale).toInt(), (soft.height * scale).toInt(), true)
                        else soft
                        val bos = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.JPEG, 60, bos)
                        result = bos.toByteArray()
                    }
                    hb.close()
                } catch (_: Exception) {
                }
                latch.countDown()
            }

            override fun onFailure(errorCode: Int) {
                latch.countDown()
            }
        })
        latch.await(4, TimeUnit.SECONDS)
        return result
    }

    @Suppress("DEPRECATION")
    private fun wake() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val wl = pm.newWakeLock(
            PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
            "chakoremote:wake"
        )
        wl.acquire(10_000L)
    }

    private fun appList(): String {
        val pm = packageManager
        val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(i, PackageManager.MATCH_ALL)
            .map { Pair(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
            .distinctBy { it.first }
            .sortedBy { it.second.lowercase() }
            .joinToString("\n") { "${it.first}\t${it.second}" }
    }

    private fun launch(pkg: String): String {
        val intent = packageManager.getLaunchIntentForPackage(pkg) ?: return "err: アプリが見つかりません"
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return try {
            handler.post {
                try { startActivity(intent) } catch (_: Exception) {}
            }
            "ok"
        } catch (e: Exception) {
            "err: ${e.message}"
        }
    }
}
