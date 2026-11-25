# -*- coding: utf-8 -*-
"""
音楽アプリ (music-app) を、今ある gallery-app のビルド設定を元に GitHub Actions でビルドできるようにする。
  - gallery-app の patch_android.py / release.jks (固定署名) を music-app にコピー
  - build-gallery-app.yml を元に build-music-app.yml を作る (gallery → music に置換)
  - .gitignore に !/music-app/ を追加
gallery-app 側は一切変更しない。何度実行しても安全。
"""
import os
import re
import shutil
import sys

HOME = os.path.expanduser("~")
G = os.path.join(HOME, "gallery-app")
M = os.path.join(HOME, "music-app")
WF_DIR = os.path.join(HOME, ".github", "workflows")
WF_SRC = os.path.join(WF_DIR, "build-gallery-app.yml")
WF_DST = os.path.join(WF_DIR, "build-music-app.yml")


def die(msg):
    sys.exit("エラー: " + msg)


def conv(s):
    for a, b in [("gallery-app", "music-app"), ("gallery_app", "music_app"),
                 ("gallery-latest", "music-latest"), ("Gallery", "Music"),
                 ("GALLERY", "MUSIC"), ("gallery", "music")]:
        s = s.replace(a, b)
    return s


if not os.path.isfile(os.path.join(M, "lib", "main.dart")):
    die("~/music-app/lib/main.dart がありません。先に music-app.tar.gz を展開してください")
if not os.path.isdir(G):
    die("~/gallery-app がありません")
if not os.path.isfile(WF_SRC):
    die("~/.github/workflows/build-gallery-app.yml がありません")

# 1) patch_android.py と署名キー
src = os.path.join(G, "patch_android.py")
if os.path.isfile(src):
    open(os.path.join(M, "patch_android.py"), "w", encoding="utf-8").write(
        conv(open(src, encoding="utf-8").read()))
    print("コピー: patch_android.py (gallery→music に置換)")
else:
    print("注意: gallery-app/patch_android.py が無いのでコピーしませんでした")
for name in os.listdir(G):
    p = os.path.join(G, name)
    if name.endswith(".jks") or name.endswith(".keystore") or name == "key.properties":
        shutil.copy(p, os.path.join(M, name))
        print("コピー:", name)

# 2) ワークフロー
# 署名まわり (パスワード・エイリアス・キー) の行は gallery の文字を書き換えない (ディレクトリ名だけ直す)
SENS = re.compile(r"pass|alias|\bks\b|--ks|keystore|jks|secrets\.|key", re.I)
kept = []


def conv_line(ln):
    if SENS.search(ln):
        new = ln.replace("gallery-app", "music-app").replace("gallery_app", "music_app")
        kept.append(new)
        return new
    return conv(ln)


lines = [conv_line(x) for x in open(WF_SRC, encoding="utf-8").read().split("\n")]
out, done = [], False
pat = re.compile(r"(python3?\s+)(\S*)patch_android\.py")
for ln in lines:
    m = pat.search(ln)
    if m and not done:
        extra = "%s%spatch_music_extra.py" % (m.group(1), m.group(2))
        st = ln.strip()
        if st.startswith("python"):  # run: | の中の1行 → 次の行に足す
            out.append(ln)
            out.append(ln[:len(ln) - len(ln.lstrip())] + extra)
        else:  # 1行にまとめて書かれている → その直後に && で足す
            out.append(ln[:m.end()] + " && " + extra + ln[m.end():])
        done = True
    else:
        out.append(ln)
text = "\n".join(out)
open(WF_DST, "w", encoding="utf-8").write(text)
print("作成: .github/workflows/build-music-app.yml")
if not done:
    print("注意: ワークフロー内に patch_android.py の実行行が見つかりません。"
          "次の行を patch_android.py の直後に足してください: python3 patch_music_extra.py")
try:
    import yaml
    yaml.safe_load(text)
    print("YAML 構文: OK")
except ImportError:
    print("YAML 構文: 未確認 (PyYAML なし)")
except Exception as e:  # noqa
    die("作ったワークフローの YAML が壊れています: %s" % e)

# 3) .gitignore
gi = os.path.join(HOME, ".gitignore")
cur = open(gi, encoding="utf-8").read() if os.path.exists(gi) else ""
if "!/music-app/" not in cur:
    with open(gi, "a", encoding="utf-8") as f:
        if cur and not cur.endswith("\n"):
            f.write("\n")
        f.write("!/music-app/\n")
    print(".gitignore に !/music-app/ を追加")

print("\n--- 署名まわりで gallery の文字を残した行 ---")
for k in kept:
    print("  " + k.rstrip())
print("\n--- 確認用 (ワークフローの music 関連行) ---")
for i, ln in enumerate(text.split("\n"), 1):
    if re.search(r"music|patch_", ln):
        print("%3d: %s" % (i, ln.rstrip()))
print("\n完了")
