#!/usr/bin/env python3
"""main.dart に PMD 追加機能を足す。
 - import 'pmd.dart';
 - MusicHandler に addPmdFiles() を追加
 - リストのメニューに「PMD（PC-98）を追加」を追加
目印が1つでも違えば何も書き換えずに止まる。2回実行しても二重に入らない。
使い方: cd ~/music-app && python3 patch_pmd_dart.py
"""
import sys

PATH = "lib/main.dart"

IMPORT_ANCHOR = "import 'package:path_provider/path_provider.dart';\n"
IMPORT_NEW = "import 'pmd.dart';\n"

METHOD_ANCHOR = "  Future<void> delItem(String plId, String u) async {"
METHOD_NEW = """  // PMD(PC-98のFM音源曲)を選んで、WAVに変換していまのリストに追加する。
  // 音色ファイル(.PPC/.P86 とドラムの 2608_*.WAV)も一緒に選べば、アプリ内に保存される。
  Future<void> addPmdFiles() async {
    try {
      final r = await FilePicker.platform
          .pickFiles(type: FileType.any, allowMultiple: true);
      if (r == null) return;
      final pd = off.phoneDir;
      if (pd == null) {
        toast('保存場所を用意できません');
        return;
      }
      const companionExts = {'ppc', 'p86', 'pzi', 'pvi', 'pps', 'ppz', 'wav'};
      final songs = <PlatformFile>[];
      var saved = 0;
      for (final f in r.files) {
        final src = f.path;
        if (src == null) continue;
        final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
        if (Pmd.isSong(f.name)) {
          songs.add(f);
        } else if (companionExts.contains(ext)) {
          await Pmd.saveCompanion(src, f.name);
          saved++;
        }
      }
      final items = <Item>[];
      var fail = 0;
      String? lastErr;
      for (var i = 0; i < songs.length; i++) {
        final f = songs[i];
        toast('PMDを変換中 ${i + 1}/${songs.length}: ${f.name}');
        final path = await Pmd.saveSong(f.path!, f.name);
        final fn = '${_hash('pmd|${f.name}|${f.size}')}.wav';
        final err = await Pmd.toWav(path, '${pd.path}/$fn');
        if (err != null) {
          fail++;
          lastErr = err;
          continue;
        }
        items.add(Item(u: _uid(), p: 'local:$fn', m: null, t: _stem(f.name)));
      }
      if (items.isNotEmpty) addItems(items);
      if (fail > 0) {
        toast('$fail曲を変換できませんでした: $lastErr');
      } else if (items.isEmpty && saved > 0) {
        toast('音色ファイル$saved個を保存しました');
      } else if (items.isEmpty) {
        toast('PMDの曲が選ばれていません');
      }
    } catch (e) {
      toast('PMDを追加できませんでした');
    }
  }

"""

MENU_ANCHOR = "          mi(c, 'スマホ内のファイルを追加', 'phone'),\n"
MENU_NEW = "          mi(c, 'PMD（PC-98）を追加', 'pmd'),\n"

BRANCH_ANCHOR = "    } else if (a == 'phone') {\n      h.addPhoneFiles();\n"
BRANCH_NEW = "    } else if (a == 'pmd') {\n      h.addPmdFiles();\n"


def main():
    s = open(PATH, encoding="utf-8").read()
    if "addPmdFiles" in s:
        print("すでに設定済みです。何もしません")
        return
    for name, anchor in [("import", IMPORT_ANCHOR), ("メソッド", METHOD_ANCHOR),
                         ("メニュー", MENU_ANCHOR), ("分岐", BRANCH_ANCHOR)]:
        n = s.count(anchor)
        if n != 1:
            sys.exit("目印が見つからない/複数あります: %s (%d個)。何も変更していません" % (name, n))
    s = s.replace(IMPORT_ANCHOR, IMPORT_ANCHOR + IMPORT_NEW, 1)
    s = s.replace(METHOD_ANCHOR, METHOD_NEW + METHOD_ANCHOR, 1)
    s = s.replace(MENU_ANCHOR, MENU_NEW + MENU_ANCHOR, 1)
    s = s.replace(BRANCH_ANCHOR, BRANCH_ANCHOR + BRANCH_NEW, 1)
    open(PATH, "w", encoding="utf-8").write(s)
    print("main.dart に PMD 追加機能を入れました")


if __name__ == "__main__":
    main()
