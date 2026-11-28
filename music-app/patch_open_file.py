#!/usr/bin/env python3
"""ファイルマネージャなどの「開く」「共有」から曲（MIDI・普通の音楽ファイル）を受け取れるようにする。
(GitHub Actions から music-app/ で実行する。patch_android.py / patch_music_extra.py の後)
 - AndroidManifest の MainActivity に VIEW / SEND の intent-filter を追加
 - MainActivity を、受け取ったファイルをキャッシュにコピーして Dart に渡す版に置き換える
   (チャンネル music_app/open: Dart→"take" で {path, name}、新しく開かれたら Kotlin→"opened")
"""
import glob
import sys

MANIFEST = "android/app/src/main/AndroidManifest.xml"

FILTERS = """
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="content" />
                <data android:scheme="file" />
                <data android:mimeType="audio/*" />
                <data android:mimeType="application/x-midi" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="audio/*" />
                <data android:mimeType="application/x-midi" />
            </intent-filter>
"""

KOTLIN = """package com.chako.music_app

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var pending: Uri? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pending = uriOf(intent)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "music_app/open")
        ch.setMethodCallHandler { call, result ->
            if (call.method == "take") {
                val u = pending
                pending = null
                if (u == null) {
                    result.success(null)
                } else {
                    Thread {
                        val r = try { copy(u) } catch (e: Exception) { null }
                        runOnUiThread { result.success(r) }
                    }.start()
                }
            } else {
                result.notImplemented()
            }
        }
        channel = ch
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val u = uriOf(intent) ?: return
        pending = u
        channel?.invokeMethod("opened", null)
    }

    private fun uriOf(i: Intent?): Uri? {
        if (i == null) return null
        if (i.action == Intent.ACTION_VIEW) return i.data
        if (i.action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            return i.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        return null
    }

    private fun nameOf(u: Uri): String {
        try {
            contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getString(0)
                    if (!n.isNullOrEmpty()) return n
                }
            }
        } catch (e: Exception) {
        }
        return u.lastPathSegment?.substringAfterLast('/') ?: "song.mid"
    }

    private fun copy(u: Uri): Map<String, String>? {
        val name = nameOf(u).replace('/', '_')
        val dir = File(cacheDir, "opened")
        dir.mkdirs()
        dir.listFiles()?.forEach { it.delete() }
        val f = File(dir, name)
        val inp = contentResolver.openInputStream(u) ?: return null
        inp.use { s -> f.outputStream().use { s.copyTo(it) } }
        return mapOf("path" to f.absolutePath, "name" to name)
    }
}
"""


def patch_manifest():
    s = open(MANIFEST, encoding="utf-8").read()
    if "android.intent.action.SEND" in s:
        print("[open] manifest: すでに設定済み")
        return
    i = s.find('android:name=".MainActivity"')
    if i < 0:
        sys.exit("[open] manifest: MainActivity が見つかりません")
    j = s.find("</activity>", i)
    if j < 0:
        sys.exit("[open] manifest: </activity> が見つかりません")
    s = s[:j] + FILTERS.lstrip("\n") + "        " + s[j:]
    open(MANIFEST, "w", encoding="utf-8").write(s)
    print("[open] manifest: 開く/共有の受け取りを追加しました")


def patch_activity():
    files = glob.glob("android/app/src/main/**/MainActivity.*", recursive=True)
    if not files:
        sys.exit("[open] MainActivity が見つかりません")
    for f in files:
        if f.endswith(".java"):
            sys.exit("[open] MainActivity が Java です（Kotlin を想定）: " + f)
        open(f, "w", encoding="utf-8").write(KOTLIN)
        print("[open] MainActivity を置き換えました " + f)


if __name__ == "__main__":
    patch_manifest()
    patch_activity()
