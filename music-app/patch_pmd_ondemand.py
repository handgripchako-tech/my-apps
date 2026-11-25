#!/usr/bin/env python3
"""main.dart を「PMDは再生・解析のときだけWAVにする」方式に変える。
(先に patch_pmd_dart.py を当ててあること。lib/pmd.dart も新しい版に置き換えること)
目印が1つでも違えば何も書き換えずに止まる。2回実行しても二重に入らない。
使い方: cd ~/music-app && python3 patch_pmd_ondemand.py
"""
import sys

PATH = "lib/main.dart"

EDITS = []


def edit(name, old, new):
    EDITS.append((name, old, new))


# 1) Offline.has: PMD本体があれば「ある」扱い
edit("has",
     "  bool has(Item it) => it.isPhone ? localPath(it) != null : idx.containsKey(it.key);\n",
     "  bool has(Item it) => it.isPhone\n"
     "      ? (localPath(it) != null || Pmd.hasSrc(phoneDir, it.p.substring(6)))\n"
     "      : idx.containsKey(it.key);\n")

# 2) 音量測定: WAVが無ければ作って送り、終わったら消す
edit("measure",
     "        final path = localPath(it);\n"
     "        if (path == null) continue;\n"
     "        status = 'スマホ内の曲の音量を測定中';\n"
     "        h.notifyUi();\n"
     "        l = await h.api.uploadLufs(File(path), it.p.split('.').last);\n"
     "        if (l == null) break;\n",
     "        final fn0 = it.p.substring(6);\n"
     "        final had = localPath(it) != null;\n"
     "        final path = had ? localPath(it) : await Pmd.ensureWav(phoneDir, fn0);\n"
     "        if (path == null) continue;\n"
     "        status = 'スマホ内の曲の音量を測定中';\n"
     "        h.notifyUi();\n"
     "        l = await h.api.uploadLufs(File(path), it.p.split('.').last);\n"
     "        if (!had) await Pmd.dropWav(phoneDir, fn0);\n"
     "        if (l == null) break;\n")

# 3) ビジュアライザー解析: WAVが無ければ作る
edit("viz",
     "        final path = h.off.localPath(it);\n"
     "        if (path == null) return null;\n"
     "        b = await h.api.uploadViz(File(path), it.p.split('.').last);\n",
     "        final path = h.off.localPath(it) ??\n"
     "            await Pmd.ensureWav(h.off.phoneDir, it.p.substring(6));\n"
     "        if (path == null) return null;\n"
     "        b = await h.api.uploadViz(File(path), it.p.split('.').last);\n")

# 4) 次の曲の準備: PMDなら先にWAVを作っておく
edit("prepNext",
     "      if (it.u != nu) continue;\n"
     "      if (off.has(it)) break;\n",
     "      if (it.u != nu) continue;\n"
     "      if (it.isPhone) {\n"
     "        unawaited(Pmd.ensureWav(off.phoneDir, it.p.substring(6)));\n"
     "        break;\n"
     "      }\n"
     "      if (off.has(it)) break;\n")

# 5) 再生前: WAVが無ければ作る
edit("play-before",
     "      final local = off.localPath(it);\n"
     "      var g = 0.0;\n",
     "      if (it.isPhone &&\n"
     "          off.localPath(it) == null &&\n"
     "          Pmd.hasSrc(off.phoneDir, it.p.substring(6))) {\n"
     "        toast('PMDを変換中…');\n"
     "      }\n"
     "      if (it.isPhone) await Pmd.ensureWav(off.phoneDir, it.p.substring(6));\n"
     "      final local = off.localPath(it);\n"
     "      var g = 0.0;\n")

# 6) 再生開始後: 古いWAVを消す
edit("play-after",
     "      unawaited(player.play());\n"
     "      _pushState();\n"
     "      _notify();\n"
     "      _prepNext();\n",
     "      unawaited(player.play());\n"
     "      _pushState();\n"
     "      _notify();\n"
     "      unawaited(Pmd.trim(off.phoneDir, it.p.substring(6)));\n"
     "      _prepNext();\n")

# 7) 追加時: 変換せず、PMD本体を保存するだけにする
edit("add",
     "      for (var i = 0; i < songs.length; i++) {\n"
     "        final f = songs[i];\n"
     "        toast('PMDを変換中 ${i + 1}/${songs.length}: ${f.name}');\n"
     "        final path = await Pmd.saveSong(f.path!, f.name);\n"
     "        final fn = '${_hash('pmd|${f.name}|${f.size}')}.wav';\n"
     "        final err = await Pmd.toWav(path, '${pd.path}/$fn');\n"
     "        if (err != null) {\n"
     "          fail++;\n"
     "          lastErr = err;\n"
     "          continue;\n"
     "        }\n"
     "        items.add(Item(u: _uid(), p: 'local:$fn', m: null, t: _stem(f.name)));\n"
     "      }\n",
     "      for (var i = 0; i < songs.length; i++) {\n"
     "        final f = songs[i];\n"
     "        if (!await Pmd.probe(f.path!)) {\n"
     "          fail++;\n"
     "          lastErr = 'PMDとして読めませんでした';\n"
     "          continue;\n"
     "        }\n"
     "        final stem = _hash('pmd|${f.name}|${f.size}');\n"
     "        try {\n"
     "          await Pmd.addSource(pd, f.path!, stem);\n"
     "        } catch (_) {\n"
     "          fail++;\n"
     "          lastErr = '保存できませんでした';\n"
     "          continue;\n"
     "        }\n"
     "        items.add(Item(u: _uid(), p: 'local:$stem.wav', m: null, t: _stem(f.name)));\n"
     "      }\n")


def main():
    s = open(PATH, encoding="utf-8").read()
    if "Pmd.ensureWav" in s:
        print("すでに設定済みです。何もしません")
        return
    for name, old, new in EDITS:
        n = s.count(old)
        if n != 1:
            sys.exit("目印が見つからない/複数あります: %s (%d個)。何も変更していません" % (name, n))
    for name, old, new in EDITS:
        s = s.replace(old, new, 1)
    open(PATH, "w", encoding="utf-8").write(s)
    print("main.dart を変更しました(%d か所)" % len(EDITS))


if __name__ == "__main__":
    main()
