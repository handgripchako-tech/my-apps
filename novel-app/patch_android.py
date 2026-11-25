#!/usr/bin/env python3
"""flutter create で作った android/ に、ノベルリーダーに必要な設定を足す。
(GitHub Actions から novel-app/ で実行する)
 - 通信(INTERNET)・http接続(Tailscale経由)の許可
 - アプリ名を「ノベル」に
 - 部品(プラグイン)の compileSdk を 36 に揃える Gradle 初期スクリプト
 - アプリアイコンを icons/ があれば差し替え（なければ標準のまま）
"""
import glob
import os
import re
import shutil
import sys

MANIFEST = "android/app/src/main/AndroidManifest.xml"


def patch_manifest():
    s = open(MANIFEST, encoding="utf-8").read()
    if "android.permission.INTERNET" in s and "usesCleartextTraffic" in s:
        print("manifest: すでに設定済み")
        return
    if s.count("<application") != 1:
        sys.exit("manifest: <application> の位置が想定と違います")
    perm = '<uses-permission android:name="android.permission.INTERNET"/>'
    if "android.permission.INTERNET" in s:
        perm = ""
    s = s.replace(
        "<application",
        perm + '\n    <application android:usesCleartextTraffic="true"',
        1,
    )
    s = re.sub(r'android:label="[^"]*"', 'android:label="ノベル"', s, count=1)
    # 新しい描画方式(Impeller)を切る（一部の端末で画面が灰色になる・チカチカするため）
    if "EnableImpeller" not in s:
        s = re.sub(
            r"(<application[^>]*>)",
            r'\1\n        <meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false"/>',
            s,
            count=1,
        )
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


def patch_icons():
    res = "android/app/src/main/res"
    n = 0
    for d in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
        src = "icons/ic_launcher_%s.png" % d
        if not os.path.exists(src):
            continue
        dst_dir = "%s/mipmap-%s" % (res, d)
        os.makedirs(dst_dir, exist_ok=True)
        shutil.copyfile(src, dst_dir + "/ic_launcher.png")
        n += 1
    if n == 0:
        print("icon: icons/ がないので標準アイコンのまま")
        return
    # 新しい Flutter が作る適応アイコン(xml)があると PNG より優先されるので消す
    for f in glob.glob(res + "/mipmap-anydpi*/ic_launcher*.xml"):
        os.remove(f)
    print("icon: %d 個の解像度を差し替えました" % n)


patch_manifest()
patch_gradle_init()
patch_icons()
