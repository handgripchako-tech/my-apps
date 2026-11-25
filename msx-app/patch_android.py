#!/usr/bin/env python3
"""flutter create で作った android/ に、WebView 版の MainActivity・WebMSX・アイコンを入れる。"""
import re
import shutil
from pathlib import Path

root = Path(__file__).resolve().parent
main = root / "android" / "app" / "src" / "main"

# 1) WebMSX 本体（assets）
(main / "assets").mkdir(parents=True, exist_ok=True)
shutil.copy(root / "assets" / "msx.html", main / "assets" / "msx.html")

# 2) 既存の MainActivity（FlutterActivity 版）を消して差し替え
for p in list(main.rglob("MainActivity.*")):
    p.unlink()
kt = main / "kotlin" / "com" / "chako" / "msx_app" / "MainActivity.kt"
kt.parent.mkdir(parents=True, exist_ok=True)
shutil.copy(root / "MainActivity.kt", kt)

# 3) アプリ名
mf = main / "AndroidManifest.xml"
s = mf.read_text(encoding="utf-8")
s = re.sub(r'android:label="[^"]*"', 'android:label="MSX"', s, count=1)

# 4) 横向き固定（左右どちらの向きでも可）
if "screenOrientation" not in s:
    s = s.replace("<activity", '<activity android:screenOrientation="sensorLandscape"', 1)
mf.write_text(s, encoding="utf-8")
print("orientation: sensorLandscape")

# 5) 見た目・操作の調整（custom*.css / custom*.js）を assets の msx.html に差し込む
html_path = main / "assets" / "msx.html"
h = html_path.read_bytes()
css = "\n".join(p.read_text(encoding="utf-8") for p in sorted(root.glob("custom*.css")))
js = "\n".join(p.read_text(encoding="utf-8") for p in sorted(root.glob("custom*.js")))
block = ("<style>\n" + css + "\n</style>\n<script>\n" + js + "\n</script>\n").encode("utf-8")
i = h.rfind(b"</body>")
h = h[:i] + block + h[i:] if i >= 0 else h + block
html_path.write_bytes(h)
print("custom injected:", len(block), "bytes")

# 6) アイコン（青背景）。レガシー用PNG + 適応アイコン
res = main / "res"
for dpi in ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]:
    d = res / ("mipmap-" + dpi)
    d.mkdir(parents=True, exist_ok=True)
    shutil.copy(root / "icons" / ("legacy_" + dpi + ".png"), d / "ic_launcher.png")
d = res / "mipmap-xxxhdpi"
shutil.copy(root / "icons" / "foreground.png", d / "ic_launcher_foreground.png")
any26 = res / "mipmap-anydpi-v26"
any26.mkdir(parents=True, exist_ok=True)
(any26 / "ic_launcher.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/msx_icon_bg"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n', encoding="utf-8")
(res / "values").mkdir(parents=True, exist_ok=True)
(res / "values" / "msx_colors.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n    <color name="msx_icon_bg">#2424FE</color>\n</resources>\n', encoding="utf-8")
print("icons: ok")

print("patched:", kt)
print("assets:", html_path.stat().st_size, "bytes")
