#!/usr/bin/env python3
"""flutter create で作った android/ に、メモアプリに必要な設定を足す。
(GitHub Actions から memo-app/ で実行する)
 - 通信(INTERNET)の許可
 - アプリ名を「メモ」に
 - 部品(プラグイン)の compileSdk を 36 に揃える Gradle 初期スクリプト
"""
import os
import re
import sys

MANIFEST = "android/app/src/main/AndroidManifest.xml"


def patch_manifest():
    s = open(MANIFEST, encoding="utf-8").read()
    if "android.permission.INTERNET" in s and 'android:label="メモ"' in s:
        print("manifest: すでに設定済み")
        return
    if s.count("<application") != 1:
        sys.exit("manifest: <application> の位置が想定と違います")
    if "android.permission.INTERNET" not in s:
        s = s.replace(
            "<application",
            '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
            1,
        )
    s = re.sub(r'android:label="[^"]*"', 'android:label="メモ"', s, count=1)
    open(MANIFEST, "w", encoding="utf-8").write(s)
    print("manifest: 設定を追加しました")


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
patch_gradle_init()
