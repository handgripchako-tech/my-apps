#!/usr/bin/env python3
"""flutter create で作った android/ に、このアプリに必要な設定を足す。
(GitHub Actions から music-app/ で実行する)
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
    open(MANIFEST, "w", encoding="utf-8").write(s)
    print("manifest: 設定を追加しました")


def patch_activity():
    files = glob.glob("android/app/src/main/**/MainActivity.*", recursive=True)
    if not files:
        sys.exit("MainActivity が見つかりません")
    for f in files:
        s = open(f, encoding="utf-8").read()
        if "AudioServiceActivity" in s:
            print("activity: すでに設定済み " + f)
            continue
        n = s
        n = n.replace(
            "import io.flutter.embedding.android.FlutterActivity",
            "import com.ryanheise.audioservice.AudioServiceActivity",
        )
        n = re.sub(r"\bFlutterActivity\b", "AudioServiceActivity", n)
        if n == s:
            sys.exit("activity: 書き換え箇所が見つかりません " + f)
        open(f, "w", encoding="utf-8").write(n)
        print("activity: 変更しました " + f)


patch_manifest()
patch_activity()
