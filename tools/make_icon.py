#!/usr/bin/env python3
"""アプリごとのアイコン（適応アイコン + 古い端末用PNG）を作って res/ に置く。

使い方（GitHub Actions の「flutter create」の後で）:
    python3 tools/make_icon.py <キー> <アプリ>/android/app/src/main/res [--label 文字]

- キーは SPECS のもの。なければ --label の1文字で作る（色はキーから自動）。
- 絵は Pillow で描くだけなので、画像ファイルをリポジトリに置く必要はない。
- 新しいアプリを作るときは SPECS に1行足す。
"""
import argparse
import glob
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

S = 864  # 前景を描く大きさ（最後に432へ縮小）
WHITE = (255, 255, 255, 255)
SOFT = (255, 255, 255, 150)


# ---------- 描画の小道具 ----------
def line(d, pts, w, fill=WHITE):
    d.line(pts, fill=fill, width=w, joint="curve")
    r = w / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def rrect(d, box, r, fill=None, outline=None, width=0):
    d.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


# ---------- 絵柄（864x864 の座標。中心は 432,432） ----------
def g_gallery(d):  # 写真の額縁 + 山 + 太陽
    rrect(d, (190, 220, 674, 644), 44, outline=WHITE, width=34)
    d.ellipse([500, 300, 580, 380], fill=WHITE)
    d.polygon([(235, 590), (360, 410), (440, 520), (500, 450), (630, 590)], fill=WHITE)


def g_memo(d):  # メモ用紙（折れ角 + 行）
    d.polygon([(230, 170), (560, 170), (650, 260), (650, 700), (230, 700)], fill=WHITE)
    d.polygon([(560, 170), (650, 260), (560, 260)], fill=(255, 255, 255, 120))
    for y in (350, 450, 550):
        line(d, [(290, y), (590, y)], 28, fill=(0, 0, 0, 70))


def g_monitor(d):  # 画面 + 脈拍の線
    rrect(d, (160, 210, 704, 600), 40, outline=WHITE, width=34)
    line(d, [(230, 410), (350, 410), (400, 300), (470, 520), (520, 410), (634, 410)], 28)
    line(d, [(432, 660), (432, 740)], 30)
    line(d, [(330, 745), (534, 745)], 30)


def g_novel(d):  # 開いた本
    d.polygon([(432, 300), (240, 260), (240, 640), (432, 680)], fill=WHITE)
    d.polygon([(432, 300), (624, 260), (624, 640), (432, 680)], fill=SOFT)
    for y in (350, 430, 510):
        line(d, [(285, y), (390, y + 15)], 18, fill=(0, 0, 0, 60))


def g_akaiito(d):  # 赤い糸（波の線 + 結び目の輪）
    pts = []
    for i in range(0, 101):
        t = i / 100
        x = 170 + 524 * t
        y = 432 + 150 * math.sin(t * 2 * math.pi * 1.0) * (1 - 0.25 * t)
        pts.append((x, y))
    line(d, pts, 26)
    for cx, cy in (pts[0], pts[-1]):
        d.ellipse([cx - 46, cy - 46, cx + 46, cy + 46], outline=WHITE, width=22)
    d.ellipse([432 - 34, 432 - 34, 432 + 34, 432 + 34], fill=WHITE)


def g_kana(d):  # 家 + ハート（おかえり）
    d.polygon([(432, 190), (690, 400), (640, 400), (640, 660), (224, 660), (224, 400), (174, 400)], fill=WHITE)
    heart = [(432, 600), (330, 500), (330, 450), (370, 420), (432, 470), (494, 420), (534, 450), (534, 500)]
    d.polygon(heart, fill=(0, 0, 0, 90))


def g_watamari(d):  # 重なる2つの輪（結ばれる）+ 星
    d.ellipse([170, 270, 520, 620], outline=WHITE, width=34)
    d.ellipse([344, 270, 694, 620], outline=WHITE, width=34)
    star = [(432, 300), (452, 360), (516, 360), (464, 398), (484, 460), (432, 422), (380, 460), (400, 398), (348, 360), (412, 360)]
    d.polygon(star, fill=(255, 255, 255, 230))


def g_store(d):  # 買い物袋 + 三角（ストア）
    d.polygon([(215, 300), (649, 300), (680, 690), (184, 690)], fill=WHITE)
    d.arc([320, 170, 544, 400], 180, 360, fill=WHITE, width=30)
    d.polygon([(385, 440), (385, 600), (520, 520)], fill=(0, 0, 0, 80))


def g_pc98disk(d):  # フロッピーディスク
    d.polygon([(200, 190), (600, 190), (664, 254), (664, 674), (200, 674)], fill=WHITE)
    rrect(d, (290, 190, 574, 330), 8, fill=(0, 0, 0, 80))
    rrect(d, (270, 440, 594, 674), 12, fill=(0, 0, 0, 60))
    rrect(d, (480, 215, 535, 305), 6, fill=WHITE)


def g_letter(d, label=""):  # 文字だけ（予備）
    f = None
    for p in glob.glob("/usr/share/fonts/**/NotoSansCJK-Bold.ttc", recursive=True) + \
             glob.glob("/usr/share/fonts/**/NotoSansCJK-Black.ttc", recursive=True):
        f = ImageFont.truetype(p, 360)
        break
    if f is None:
        f = ImageFont.load_default()
    d.text((432, 432), (label or "?")[0], font=f, fill=WHITE, anchor="mm")


# キー: (絵, 背景の色1, 背景の色2)
SPECS = {
    "gallery":  (g_gallery,  "#1F8A70", "#0B4F3F"),
    "memo":     (g_memo,     "#F2A93B", "#D2691E"),
    "monitor":  (g_monitor,  "#2A6FDB", "#14397A"),
    "novel":    (g_novel,    "#7B4FD6", "#3D2680"),
    "akaiito":  (g_akaiito,  "#E0364E", "#8A0F26"),
    "kana":     (g_kana,     "#F28AAE", "#C4457A"),
    "watamari": (g_watamari, "#7FA8F2", "#3B4FA0"),
    "store":    (g_store,    "#00A58E", "#006B8F"),
    "pc98disk": (g_pc98disk, "#5B6770", "#2C343A"),
}


def auto_colors(key):
    h = sum(ord(c) * (i + 3) for i, c in enumerate(key)) % 360
    import colorsys
    def rgb(hh, v):
        r, g, b = colorsys.hsv_to_rgb(hh / 360, 0.65, v)
        return "#%02X%02X%02X" % (int(r * 255), int(g * 255), int(b * 255))
    return rgb(h, 0.85), rgb((h + 25) % 360, 0.5)


def hexrgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


# ---------- 組み立て ----------
def make_bg(c1, c2, size=432):
    a, b = hexrgb(c1), hexrgb(c2)
    im = Image.new("RGB", (size, size))
    px = im.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    return im


def make_fg(glyph, label=""):
    # 864x864 のキャンバスに描いて 432 に縮小（きれいな縁にするため）
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    scaled = _Scaled(d, 1)
    if glyph is g_letter:
        glyph(scaled, label)
    else:
        glyph(scaled)
    # 適応アイコンは外側が丸などに切られるので、絵を中央に小さめ(72%)に置く
    k = int(S * 0.72)
    small = canvas.resize((k, k), Image.LANCZOS)
    full = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    full.paste(small, ((S - k) // 2, (S - k) // 2), small)
    return full.resize((432, 432), Image.LANCZOS)


class _Scaled:
    """座標を k 倍して ImageDraw に渡す薄いラッパ。"""

    def __init__(self, d, k):
        self.d, self.k = d, k

    def _p(self, v):
        if isinstance(v, (list, tuple)):
            if v and isinstance(v[0], (list, tuple)):
                return [tuple(c * self.k for c in p) for p in v]
            return [c * self.k for c in v]
        return v * self.k

    def line(self, pts, fill=None, width=0, joint=None):
        self.d.line(self._p(pts), fill=fill, width=int(width * self.k), joint=joint)

    def ellipse(self, box, fill=None, outline=None, width=0):
        self.d.ellipse(self._p(box), fill=fill, outline=outline, width=int(width * self.k))

    def polygon(self, pts, fill=None):
        self.d.polygon(self._p(pts), fill=fill)

    def arc(self, box, a0, a1, fill=None, width=0):
        self.d.arc(self._p(box), a0, a1, fill=fill, width=int(width * self.k))

    def rounded_rectangle(self, box, radius=0, fill=None, outline=None, width=0):
        self.d.rounded_rectangle(self._p(box), radius=radius * self.k, fill=fill,
                                 outline=outline, width=int(width * self.k))

    def text(self, xy, t, font=None, fill=None, anchor=None):
        self.d.text(self._p(xy), t, font=font, fill=fill, anchor=anchor)


def write_icons(res, bg, fg):
    os.makedirs(os.path.join(res, "drawable-nodpi"), exist_ok=True)
    bg.save(os.path.join(res, "drawable-nodpi", "ic_launcher_bg.png"))
    fg.save(os.path.join(res, "drawable-nodpi", "ic_launcher_fg.png"))

    # 新しい Flutter が作る適応アイコン(xml)は消して、自分のものに置き換える
    for f in glob.glob(os.path.join(res, "mipmap-anydpi*", "ic_launcher*.xml")):
        os.remove(f)
    d26 = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(d26, exist_ok=True)
    with open(os.path.join(d26, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@drawable/ic_launcher_bg"/>\n'
            '    <foreground android:drawable="@drawable/ic_launcher_fg"/>\n'
            '</adaptive-icon>\n')

    # 古い端末向け: 中央の72dp分を切り出して角丸に
    comp = bg.convert("RGBA")
    comp.alpha_composite(fg)
    comp = comp.crop((72, 72, 360, 360))
    for name, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        im = comp.resize((px, px), Image.LANCZOS)
        mask = Image.new("L", (px * 4, px * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, px * 4 - 1, px * 4 - 1), radius=px * 4 * 0.22, fill=255)
        im.putalpha(mask.resize((px, px), Image.LANCZOS))
        out = os.path.join(res, "mipmap-" + name)
        os.makedirs(out, exist_ok=True)
        im.save(os.path.join(out, "ic_launcher.png"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("key")
    ap.add_argument("res")
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    if a.key in SPECS:
        glyph, c1, c2 = SPECS[a.key]
        label = ""
    elif a.label:
        glyph = g_letter
        c1, c2 = auto_colors(a.key)
        label = a.label
    else:
        sys.exit("キー '%s' が SPECS にありません（--label で文字アイコンも作れます）" % a.key)
    write_icons(a.res, make_bg(c1, c2), make_fg(glyph, label))
    print("icon: %s を %s に作りました" % (a.key, a.res))


if __name__ == "__main__":
    main()
