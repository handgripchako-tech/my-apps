#!/usr/bin/env python3
"""PMD再生用のネイティブ部分(native/)を、flutter create で作った android/ に組み込む。
(GitHub Actions から music-app/ で実行する。patch_android.py の後)
 - native/ を android/app/src/main/cpp にコピー
 - android/app/build.gradle(.kts) に CMake の設定を追加
"""
import os
import shutil
import sys

SRC = "native"
DST = "android/app/src/main/cpp"
GRADLE_KTS = "android/app/build.gradle.kts"
GRADLE_GROOVY = "android/app/build.gradle"

KTS_BLOCK = """
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
"""
GROOVY_BLOCK = """
    externalNativeBuild {
        cmake {
            path "src/main/cpp/CMakeLists.txt"
        }
    }
"""


def copy_native():
    if not os.path.isdir(SRC):
        sys.exit("native/ が見つかりません")
    if os.path.isdir(DST):
        shutil.rmtree(DST)
    shutil.copytree(SRC, DST)
    n = sum(len(f) for _, _, f in os.walk(DST))
    print("native: %d ファイルを %s にコピーしました" % (n, DST))


def patch_gradle():
    path = GRADLE_KTS if os.path.exists(GRADLE_KTS) else GRADLE_GROOVY
    if not os.path.exists(path):
        sys.exit("build.gradle が見つかりません")
    s = open(path, encoding="utf-8").read()
    if "externalNativeBuild" in s:
        print("gradle: すでに設定済み " + path)
        return
    block = KTS_BLOCK if path.endswith(".kts") else GROOVY_BLOCK
    key = "android {"
    if s.count(key) != 1:
        sys.exit("gradle: 'android {' の位置が想定と違います (%d個)" % s.count(key))
    s = s.replace(key, key + block, 1)
    open(path, "w", encoding="utf-8").write(s)
    print("gradle: CMake設定を追加しました " + path)


if __name__ == "__main__":
    copy_native()
    patch_gradle()
