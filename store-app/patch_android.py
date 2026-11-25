#!/usr/bin/env python3
"""flutter create で作った android/ に、ストアに必要な設定を足す。
(GitHub Actions から store-app/ で実行する)
 - 通信 / APKインストール / 他アプリの一覧取得の許可
 - アプリ名を「ストア」に
 - APK インストール用 FileProvider
 - MainActivity に info / install / launch / uninstall のチャンネル
 - 部品(プラグイン)の compileSdk を 36 に揃える Gradle 初期スクリプト
"""
import os
import re
import sys

MANIFEST = "android/app/src/main/AndroidManifest.xml"
KOTLIN_DIR = "android/app/src/main/kotlin/com/chako/store_app"
XML_DIR = "android/app/src/main/res/xml"

PERMS = [
    "android.permission.INTERNET",
    "android.permission.REQUEST_INSTALL_PACKAGES",
    "android.permission.QUERY_ALL_PACKAGES",
]

PROVIDER = """<provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>
        """


def patch_manifest():
    s = open(MANIFEST, encoding="utf-8").read()
    if s.count("<application") != 1 or s.count("</application>") != 1:
        sys.exit("manifest: <application> の位置が想定と違います")
    add = ""
    for p in PERMS:
        if p not in s:
            add += '<uses-permission android:name="%s"/>\n    ' % p
    if add:
        s = s.replace("<application", add + "<application", 1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="ストア"', s, count=1)
    if "FileProvider" not in s:
        s = s.replace("</application>", PROVIDER + "</application>", 1)
    open(MANIFEST, "w", encoding="utf-8").write(s)
    print("manifest: 設定を追加しました")


FILE_PATHS = """<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="cache" path="." />
    <!-- Flutter の systemTemp は code_cache になるので root-path で全体を許可 -->
    <root-path name="root" path="." />
</paths>
"""

MAIN_ACTIVITY = """package com.chako.store_app

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chako/store")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        try {
                            val pi = packageManager.getPackageInfo(pkg, 0)
                            val code = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()
                            result.success(
                                mapOf(
                                    "versionName" to (pi.versionName ?: ""),
                                    "versionCode" to code,
                                    "updated" to pi.lastUpdateTime
                                )
                            )
                        } catch (e: PackageManager.NameNotFoundException) {
                            result.success(null)
                        }
                    }
                    "install" -> {
                        val path = call.argument<String>("path") ?: ""
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            val i = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + packageName))
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success("need_permission")
                        } else {
                            val uri = FileProvider.getUriForFile(this, packageName + ".fileprovider", File(path))
                            val i = Intent(Intent.ACTION_VIEW)
                            i.setDataAndType(uri, "application/vnd.android.package-archive")
                            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success("ok")
                        }
                    }
                    "launch" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val i = packageManager.getLaunchIntentForPackage(pkg)
                        if (i != null) {
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "uninstall" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val i = Intent(Intent.ACTION_DELETE, Uri.parse("package:" + pkg))
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
"""


def patch_sources():
    os.makedirs(XML_DIR, exist_ok=True)
    with open(os.path.join(XML_DIR, "file_paths.xml"), "w", encoding="utf-8") as f:
        f.write(FILE_PATHS)
    # flutter create の MainActivity は同じ場所に出来るので上書きする
    os.makedirs(KOTLIN_DIR, exist_ok=True)
    for name in os.listdir(KOTLIN_DIR):
        if name.endswith(".kt"):
            os.remove(os.path.join(KOTLIN_DIR, name))
    with open(os.path.join(KOTLIN_DIR, "MainActivity.kt"), "w", encoding="utf-8") as f:
        f.write(MAIN_ACTIVITY)
    print("kotlin / xml: 作成しました")


INIT = """allprojects {
    afterEvaluate { p ->
        if (p.hasProperty('android')) {
            try {
                p.android { compileSdkVersion 36 }
            } catch (Throwable t) {
                println("compileSdk 変更を skip: " + p.name)
            }
        }
    }
}
"""


def patch_gradle_init():
    d = os.path.expanduser("~/.gradle/init.d")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "compilesdk.gradle"), "w", encoding="utf-8") as f:
        f.write(INIT)
    print("gradle init: compileSdk を揃える設定を作成しました")


patch_manifest()
patch_sources()
patch_gradle_init()
