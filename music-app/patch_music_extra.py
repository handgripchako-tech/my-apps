# -*- coding: utf-8 -*-
"""
music-app 用の追加パッチ (CI で patch_android.py の後に実行。何度実行しても安全)
  - 権限 (INTERNET / 通知 / フォアグラウンドサービス) が無ければ追加
  - http:// のサーバーでも再生できるように usesCleartextTraffic を有効化
  - アプリ名を MUSIC に
  - audio_service の service / receiver / MainActivity が無ければ追加
"""
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
BASES = [HERE, os.getcwd(), os.path.join(os.getcwd(), "music-app")]


def find(rel):
    for b in BASES:
        hits = glob.glob(os.path.join(b, rel), recursive=True)
        if hits:
            return hits[0]
    return None


def patch_manifest():
    p = find("android/app/src/main/AndroidManifest.xml")
    if not p:
        print("[extra] AndroidManifest.xml が見つかりません")
        return
    s = open(p, encoding="utf-8").read()
    orig = s

    # 権限
    perms = [
        "android.permission.INTERNET",
        "android.permission.WAKE_LOCK",
        "android.permission.FOREGROUND_SERVICE",
        "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
        "android.permission.POST_NOTIFICATIONS",
    ]
    add = ""
    for pm in perms:
        if pm not in s:
            add += '    <uses-permission android:name="%s" />\n' % pm
    if add:
        s = re.sub(r"(\s*)<application\b", lambda m: "\n" + add + "    <application", s, count=1)

    # application タグ
    m = re.search(r"<application\b[^>]*>", s)
    if m:
        tag = m.group(0)
        new = tag
        if "usesCleartextTraffic" not in new:
            new = new.replace("<application", '<application android:usesCleartextTraffic="true"', 1)
        if re.search(r'android:label="[^"]*"', new):
            new = re.sub(r'android:label="[^"]*"', 'android:label="MUSIC"', new, count=1)
        else:
            new = new.replace("<application", '<application android:label="MUSIC"', 1)
        s = s.replace(tag, new, 1)

    # audio_service の service / receiver
    if "com.ryanheise.audioservice.AudioService" not in s:
        svc = (
            '        <service android:name="com.ryanheise.audioservice.AudioService"\n'
            '            android:foregroundServiceType="mediaPlayback"\n'
            '            android:exported="true">\n'
            '            <intent-filter>\n'
            '                <action android:name="android.media.browse.MediaBrowserService" />\n'
            '            </intent-filter>\n'
            '        </service>\n'
        )
        s = s.replace("</application>", svc + "    </application>", 1)
    if "com.ryanheise.audioservice.MediaButtonReceiver" not in s:
        rcv = (
            '        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"\n'
            '            android:exported="true">\n'
            '            <intent-filter>\n'
            '                <action android:name="android.intent.action.MEDIA_BUTTON" />\n'
            '            </intent-filter>\n'
            '        </receiver>\n'
        )
        s = s.replace("</application>", rcv + "    </application>", 1)

    if s != orig:
        open(p, "w", encoding="utf-8").write(s)
        print("[extra] AndroidManifest.xml を更新しました")
    else:
        print("[extra] AndroidManifest.xml は変更なし")


def patch_activity():
    p = find("android/app/src/main/**/MainActivity.*")
    if not p:
        print("[extra] MainActivity が見つかりません")
        return
    s = open(p, encoding="utf-8").read()
    if "AudioServiceActivity" in s:
        print("[extra] MainActivity は変更なし")
        return
    s = s.replace("import io.flutter.embedding.android.FlutterActivity",
                  "import com.ryanheise.audioservice.AudioServiceActivity")
    s = s.replace("FlutterActivity()", "AudioServiceActivity()")
    open(p, "w", encoding="utf-8").write(s)
    print("[extra] MainActivity を AudioServiceActivity に変更しました")


ICONS = {
    "mdpi": "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAAqElEQVR42u1YSQ6AIBCrxlfAZ3w6n4Fv6IWDkchilBlIe/Eyh9qWdDIAkccSv97Lc7EWwKpNoS3lKICLP8oV6p+nxJMhFOqTpwcf1ClEQu8zlMURGgvB0DJm6L4k7ABgXHk07AAAR8tIiIRIiIRISL7LYit9OjmLQl20mWsfqtqEWidHfvbG1f5o/eSMGfotN6yOSTMkdJcdQiGpW+wICim456tTiCjhBJahHKOB/GX4AAAAAElFTkSuQmCC",
    "hdpi": "iVBORw0KGgoAAAANSUhEUgAAAEgAAABICAIAAADajyQQAAAA0UlEQVR42u3bQQ7CIBBGYWo8RXsZj97LtNfQha0sjEaxKky/fwObWbzMYxJISEmkinR5O00RgIbhuh6idiws2PFJN1vK3TmiYgQVG5qTj08NFUOpWO2cfOGMUBEYMGBfnIrv5DxvdKHqdQwYMGARpmKXTsuuH0vq57U8jToGDBgwYMCAAQMGDBgwYMDi3KDzhfcf5VSkYq0GUtG7Yk7Zc+JW5VTcm4o3Ycrm24flVKRirTOQisCAAfvpVGzwrwEVQ6nY4s8CKkZSMcR/KyqKSFEueL8daVy/Dn4AAAAASUVORK5CYII=",
    "xhdpi": "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAABDElEQVR42u3cQQ6CMBAF0KnxFHAZj85l4Bq6U1hoMBZb2vdXuuni5XcyCYQIEZFySZt/80wkImIcnz8vND4HEKDfct1zD7vIm/mrQa4YoEIzqIf9aMec1SBAgCqYQS3tR1/OUw0CBAgQIECA7EE5cl+OPT8NGuSKAQIECJAAqnMPSnF7/RmmPIcuqzNj0iBXDBAgQIAEECBAgAABAgQIEAJAgAABAgQIECCJvz0X2zyrqvhMDQIEqJ0Z1NDc0SBAgNp8PyjbO0FHn6lBgACdbwatZ0Gu/eWIMzUIEKD296AT7jsaBAgQIECAANmDotfvmWkQIED1zqDevuuqQYAAlZ9Bvm+vQYAAiYi0nQcWsh2VIcNPrQAAAABJRU5ErkJggg==",
    "xxhdpi": "iVBORw0KGgoAAAANSUhEUgAAAJAAAACQCAIAAABoJHXvAAABYElEQVR42u3cQQqDMBBA0bF4CnOZHt3LxGu0+6hQisaEvLfsxuJnwhBoIwAAoDQdfJaz99KKlIoPXt5JXwQTDMEQrFfzf7sKt/hhPzdhjkQEQzDBaGhLdN8YNe4JTZgjEcEQTDC63xLdNz60V5swRyKCIZhgCIZggiEYgglG9H6XeJvP1tb3mRYThmCCIRiCCYZgCCYYgiFYuEuMFv+s511+tKz1Hr/tnh6rCUMwwRAMwQRDMAQTDMEQTDAEQzDBEAzBEEwwBEMwwRAMwQRDMAQTDMEQTDAEQzDBEIzo9DfOB78gHubpJsyRiGAIJhi2RDuhCXMkIhiCCYYt8Vo1/x2xtaebMEcigiGYYIywJe43rpr3e88+3YQ5EhEMwQTDluie0IQhmGAIhmCCIRiCCYZgCBbuEk/k7G2aMAQTDMEQbPQtMSXvzoQhmGAIhmCjb4nuCU0YggmGYAgGAACj+wJDBR3tf+PHKgAAAABJRU5ErkJggg==",
    "xxxhdpi": "iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAIAAADdvvtQAAAB1UlEQVR42u3dOwqDQBSG0d+QVTibydLdjG4jaQJptJCEzMNzyqQZ5OMKlwETAAAAAK5gOvxnXT0dPkrZ/fnmyfANASEgBISAEBAIiH+6/2ofwCBO7v9MILzCEBACQkAgIARExt0Dxf2hDHy/xwTCKwwBISAQEAJCQMQeKHX3DaTJ/ZwJhIAQEAJCQCAgBISAEBAICAEhIAQEAkJA5Fr3gSp5bn2ff5pNILzCQEAICAEhIBAQAkJACAgEhIAQEAJCQBD3gd6mPPb/mJe2DrodnDNLTCC8wkBACAgBISAQEAJCQAgIBISAEBACQkAgIASEgBAQCAgBISAEBAJCQAgIAYGAEBACQkAICASEgBAQAgIBISAEhIBAQAgIASEgEBACQkDE98JS+7tazmkCISAEBAJCQAgIAUF63APZ95hACAgEhIAQEAICAZFL3wc6a16c0wRCQAgIBISAEBACgjS8Bzrai7R2/6aXc5pACAgBgYAQEAJCQJDO7gO532MCISAQEAJCQAgIAXkECAgBISAEBAJCQAgIAUGq3wdaV0/ZBAIBISAEhIBAQAiIDLQHKsXTNIFAQAgIASEgEBACIgPtgdzvwQRCQAgIASEgEBACAgAAAABa9QKQAR5F8Z8GpgAAAABJRU5ErkJggg==",
}


def patch_icon():
    """ギャラリーと別のランチャーアイコン (PC98風ピクセルの音符) を書き込む"""
    import base64
    res = find("android/app/src/main/res")
    if not res:
        print("[extra] res フォルダが見つかりません (アイコン変更なし)")
        return
    for d, b64 in ICONS.items():
        folder = os.path.join(res, "mipmap-" + d)
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "ic_launcher.png"), "wb") as f:
            f.write(base64.b64decode(b64))
    for x in glob.glob(os.path.join(res, "mipmap-anydpi*", "ic_launcher*.xml")):
        os.remove(x)
    print("[extra] ランチャーアイコンを更新しました")


def patch_sdk():
    """依存ライブラリが compileSdk 36 以上を求めるので、アプリ側の compileSdk を 36 に上げる"""
    p = find("android/app/build.gradle*")
    if not p:
        print("[extra] build.gradle が見つかりません (compileSdk 変更なし)")
        return
    s = open(p, encoding="utf-8").read()
    n, cnt = re.subn(r"(compileSdk(?:Version)?)(\s*=\s*|\s+)flutter\.compileSdkVersion",
                     r"\g<1>\g<2>36", s)
    if cnt == 0:
        m = re.search(r"compileSdk(?:Version)?\s*=?\s*(\d+)", s)
        if m and int(m.group(1)) >= 36:
            print("[extra] compileSdk は既に %s です" % m.group(1))
        else:
            print("[extra] compileSdk の行が見つかりません。build.gradle を確認してください")
        return
    open(p, "w", encoding="utf-8").write(n)
    print("[extra] compileSdk を 36 に変更しました: " + os.path.basename(p))


INIT_GRADLE = """// music-app: ライブラリ(プラグイン)も含め、全部の compileSdk を 36 に上げる
allprojects {
    afterEvaluate { p ->
        def a = p.extensions.findByName('android')
        if (a != null) {
            try {
                a.compileSdkVersion(36)
            } catch (Throwable t) {
                println "[music] compileSdk 変更失敗: ${p.name}: ${t}"
            }
        }
    }
}
"""


def patch_gradle_init():
    """部品側が compileSdk 34 のままだと、新しい依存でビルドが落ちるため、Gradle の初期スクリプトで全部 36 に揃える"""
    home = os.environ.get("GRADLE_USER_HOME") or os.path.join(os.path.expanduser("~"), ".gradle")
    d = os.path.join(home, "init.d")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "music-compile-sdk.gradle")
    with open(p, "w", encoding="utf-8") as f:
        f.write(INIT_GRADLE)
    print("[extra] Gradle 初期スクリプトを書きました: " + p)


patch_manifest()
patch_activity()
patch_icon()
patch_sdk()
patch_gradle_init()
