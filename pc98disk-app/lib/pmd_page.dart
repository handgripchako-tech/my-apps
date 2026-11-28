// ディスクイメージから PMD の曲データ（と PCM・音色・MML）を探して取り出す画面。
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'archive.dart';
import 'disk.dart';
import 'main.dart' show fmtSize;
import 'pmd.dart';
import 'zip.dart';

enum PmdKind { file, embed, lzss, raw, pcm, mml, driver }

const _kindLabel = {
  PmdKind.file: '曲ファイル',
  PmdKind.embed: '埋め込み',
  PmdKind.lzss: 'LZSS展開',
  PmdKind.raw: 'ディスク直読み',
  PmdKind.pcm: 'PCM・音色',
  PmdKind.mml: 'MML',
  PmdKind.driver: 'ドライバ',
};

const _kindColor = {
  PmdKind.file: Colors.teal,
  PmdKind.embed: Colors.orange,
  PmdKind.lzss: Colors.purple,
  PmdKind.raw: Colors.brown,
  PmdKind.pcm: Colors.blueGrey,
  PmdKind.mml: Colors.indigo,
  PmdKind.driver: Colors.red,
};

class PmdHit {
  final PmdKind kind;
  final String source; // 見つかった場所（ファイルのパス）
  final int offset; // そのファイル内の位置
  final Uint8List data;
  final String name; // 保存するときの名前
  final PmdInfo? info;
  bool selected = true;
  PmdHit(this.kind, this.source, this.offset, this.data, this.name, this.info);

  bool get isSong => kind != PmdKind.pcm && kind != PmdKind.mml && kind != PmdKind.driver;
}

class PmdPage extends StatefulWidget {
  final Disk disk;
  final List<Volume> vols;
  final String baseName;
  const PmdPage({super.key, required this.disk, required this.vols, required this.baseName});

  @override
  State<PmdPage> createState() => _PmdPageState();
}

class _PmdPageState extends State<PmdPage> {
  final List<PmdHit> hits = [];
  final Set<String> _seen = {};
  bool scanning = false;
  bool _cancel = false;
  int files = 0;
  String current = '';
  bool rawMode = false;

  /// Claude に調べてもらう資料：見たファイルの一覧と、音楽ドライバらしいファイルの中身
  final List<String> _log = [];
  final Map<String, Uint8List> _keep = {};
  int _keepBytes = 0;

  @override
  void initState() {
    super.initState();
    _start(raw: widget.vols.isEmpty);
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _yield() async {
    if (mounted) setState(() {});
    await Future<void>.delayed(Duration.zero);
  }

  // ------------------------------------------------------------ 探す

  Future<void> _start({required bool raw}) async {
    setState(() {
      hits.clear();
      _seen.clear();
      _log.clear();
      _keep.clear();
      _falDrv = null;
      _keepBytes = 0;
      files = 0;
      current = '';
      scanning = true;
      rawMode = raw;
      _cancel = false;
    });
    try {
      if (raw) {
        await _scanRaw();
      } else {
        for (final v in widget.vols) {
          if (_cancel) break;
          final pre = widget.vols.length > 1 ? '${v.name}:/' : '';
          await _walk(v.fat, 0, pre, 0);
        }
      }
    } catch (e) {
      _snack('途中で失敗しました: $e');
    }
    final drv = _falDrv;
    if (drv != null) _add(PmdHit(PmdKind.driver, _falDrvPath, 0, drv, 'FALOPNA.DRV', null));
    if (!mounted) return;
    setState(() {
      scanning = false;
      current = '';
    });
    final songs = hits.where((h) => h.isSong).length;
    _snack('曲 $songs 件、付属ファイル ${hits.length - songs} 件 見つかりました');
    if (songs == 0 && !_cancel && !rawMode && _log.isNotEmpty && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('曲データが見つかりませんでした'),
          content: const Text('このゲームの音楽の形式を Claude に調べてもらうための資料（ファイル一覧と、音楽ドライバらしいファイル）をまとめて共有しますか？\n\n共有先で Claude アプリを選んでください。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('しない')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('共有する')),
          ],
        ),
      );
      if (ok == true) await _shareReport();
    }
  }

  static const _keys = [
    'DRIVER', 'Driver', 'driver', 'MUSIC', 'Music', 'SOUND', 'Sound', 'OPN', 'YM2', 'PMD',
    'FMP', 'MML', 'PSG', 'synthia', 'BGM', 'MIDI', 'Version', 'VERSION', 'Copyright', '(C)', '(c)'
  ];

  static String _hexHead(Uint8List d) {
    final n = d.length < 32 ? d.length : 32;
    return [for (var i = 0; i < n; i++) d[i].toRadixString(16).padLeft(2, '0')].join(' ');
  }

  /// 調べたファイルを資料に書き留める
  void _note(String path, Uint8List d) {
    final n = d.length < 0x10000 ? d.length : 0x10000;
    final txt = latin1.decode(Uint8List.sublistView(d, 0, n));
    final hit = <String>[for (final k in _keys) if (txt.contains(k)) k];
    _log.add('$path\t${d.length}\t${_hexHead(d)}${hit.isEmpty ? '' : '\t[${hit.join(',')}]'}');
    final ext = _ext(path);
    final base = path.split('/').last.toUpperCase();
    // MS-DOS 本体などは音楽と関係ないので入れない
    const dos = {'IO.SYS', 'MSDOS.SYS', 'COMMAND.COM', 'HIMEM.SYS', 'EMM386.EXE', 'DBLSPACE.BIN', 'DRVSPACE.BIN'};
    if (dos.contains(base) || txt.contains('Microsoft')) return;
    final exe = const {'COM', 'EXE', 'BIN', 'SYS', 'DRV', 'X', 'R'}.contains(ext);
    final strong = hit.any((k) => const {'DRIVER', 'Driver', 'driver', 'MUSIC', 'Music', 'OPN', 'YM2', 'PMD', 'FMP', 'synthia', 'BGM', 'SOUND', 'Sound', 'MIDI'}.contains(k));
    void keep(String name, Uint8List x) {
      if (_keepBytes + x.length > 8 * 1024 * 1024) return;
      _keep[name] = x;
      _keepBytes += x.length;
    }

    if (d.length <= 0x10000 && (strong || exe)) {
      keep(path, d);
    } else if (strong) {
      // 大きいファイル：先頭（目次があることが多い）と、言葉が見つかった辺りを入れる
      keep('$path.head64k', Uint8List.fromList(Uint8List.sublistView(d, 0, n)));
    } else {
      // それ以外：形式を見分けるため先頭 4KB だけ
      final m = d.length < 4096 ? d.length : 4096;
      keep('$path.head4k', Uint8List.fromList(Uint8List.sublistView(d, 0, m)));
    }
  }

  Future<void> _shareReport() async {
    final z = ZipWriter();
    final sb = StringBuffer()
      ..writeln('PC98ディスクビューア 調査資料')
      ..writeln('ディスク: ${widget.baseName}')
      ..writeln('形式: ${widget.disk.format}  ${widget.disk.geometry}')
      ..writeln('調べたファイル: ${_log.length} 個 / 中身を同梱: ${_keep.length} 個')
      ..writeln('見つかったもの: ${hits.map((h) => h.name).join(', ')}')
      ..writeln()
      ..writeln('パス\t大きさ\t先頭32バイト\t含まれていた言葉');
    for (final l in _log) {
      sb.writeln(l);
    }
    z.add('README.txt', Uint8List.fromList(const Utf8Encoder().convert(sb.toString())));
    final used = <String>{};
    for (final e in _keep.entries) {
      var nm = 'files/${e.key.replaceAll(':', '_')}';
      var k = 2;
      while (!used.add(nm.toUpperCase())) {
        nm = 'files/${e.key.replaceAll(':', '_')}_$k';
        k++;
      }
      z.add(nm, e.value);
    }
    final dir = Directory('${Directory.systemTemp.path}/report');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final f = File('${dir.path}/${widget.baseName}_調査資料.zip');
    f.writeAsBytesSync(z.finish(), flush: true);
    await Share.shareXFiles(
      [XFile(f.path, mimeType: 'application/zip')],
      text: 'PC98ディスクビューアで「${widget.baseName}」の曲データが見つかりませんでした。'
          'この資料（ファイル一覧と音楽ドライバらしいファイル）から、音楽の形式を調べてください。',
    );
  }

  void _add(PmdHit h) {
    if (h.data.isEmpty) return;
    final key = '${h.data.length}:${ZipWriter.crc32(h.data)}';
    if (!_seen.add(key)) return; // 同じ中身は1つだけ
    hits.add(h);
  }

  Future<void> _walk(Fat fat, int cluster, String path, int depth) async {
    if (depth > 32 || _cancel) return;
    List<DirEntry> list;
    try {
      list = fat.list(cluster);
    } catch (_) {
      return;
    }
    for (final e in list) {
      if (_cancel) return;
      if (e.isDir) {
        if (e.cluster >= 2 && e.cluster != cluster) {
          await _walk(fat, e.cluster, '$path${e.name}/', depth + 1);
        }
      } else {
        await _file(fat, e, '$path${e.name}');
      }
    }
  }

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toUpperCase();
  }

  static String _stem(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  static String _hex(int n) => n.toRadixString(16).toUpperCase().padLeft(5, '0');

  Future<void> _file(Fat fat, DirEntry e, String path) async {
    files++;
    current = path;
    if (files % 3 == 0) await _yield();
    if (e.size == 0 || e.size > 32 * 1024 * 1024) return;
    Uint8List d;
    try {
      d = fat.readFile(e);
    } catch (_) {
      return;
    }
    await _bytes(path, e.name, d, 0);
  }

  /// 文字列が入っているか（先頭 64KB だけ見る）
  static bool _has(Uint8List d, String str) {
    final p = str.codeUnits;
    final n = d.length < 0x10000 ? d.length : 0x10000;
    for (var i = 0; i + p.length <= n; i++) {
      var k = 0;
      while (k < p.length && d[i + k] == p[k]) {
        k++;
      }
      if (k == p.length) return true;
    }
    return false;
  }

  /// WM / PAI の曲（PMD以外のドライバの曲）
  static const _otherSongExts = {'WM', 'PAI', 'FAL'};

  /// ファルコムの音楽ドライバ（いちばん大きい OPNA 版を最後に1つだけ入れる）
  Uint8List? _falDrv;
  String _falDrvPath = '';

  Future<void> _bytes(String path, String name, Uint8List d, int depth, {String? fal}) async {
    // まとめファイル（FA1 / silky's DISK）なら中身を1つずつ調べる
    final arc = depth < 2 ? openArchive(d) : null;
    if (arc != null) {
      for (final en in arc.entries) {
        if (_cancel) return;
        files++;
        current = '$path/${en.name}';
        if (files % 3 == 0) await _yield();
        Uint8List x;
        try {
          x = en.read();
        } catch (_) {
          continue;
        }
        final arcStem = _stem(name);
        await _bytes('$path/${en.name}', en.name, x, depth + 1,
            fal: arc.kind == 'AFLB' ? '${arcStem}_${_stem(en.name)}' : null);
      }
      return;
    }
    _note(path, d);
    // ファルコム（AFLB の中）の曲とドライバ
    if (fal != null) {
      if (isFalcomSong(d)) {
        _add(PmdHit(PmdKind.file, path, 0, d, '$fal.FAL', null));
        return;
      }
      if (isFalcomDriver(d)) {
        if (_falDrv == null || d.length > _falDrv!.length) {
          _falDrv = d;
          _falDrvPath = path;
        }
        return;
      }
    }
    final ext = _ext(name);
    // WM・PAI の曲は、ゲームの音楽ドライバと組で鳴らす
    if (const {'COM', 'BIN', 'EXE'}.contains(ext) &&
        d.length < 0x10000 &&
        (_has(d, 'MUSIC DRIVER') || _has(d, 'synthia'))) {
      _add(PmdHit(PmdKind.driver, path, 0, d, name, null));
      return;
    }
    if (_otherSongExts.contains(ext)) {
      _add(PmdHit(PmdKind.file, path, 0, d, name, null));
      return;
    }
    if (pmdPcmExts.contains(ext)) {
      _add(PmdHit(PmdKind.pcm, path, 0, d, name, null));
      return;
    }
    if (pmdMmlExts.contains(ext)) {
      _add(PmdHit(PmdKind.mml, path, 0, d, name, null));
      return;
    }
    final named = pmdSongExts.contains(ext);
    final found = scanPmd(d);
    if (named) {
      PmdInfo? head;
      for (final f in found) {
        if (f.start == 0) head = f;
      }
      _add(PmdHit(PmdKind.file, path, 0, d, name, head));
    }
    final stem = _stem(name);
    for (final f in found) {
      if (named && f.start == 0) continue;
      final kind = f.start == 0 ? PmdKind.file : PmdKind.embed;
      final nm = f.start == 0 ? '$stem.M' : '${stem}_${_hex(f.start)}.M';
      _add(PmdHit(kind, path, f.start, Uint8List.fromList(d.sublist(f.start, f.end)), nm, f));
    }
    if (found.isEmpty && !named && d.length >= 32 && d.length <= 2 * 1024 * 1024) {
      _tryLzss(d, path, stem);
    }
  }

  /// 圧縮されたファイルなら、展開してもう一度探す
  void _tryLzss(Uint8List d, String path, String stem) {
    final maxOut = (d.length * 16).clamp(4096, 4 * 1024 * 1024);
    for (final off in const [0, 2, 4]) {
      for (final fill in const [0x20, 0x00]) {
        final out = lzssDecode(d, off, maxOut, fill: fill);
        final fs = scanPmd(out);
        if (fs.isEmpty) continue;
        var k = 0;
        for (final f in fs) {
          k++;
          final nm = fs.length == 1 ? '${stem}_lz.M' : '${stem}_lz$k.M';
          _add(PmdHit(PmdKind.lzss, path, f.start,
              Uint8List.fromList(out.sublist(f.start, f.end)), nm, f));
        }
        return;
      }
    }
  }

  /// ファイルの区切りを使わず、ディスク全体を頭から調べる（独自形式のディスクや消したファイル向け）
  Future<void> _scanRaw() async {
    final src = widget.disk.src;
    const chunk = 1 << 20;
    const over = 0x10000;
    var k = 0;
    for (var pos = 0; pos < src.length && !_cancel; pos += chunk) {
      files = pos;
      current = 'ディスク直読み ${fmtSize(pos)} / ${fmtSize(src.length)}';
      await _yield();
      final buf = src.read(pos, chunk + over);
      final valid = (src.length - pos).clamp(0, chunk + over);
      final b = Uint8List.sublistView(buf, 0, valid);
      for (final f in scanPmd(b, to: chunk < valid ? chunk : valid)) {
        k++;
        final at = pos + f.start;
        _add(PmdHit(PmdKind.raw, 'ディスク', at, Uint8List.fromList(b.sublist(f.start, f.end)),
            '${widget.baseName}_${_hex(at)}.M', f));
      }
    }
    files = k;
  }

  // ------------------------------------------------------------ 保存

  Future<void> _saveOne(PmdHit h) async {
    final p = await FilePicker.platform.saveFile(
      dialogTitle: '保存先',
      fileName: h.name,
      bytes: h.data,
    );
    if (p != null) _snack('保存しました: ${h.name}');
  }

  Future<void> _saveZip() async {
    final sel = hits.where((h) => h.selected).toList();
    if (sel.isEmpty) {
      _snack('保存するものを選んでください');
      return;
    }
    final z = ZipWriter();
    final used = <String>{};
    for (final h in sel) {
      final dir = h.kind == PmdKind.pcm
          ? 'PCM/'
          : h.kind == PmdKind.mml
              ? 'MML/'
              : '';
      var nm = '$dir${h.name}';
      var n = 2;
      while (!used.add(nm.toUpperCase())) {
        nm = '$dir${_stem(h.name)}_$n.${_ext(h.name)}';
        n++;
      }
      z.add(nm, h.data);
    }
    final p = await FilePicker.platform.saveFile(
      dialogTitle: '保存先',
      fileName: '${widget.baseName}_PMD.zip',
      bytes: z.finish(),
    );
    if (p != null) _snack('${sel.length} 件をZIPで保存しました');
  }

  void _detail(PmdHit h) {
    final i = h.info;
    final rows = <String>[
      '種類: ${_kindLabel[h.kind]}',
      '場所: ${h.source}${h.offset > 0 ? '  (+0x${h.offset.toRadixString(16).toUpperCase()})' : ''}',
      '大きさ: ${fmtSize(h.data.length)}',
      if (i?.title != null) '曲名: ${i!.title}',
      if (i?.composer != null) '作曲: ${i!.composer}',
      if (i?.arranger != null) '編曲: ${i!.arranger}',
      if (i?.pcmFile != null) '使うPCM: ${i!.pcmFile}',
      if (i?.ppsFile != null) '使うPPS: ${i!.ppsFile}',
      if (i?.ppzFile != null) '使うPPZ: ${i!.ppzFile}',
      if (h.isSong && h.kind != PmdKind.file && i != null && !i.exactEnd)
        '※終わりの位置が分からなかったので、後ろに余分なデータが付いています（再生には影響しないことが多いです）',
      if (h.kind == PmdKind.file && i == null && pmdSongExts.contains(_ext(h.name)))
        '※中身がPMDの形式と一致しませんでした（名前だけで拾っています）',
      if (_otherSongExts.contains(_ext(h.name)))
        '※PMDではない曲です（${const {'WM': 'MUSIC.COM', 'PAI': 'S20S_4.BIN', 'FAL': 'FALOPNA.DRV'}[_ext(h.name)]} で鳴らす形式）。音楽アプリに入れるときは、一緒に見つかったドライバも選んでください',
      if (h.kind == PmdKind.driver) '※ゲームの音楽ドライバです。WM・PAI・FALの曲を音楽アプリで鳴らすのに使います',
    ];
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(h.name),
        content: SingleChildScrollView(
          child: SelectableText(rows.join('\n')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('閉じる')),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(c);
              _saveOne(h);
            },
            icon: const Icon(Icons.save_alt),
            label: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 画面

  @override
  Widget build(BuildContext context) {
    final nSel = hits.where((h) => h.selected).length;
    final allSel = hits.isNotEmpty && nSel == hits.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('PMD曲データ'),
        actions: [
          if (!scanning && hits.isNotEmpty)
            IconButton(
              tooltip: allSel ? '全部はずす' : '全部選ぶ',
              icon: Icon(allSel ? Icons.deselect : Icons.select_all),
              onPressed: () => setState(() {
                for (final h in hits) {
                  h.selected = !allSel;
                }
              }),
            ),
          if (!scanning)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'raw') _start(raw: true);
                if (v == 'files') _start(raw: false);
                if (v == 'share') _shareReport();
              },
              itemBuilder: (_) => [
                if (_log.isNotEmpty)
                  const PopupMenuItem(value: 'share', child: Text('Claude に調べてもらう（資料を共有）')),
                if (!rawMode || widget.vols.isEmpty)
                  const PopupMenuItem(value: 'raw', child: Text('ディスク全体を直接調べる（消したファイル・独自形式向け）')),
                if (rawMode && widget.vols.isNotEmpty)
                  const PopupMenuItem(value: 'files', child: Text('ファイルごとに調べ直す')),
              ],
            ),
        ],
      ),
      body: Column(children: [
        if (scanning) ...[
          const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              rawMode ? current : '$files 個目: $current',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
        Expanded(
          child: hits.isEmpty && !scanning
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      rawMode
                          ? '見つかりませんでした。'
                          : '見つかりませんでした。\n独自の圧縮をしているゲームかもしれません。\n右上のメニューの「ディスク全体を直接調べる」も試せます。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: hits.length,
                  itemBuilder: (_, i) => _tile(hits[i]),
                ),
        ),
      ]),
      bottomNavigationBar: scanning || hits.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: FilledButton.icon(
                  onPressed: nSel == 0 ? null : _saveZip,
                  icon: const Icon(Icons.archive),
                  label: Text('選んだ $nSel 件をZIPで保存'),
                ),
              ),
            ),
    );
  }

  Widget _tile(PmdHit h) {
    final i = h.info;
    final title = i?.title ?? h.name;
    final sub = <String>[
      '${title == h.name ? '' : '${h.name} ・ '}${fmtSize(h.data.length)}',
      h.source + (h.offset > 0 ? ' (+0x${h.offset.toRadixString(16).toUpperCase()})' : ''),
      if (i?.composer != null) '作曲: ${i!.composer}',
      if (i?.pcmFile != null) 'PCM: ${i!.pcmFile}',
    ];
    final color = _kindColor[h.kind]!;
    return ListTile(
      leading: Checkbox(
        value: h.selected,
        onChanged: (v) => setState(() => h.selected = v ?? false),
      ),
      title: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: color.withAlpha(90),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(_kindLabel[h.kind]!, style: const TextStyle(fontSize: 11)),
        ),
        Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      subtitle: Text(sub.join('\n'), style: const TextStyle(fontSize: 12)),
      isThreeLine: true,
      onTap: () => _detail(h),
    );
  }
}
