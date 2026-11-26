#!/usr/bin/env python3
"""flutter create で作った android/ に、このアプリに必要な設定を足す。
(GitHub Actions から gallery-app/ で実行する)
 - 通信(INTERNET)・http接続・常駐再生に必要な権限
 - audio_service のサービス/受信設定
 - MainActivity を AudioServiceActivity に変更
 - アプリ名を「ギャラリー」に
"""
import glob
import re
import sys

MANIFEST = "android/app/src/main/AndroidManifest.xml"

PERMS = [
    "android.permission.INTERNET",
    "android.permission.WAKE_LOCK",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
]

SERVICE = """<service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>
    """


OPEN_FILTERS = """<intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="content" />
                <data android:scheme="file" />
                <data android:mimeType="video/*" />
                <data android:mimeType="application/x-matroska" />
                <data android:mimeType="application/mp4" />
                <data android:mimeType="application/pdf" />
                <data android:mimeType="application/epub+zip" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="video/*" />
                <data android:mimeType="application/pdf" />
                <data android:mimeType="application/epub+zip" />
            </intent-filter>
        """

KOTLIN = """package __PKG__

import android.content.ContentUris
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.Charset
import java.util.concurrent.Executors
import java.util.zip.ZipFile

// 他のアプリから「開く」「共有」で渡された動画・PDF・epub を Flutter 側へ渡す。
// 置き場所(パス)が分かればパスを、分からなければ content:// のまま渡す。
class MainActivity : AudioServiceActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gallery/book")
            .setMethodCallHandler { call, result -> bookCall(call, result) }
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gallery/intent")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            if (call.method == "initial") {
                val v = resolve(intent)
                if (v != null) setIntent(Intent(Intent.ACTION_MAIN))
                result.success(v)
            } else {
                result.notImplemented()
            }
        }
    }

    // ---- PDF・epub(zip) の読み取り（重い処理は裏の1本のスレッドで順番に） ----
    private val bookExec = Executors.newSingleThreadExecutor()
    private val mainH = Handler(Looper.getMainLooper())
    private val pdfs = HashMap<Int, Pair<ParcelFileDescriptor, PdfRenderer>>()
    private var pdfSeq = 0
    private val zips = HashMap<String, ZipFile>()

    private fun bookCall(call: MethodCall, result: MethodChannel.Result) {
        bookExec.execute {
            try {
                val src = call.argument<String>("src") ?: ""
                val v: Any? = when (call.method) {
                    "mime" -> contentResolver.getType(Uri.parse(src))
                    "name" -> displayName(Uri.parse(src))
                    "pdfOpen" -> {
                        val fd = ParcelFileDescriptor.open(localFile(src), ParcelFileDescriptor.MODE_READ_ONLY)
                        val r = try { PdfRenderer(fd) } catch (e: Exception) { fd.close(); throw e }
                        val id = ++pdfSeq
                        pdfs[id] = Pair(fd, r)
                        mapOf("id" to id, "count" to r.pageCount)
                    }
                    "pdfPage" -> {
                        val r = pdfs[call.argument<Int>("id")!!]?.second ?: throw Exception("PDFが閉じられています")
                        val page = r.openPage(call.argument<Int>("i")!!)
                        try {
                            val w = call.argument<Int>("w")!!
                            val pw = maxOf(1, page.width)
                            val ph = maxOf(1, page.height)
                            var bw = w
                            var bh = (w.toLong() * ph / pw).toInt()
                            if (bh > w * 3) { bh = w * 3; bw = maxOf(1, (bh.toLong() * pw / ph).toInt()) }
                            val bmp = Bitmap.createBitmap(bw, maxOf(1, bh), Bitmap.Config.ARGB_8888)
                            bmp.eraseColor(Color.WHITE)
                            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            val out = ByteArrayOutputStream()
                            bmp.compress(Bitmap.CompressFormat.JPEG, 90, out)
                            bmp.recycle()
                            out.toByteArray()
                        } finally {
                            page.close()
                        }
                    }
                    "pdfClose" -> {
                        pdfs.remove(call.argument<Int>("id")!!)?.let { it.second.close(); it.first.close() }
                        null
                    }
                    "zipList" -> {
                        val z = zipOf(src)
                        z.entries().asSequence().filter { !it.isDirectory }.map { it.name }.toList()
                    }
                    "zipRead" -> {
                        val z = zipOf(src)
                        val e = z.getEntry(call.argument<String>("name")!!) ?: throw Exception("中にありません")
                        z.getInputStream(e).use { it.readBytes() }
                    }
                    "zipClose" -> {
                        zips.remove(src)?.close()
                        null
                    }
                    else -> {
                        mainH.post { result.notImplemented() }
                        return@execute
                    }
                }
                mainH.post { result.success(v) }
            } catch (e: Throwable) {
                mainH.post { result.error("book", e.message ?: e.toString(), null) }
            }
        }
    }

    // zip を開いたまま覚えておく。名前が UTF-8 でない zip は Shift_JIS で開き直す
    private fun zipOf(src: String): ZipFile {
        zips[src]?.let { return it }
        val f = localFile(src)
        val z = try {
            val u = ZipFile(f)
            u.entries().asSequence().forEach { it.name }
            u
        } catch (e: Exception) {
            ZipFile(f, Charset.forName("Shift_JIS"))
        }
        while (zips.size >= 3) zips.remove(zips.keys.first())?.close()
        zips[src] = z
        return z
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme != "content") return uri.lastPathSegment
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (i >= 0) return c.getString(i)
            }
        }
        return null
    }

    // content:// はアプリのキャッシュに写してから読む（最近の3つだけ残す）
    private fun localFile(src: String): File {
        if (!src.startsWith("content://")) return File(src)
        val uri = Uri.parse(src)
        val dir = File(cacheDir, "book")
        dir.mkdirs()
        val name = displayName(uri) ?: "book"
        val dot = name.lastIndexOf('.')
        val ext = if (dot > 0) name.substring(dot) else ""
        val f = File(dir, Integer.toHexString(src.hashCode()) + ext)
        if (!f.exists() || f.length() == 0L) {
            val tmp = File(dir, f.name + ".part")
            contentResolver.openInputStream(uri)!!.use { inp -> tmp.outputStream().use { inp.copyTo(it) } }
            tmp.renameTo(f)
        }
        f.setLastModified(System.currentTimeMillis())
        dir.listFiles()?.filter { it.name != f.name }?.sortedByDescending { it.lastModified() }
            ?.drop(2)?.forEach { it.delete() }
        return f
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val v = resolve(intent) ?: return
        setIntent(Intent(Intent.ACTION_MAIN))
        channel?.invokeMethod("open", v)
    }

    @Suppress("DEPRECATION")
    private fun streamOf(i: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= 33) {
            i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
    }

    private fun resolve(i: Intent?): String? {
        if (i == null) return null
        val uri: Uri? = when (i.action) {
            Intent.ACTION_VIEW -> i.data
            Intent.ACTION_SEND -> streamOf(i)
            else -> null
        }
        if (uri == null) return null
        val p = toPath(uri)
        return if (p != null && File(p).exists()) p else uri.toString()
    }

    private fun toPath(uri: Uri): String? {
        try {
            if (uri.scheme == "file") return uri.path
            if (uri.scheme != "content") return null
            if (DocumentsContract.isDocumentUri(this, uri)) {
                val id = DocumentsContract.getDocumentId(uri)
                when (uri.authority) {
                    "com.android.externalstorage.documents" -> {
                        val parts = id.split(":", limit = 2)
                        val base = if (parts[0] == "primary")
                            Environment.getExternalStorageDirectory().path
                        else "/storage/" + parts[0]
                        return base + "/" + (parts.getOrNull(1) ?: "")
                    }
                    "com.android.providers.downloads.documents" -> {
                        if (id.startsWith("raw:")) return id.substring(4)
                        val num = id.removePrefix("msf:")
                        if (num.isNotEmpty() && num.all { it.isDigit() }) {
                            val u = ContentUris.withAppendedId(
                                MediaStore.Files.getContentUri("external"), num.toLong())
                            return queryData(u)
                        }
                    }
                    "com.android.providers.media.documents" -> {
                        val parts = id.split(":", limit = 2)
                        if (parts.size == 2) {
                            val base = when (parts[0]) {
                                "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                                else -> null
                            }
                            if (base != null) return queryData(Uri.withAppendedPath(base, parts[1]))
                        }
                    }
                }
            }
            return queryData(uri)
        } catch (e: Exception) {
            return null
        }
    }

    private fun queryData(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val i = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (i >= 0) return c.getString(i)
            }
        }
        return null
    }
}
"""


def patch_manifest():
    s = open(MANIFEST, encoding="utf-8").read()
    if "com.ryanheise.audioservice.AudioService" in s:
        print("manifest: すでに設定済み")
        return
    if s.count("<application") != 1 or s.count("</application>") != 1:
        sys.exit("manifest: <application> の位置が想定と違います")
    perms = "\n    ".join(
        '<uses-permission android:name="%s"/>' % p for p in PERMS
    )
    s = s.replace(
        "<application",
        perms + '\n    <application android:usesCleartextTraffic="true"',
        1,
    )
    s = re.sub(r'android:label="[^"]*"', 'android:label="ギャラリー"', s, count=1)
    s = s.replace("</application>", SERVICE + "</application>", 1)
    # 動画を「開く」「共有」の宛先にする（MainActivity の中に足す）
    if "</activity>" not in s:
        sys.exit("manifest: </activity> が見つかりません")
    s = s.replace("</activity>", OPEN_FILTERS + "</activity>", 1)
    open(MANIFEST, "w", encoding="utf-8").write(s)
    print("manifest: 設定を追加しました")


def patch_activity():
    files = glob.glob("android/app/src/main/**/MainActivity.kt", recursive=True)
    if not files:
        sys.exit("MainActivity.kt が見つかりません")
    for f in files:
        s = open(f, encoding="utf-8").read()
        if "gallery/intent" in s:
            print("activity: すでに設定済み " + f)
            continue
        m = re.search(r"^package\s+(\S+)", s, re.M)
        pkg = m.group(1) if m else "com.chako.gallery_app"
        open(f, "w", encoding="utf-8").write(KOTLIN.replace("__PKG__", pkg))
        print("activity: MainActivity を置き換えました " + f)


patch_manifest()
patch_activity()
