import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'disk.dart';
import 'pmd_page.dart';
import 'sjis.dart';
import 'zip.dart';

void main() => runApp(const DiskViewerApp());

class DiskViewerApp extends StatelessWidget {
  const DiskViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PC98ディスクビューア',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
      ),
      home: const HomePage(),
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String fmtSize(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
}

String fmtTime(DateTime? t) => t == null
    ? ''
    : '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

String extOf(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

const _imageExts = ['bmp', 'png', 'jpg', 'jpeg', 'gif', 'webp'];
const _textExts = [
  'txt', 'doc', 'me', 'asc', 'bat', 'c', 'h', 'asm', 'bas', 'cfg', 'sys', 'ini', 'hlp', 'inf', 'lst', 'mac', 'src', 'sh'
];

// ---------------------------------------------------------------------- Home

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Disk? disk;
  List<Volume> vols = [];
  int vi = 0;
  final List<DirEntry> stack = [];
  List<DirEntry> entries = [];
  final Set<int> selected = {};
  String fileName = '';
  String? error;
  bool busy = false;

  Fat? get _fat => vols.isEmpty ? null : vols[vi].fat;
  int get _cluster => stack.isEmpty ? 0 : stack.last.cluster;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _reload() {
    final fat = _fat;
    if (fat == null) {
      entries = [];
      selected.clear();
      return;
    }
    final l = fat.list(_cluster);
    l.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    entries = l;
    selected.clear();
  }

  String get _pathText {
    final head = vols.isEmpty ? '' : vols[vi].name;
    return '$head:/${stack.map((e) => e.name).join('/')}';
  }

  bool get _canEdit => disk?.writable == true && _fat != null;

  Future<bool> _confirm(String msg, {String ok = 'OK'}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    );
    return r == true;
  }

  Future<String?> _askText(String title, String initial) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('OK')),
        ],
      ),
    );
  }

  /// 書き込み操作を実行して一覧を更新する
  void _edit(void Function(Fat fat) body, String okMsg) {
    final fat = _fat;
    final d = disk;
    if (fat == null || d == null) return;
    try {
      body(fat);
      d.modified = true;
      setState(_reload);
      _snack(okMsg);
    } on FormatException catch (e) {
      setState(_reload);
      _snack(e.message);
    } catch (e) {
      setState(_reload);
      _snack('失敗しました: $e');
    }
  }

  Future<void> _deleteSelected() async {
    final items = (selected.toList()..sort()).map((i) => entries[i]).toList();
    if (items.isEmpty) return;
    final what = items.length == 1 ? '「${items.first.name}」' : '${items.length}件';
    final dirNote = items.any((e) => e.isDir) ? '\nフォルダは中身ごと消えます。' : '';
    if (!await _confirm('$whatを削除しますか？$dirNote\n（ディスクイメージを保存するまで、元のファイルは変わりません）', ok: '削除')) {
      return;
    }
    _edit((fat) {
      for (final e in items) {
        fat.delete(e);
      }
    }, '削除しました');
  }

  Future<void> _renameSelected() async {
    if (selected.length != 1) return;
    final e = entries[selected.first];
    final n = await _askText('名前を変える（8.3形式）', e.name);
    if (n == null || n.trim().isEmpty || n == e.name) return;
    _edit((fat) => fat.rename(e, n), '名前を変えました');
  }

  List<MapEntry<String, int>> _allFolders(Fat fat) {
    final out = <MapEntry<String, int>>[const MapEntry('/', 0)];
    void walk(int c, String path, int depth) {
      if (depth > 8 || out.length > 400) return;
      for (final e in fat.list(c)) {
        if (!e.isDir) continue;
        final p = '$path${e.name}/';
        out.add(MapEntry(p, e.cluster));
        walk(e.cluster, p, depth + 1);
      }
    }

    walk(0, '/', 0);
    return out;
  }

  Future<void> _moveSelected() async {
    final fat = _fat;
    if (fat == null) return;
    final items = (selected.toList()..sort()).map((i) => entries[i]).toList();
    if (items.isEmpty) return;
    final folders = _allFolders(fat);
    final dest = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移動先のフォルダ'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: ListView(children: [
            for (final f in folders)
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder),
                title: Text(f.key),
                enabled: f.value != _cluster,
                onTap: () => Navigator.pop(c, f.value),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('やめる'))],
      ),
    );
    if (dest == null) return;
    _edit((fat) {
      for (final e in items) {
        fat.move(e, dest);
      }
    }, '移動しました');
  }

  String _suggest(String name) {
    final i = name.lastIndexOf('.');
    String clean(String t, int max) {
      final u = t.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_]'), '');
      return u.length > max ? u.substring(0, max) : u;
    }

    final b = clean(i < 0 ? name : name.substring(0, i), 8);
    final x = i < 0 ? '' : clean(name.substring(i + 1), 3);
    return x.isEmpty ? b : '$b.$x';
  }

  Future<void> _addFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (r == null) return;
    final cluster = _cluster;
    for (final f in r.files) {
      final p = f.path;
      if (p == null) continue;
      final data = File(p).readAsBytesSync();
      var name = f.name;
      while (Fat.make83(name) == null) {
        if (!mounted) return;
        final n = await _askText('「${f.name}」は8.3形式にできません。DOS用の名前を入力', _suggest(name));
        if (n == null) {
          name = '';
          break;
        }
        name = n;
      }
      if (name.isEmpty) continue;
      final nm = name;
      _edit((fat) => fat.addFile(cluster, nm, data), '追加しました: $nm');
    }
  }

  /// 選んだファイルを起動する AUTOEXEC.BAT をルートに作る（あれば上書き）
  Future<void> _makeAutoexec() async {
    final fat = _fat;
    if (fat == null || selected.length != 1) return;
    final e = entries[selected.first];
    if (e.isDir) {
      _snack('ファイルを1つ選んでください');
      return;
    }
    final dot = e.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : e.name.substring(dot + 1).toUpperCase();
    final run = (ext == 'EXE' || ext == 'COM' || ext == 'BAT') ? e.name.substring(0, dot) : e.name;
    final lines = <String>['@echo off'];
    if (stack.isNotEmpty) lines.add('cd \\${stack.map((x) => x.name).join('\\')}');
    lines.add(run);
    final ctl = TextEditingController(text: lines.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('AUTOEXEC.BAT を作る'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('ディスクのいちばん上に作ります（同名があれば上書き）。内容は直せます。',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: ctl,
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('作る')),
        ],
      ),
    );
    if (ok != true) return;
    final text = ctl.text.replaceAll('\r\n', '\n').trimRight().replaceAll('\n', '\r\n') + '\r\n';
    final data = sjisEncode(text);
    if (data == null) {
      _snack('Shift-JIS にできない文字が含まれています');
      return;
    }
    final old = fat.list(0).where((x) => !x.isDir && x.name.toUpperCase() == 'AUTOEXEC.BAT');
    _edit((f) {
      if (old.isNotEmpty) {
        f.replaceFile(old.first, data);
      } else {
        f.addFile(0, 'AUTOEXEC.BAT', data);
      }
    }, 'AUTOEXEC.BAT を作りました');
  }

  Future<void> _newFolder() async {
    final n = await _askText('新しいフォルダ名（8.3形式）', '');
    if (n == null || n.trim().isEmpty) return;
    final cluster = _cluster;
    _edit((fat) => fat.mkdir(cluster, n), 'フォルダを作りました');
  }

  Future<void> _saveImage() async {
    final d = disk;
    final img = d?.image;
    if (d == null || img == null) return;
    final p = await FilePicker.platform.saveFile(
      dialogTitle: '編集したディスクイメージの保存先',
      fileName: fileName,
      bytes: img,
    );
    if (p != null) {
      d.modified = false;
      if (mounted) setState(() {});
      _snack('保存しました: $fileName');
    }
  }

  Future<void> _pick() async {
    if (disk?.modified == true &&
        !await _confirm('保存していない変更があります。破棄して別のイメージを開きますか？', ok: '破棄して開く')) {
      return;
    }
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    if (r == null || r.files.isEmpty) return;
    final f = r.files.single;
    final path = f.path;
    if (path == null) {
      _snack('ファイルを取得できませんでした');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      final d = openDisk(path);
      final v = findVolumes(d);
      disk?.close();
      disk = d;
      vols = v;
      vi = 0;
      stack.clear();
      fileName = f.name;
      _reload();
    } catch (e) {
      error = e is FormatException ? e.message : '$e';
      _snack('開けませんでした: $error');
    }
    if (mounted) setState(() => busy = false);
  }

  void _goUp() {
    setState(() {
      if (selected.isNotEmpty) {
        selected.clear();
      } else if (stack.isNotEmpty) {
        stack.removeLast();
        _reload();
      }
    });
  }

  void _onTap(int i) {
    final e = entries[i];
    if (selected.isNotEmpty) {
      setState(() => selected.contains(i) ? selected.remove(i) : selected.add(i));
      return;
    }
    if (e.isDir) {
      setState(() {
        stack.add(e);
        _reload();
      });
    } else {
      final fat = _fat!;
      final data = fat.readFile(e);
      var cur = e;
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PreviewPage(
          name: e.name,
          bytes: data,
          onSave: !_canEdit
              ? null
              : (b) async {
                  try {
                    fat.replaceFile(cur, b);
                    cur = fat.list(cur.parent).firstWhere((x) => x.entryOff == cur.entryOff);
                    disk!.modified = true;
                    setState(_reload);
                    return null;
                  } on FormatException catch (x) {
                    return x.message;
                  } catch (x) {
                    return '$x';
                  }
                },
        ),
      ));
    }
  }

  Future<void> _saveBytes(String name, Uint8List bytes) async {
    final p = await FilePicker.platform.saveFile(
      dialogTitle: '保存先',
      fileName: name,
      bytes: bytes,
    );
    if (p != null) _snack('保存しました: $name');
  }

  void _addToZip(ZipWriter z, Fat fat, DirEntry e, String prefix, int depth) {
    if (depth > 32) return;
    if (e.isDir) {
      final dir = '$prefix${e.name}/';
      final kids = fat.list(e.cluster);
      if (kids.isEmpty) z.addDir(dir, e.time);
      for (final k in kids) {
        _addToZip(z, fat, k, dir, depth + 1);
      }
    } else {
      z.add('$prefix${e.name}', fat.readFile(e), e.time);
    }
  }

  Future<void> _saveZip(List<DirEntry> items, String zipName) async {
    final fat = _fat;
    if (fat == null) return;
    setState(() => busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    try {
      final z = ZipWriter();
      for (final e in items) {
        _addToZip(z, fat, e, '', 0);
      }
      await _saveBytes(zipName, z.finish());
    } catch (e) {
      _snack('保存に失敗しました: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  String get _baseName {
    final i = fileName.lastIndexOf('.');
    return i > 0 ? fileName.substring(0, i) : fileName;
  }

  Future<void> _saveSelected() async {
    final fat = _fat;
    if (fat == null) return;
    final items = (selected.toList()..sort()).map((i) => entries[i]).toList();
    if (items.length == 1 && !items.first.isDir) {
      await _saveBytes(items.first.name, fat.readFile(items.first));
    } else {
      await _saveZip(items, '${items.length == 1 ? items.first.name : _baseName}.zip');
    }
    if (mounted) setState(selected.clear);
  }

  Future<void> _saveFolder() => _saveZip(
      List<DirEntry>.of(_fat!.list(_cluster)),
      '${stack.isEmpty ? _baseName : stack.last.name}.zip');

  Future<void> _saveAll() =>
      _saveZip(List<DirEntry>.of(_fat!.list(0)), '$_baseName.zip');

  void _openPmd() {
    final d = disk;
    if (d == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PmdPage(disk: d, vols: vols, baseName: _baseName),
      ),
    );
  }

  void _showInfo() {
    final d = disk;
    if (d == null) return;
    final lines = <String>[
      'ファイル: $fileName',
      '形式: ${d.format}',
      '構成: ${d.geometry}',
      '容量: ${fmtSize(d.src.length)}',
    ];
    final fat = _fat;
    if (fat != null) {
      lines.addAll([
        '',
        'ボリューム: ${vols[vi].name}',
        if (fat.label.isNotEmpty) 'ラベル: ${fat.label}',
        'ファイルシステム: FAT${fat.bits}',
        'クラスタ: ${fmtSize(fat.clusterBytes)} x ${fat.clusters}',
        '空き: ${fmtSize(fat.freeClusters() * fat.clusterBytes)} / ${fmtSize(fat.totalBytes)}',
      ]);
    }
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ディスク情報'),
        content: SingleChildScrollView(child: SelectableText(lines.join('\n'))),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('閉じる')),
        ],
      ),
    );
  }

  void _showBootSector() {
    final d = disk;
    if (d == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PreviewPage(
        name: '先頭4KB',
        bytes: d.src.read(0, 4096),
        initialMode: PreviewMode.hex,
      ),
    ));
  }

  IconData _iconFor(DirEntry e) {
    if (e.isDir) return Icons.folder;
    final x = extOf(e.name);
    if (_imageExts.contains(x)) return Icons.image;
    if (_textExts.contains(x)) return Icons.description;
    if (const ['exe', 'com', 'bat'].contains(x)) return Icons.settings_applications;
    return Icons.insert_drive_file;
  }

  @override
  Widget build(BuildContext context) {
    final selecting = selected.isNotEmpty;
    return PopScope(
      canPop: stack.isEmpty && !selecting && disk?.modified != true,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (selected.isNotEmpty || stack.isNotEmpty) {
          _goUp();
          return;
        }
        if (await _confirm('保存していない変更があります。破棄して終了しますか？', ok: '破棄して終了')) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        appBar: selecting
            ? AppBar(
                leading: IconButton(icon: const Icon(Icons.close), onPressed: _goUp),
                title: Text('${selected.length}件選択'),
                actions: [
                  IconButton(
                    tooltip: 'すべて選択',
                    icon: const Icon(Icons.select_all),
                    onPressed: () => setState(() {
                      for (var i = 0; i < entries.length; i++) {
                        selected.add(i);
                      }
                    }),
                  ),
                  if (_canEdit) ...[
                    if (selected.length == 1 && !entries[selected.first].isDir)
                      IconButton(
                        tooltip: 'このファイルを自動起動にする（AUTOEXEC.BAT）',
                        icon: const Icon(Icons.play_circle_outline),
                        onPressed: busy ? null : _makeAutoexec,
                      ),
                    if (selected.length == 1)
                      IconButton(
                        tooltip: '名前を変える',
                        icon: const Icon(Icons.drive_file_rename_outline),
                        onPressed: busy ? null : _renameSelected,
                      ),
                    IconButton(
                      tooltip: '移動',
                      icon: const Icon(Icons.drive_file_move),
                      onPressed: busy ? null : _moveSelected,
                    ),
                    IconButton(
                      tooltip: '削除',
                      icon: const Icon(Icons.delete),
                      onPressed: busy ? null : _deleteSelected,
                    ),
                  ],
                  IconButton(
                    tooltip: '保存',
                    icon: const Icon(Icons.save_alt),
                    onPressed: busy ? null : _saveSelected,
                  ),
                ],
              )
            : AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fileName.isEmpty ? 'PC98ディスクビューア' : '${disk?.modified == true ? '● ' : ''}$fileName',
                        style: const TextStyle(fontSize: 16), overflow: TextOverflow.ellipsis),
                    if (_fat != null)
                      Text(_pathText,
                          style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: 'イメージを開く',
                    icon: const Icon(Icons.folder_open),
                    onPressed: busy ? null : _pick,
                  ),
                  if (disk != null)
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        switch (v) {
                          case 'info':
                            _showInfo();
                          case 'folder':
                            _saveFolder();
                          case 'all':
                            _saveAll();
                          case 'boot':
                            _showBootSector();
                          case 'newfolder':
                            _newFolder();
                          case 'addfile':
                            _addFiles();
                          case 'saveimg':
                            _saveImage();
                          case 'pmd':
                            _openPmd();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'pmd', child: Text('PMD曲データを抜き出す')),
                        const PopupMenuItem(value: 'info', child: Text('ディスク情報')),
                        if (_fat != null) ...const [
                          PopupMenuItem(value: 'folder', child: Text('このフォルダをZIPで保存')),
                          PopupMenuItem(value: 'all', child: Text('ディスク全体をZIPで保存')),
                        ],
                        const PopupMenuItem(value: 'boot', child: Text('先頭セクタをHEX表示')),
                        if (_canEdit) ...const [
                          PopupMenuItem(value: 'addfile', child: Text('ファイルを追加')),
                          PopupMenuItem(value: 'newfolder', child: Text('新しいフォルダ')),
                          PopupMenuItem(value: 'saveimg', child: Text('ディスクイメージを保存')),
                        ] else
                          const PopupMenuItem(
                              enabled: false, child: Text('(このイメージは閲覧のみ)')),
                      ],
                    ),
                ],
              ),
        body: Stack(children: [
          _body(),
          if (busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _body() {
    if (disk == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.save, size: 72),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy ? null : _pick,
              icon: const Icon(Icons.folder_open),
              label: const Text('ディスクイメージを開く'),
            ),
            const SizedBox(height: 16),
            const Text('HDI / FDI / D88 / HDM など (FAT12・FAT16)',
                textAlign: TextAlign.center),
            if (error != null) ...[
              const SizedBox(height: 16),
              Text('開けませんでした: $error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center),
            ],
          ]),
        ),
      );
    }
    if (_fat == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.help_outline, size: 64),
            const SizedBox(height: 12),
            const Text(
                'FAT12/16 のファイルシステムが見つかりませんでした。\n(N88-BASIC形式・FAT32・暗号化などは未対応です)',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _showBootSector, child: const Text('先頭セクタをHEXで見る')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _showInfo, child: const Text('ディスク情報')),
          ]),
        ),
      );
    }
    return Column(children: [
      if (vols.length > 1)
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (var i = 0; i < vols.length; i++)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: ChoiceChip(
                    label: Text(vols[i].name),
                    selected: i == vi,
                    onSelected: (_) => setState(() {
                      vi = i;
                      stack.clear();
                      _reload();
                    }),
                  ),
                ),
            ],
          ),
        ),
      if (stack.isNotEmpty)
        ListTile(
          dense: true,
          leading: const Icon(Icons.arrow_upward),
          title: const Text('..'),
          onTap: _goUp,
        ),
      Expanded(
        child: entries.isEmpty
            ? const Center(child: Text('(空)'))
            : ListView.builder(
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final e = entries[i];
                  final sub = e.isDir
                      ? fmtTime(e.time)
                      : '${fmtSize(e.size)}   ${fmtTime(e.time)}';
                  return ListTile(
                    leading: Icon(_iconFor(e)),
                    title: Text(e.name),
                    subtitle: Text(sub),
                    selected: selected.contains(i),
                    onTap: () => _onTap(i),
                    onLongPress: () => setState(() =>
                        selected.contains(i) ? selected.remove(i) : selected.add(i)),
                  );
                },
              ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------- Preview

enum PreviewMode { text, hex, image }

class PreviewPage extends StatefulWidget {
  final String name;
  final Uint8List bytes;
  final PreviewMode? initialMode;

  /// 編集を保存する処理。失敗したらメッセージ、成功なら null を返す。null のときは編集不可。
  final Future<String?> Function(Uint8List bytes)? onSave;
  const PreviewPage(
      {super.key, required this.name, required this.bytes, this.initialMode, this.onSave});

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  late PreviewMode mode;
  late Uint8List _bytes = widget.bytes;

  @override
  void initState() {
    super.initState();
    mode = widget.initialMode ?? _guess();
  }

  PreviewMode _guess() {
    final x = extOf(widget.name);
    if (_imageExts.contains(x)) return PreviewMode.image;
    final n = _bytes.length < 2048 ? _bytes.length : 2048;
    var bad = 0;
    for (var i = 0; i < n; i++) {
      final b = _bytes[i];
      if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D && b != 0x1A && b != 0x1B) bad++;
    }
    if (n == 0 || bad == 0) return PreviewMode.text;
    return PreviewMode.hex;
  }

  Future<void> _edit() async {
    final text = sjisDecode(_bytes, stopAtEof: true).replaceAll('\r\n', '\n');
    final res = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(
      builder: (_) => EditPage(name: widget.name, text: text, onSave: widget.onSave!),
    ));
    if (res != null && mounted) setState(() => _bytes = res);
  }

  Future<void> _save() async {
    final p = await FilePicker.platform.saveFile(
      dialogTitle: '保存先',
      fileName: widget.name,
      bytes: _bytes,
    );
    if (p != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存しました: ${widget.name}')));
    }
  }

  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.3);

  Widget _content() {
    final bytes = _bytes;
    switch (mode) {
      case PreviewMode.image:
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.none,
              errorBuilder: (c, e, s) => const Padding(
                padding: EdgeInsets.all(24),
                child: Text('この形式は画像として表示できません'),
              ),
            ),
          ),
        );
      case PreviewMode.text:
        const limit = 256 * 1024;
        final cut = bytes.length > limit;
        final text = sjisDecode(cut ? bytes.sublist(0, limit) : bytes, stopAtEof: true);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SelectableText(cut ? '$text\n\n... (先頭256KBのみ表示)' : text, style: _mono),
        );
      case PreviewMode.hex:
        const limit = 64 * 1024;
        final len = bytes.length > limit ? limit : bytes.length;
        final rows = (len + 15) ~/ 16;
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: rows + (bytes.length > limit ? 1 : 0),
          itemBuilder: (_, r) {
            if (r == rows) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Text('... (先頭64KBのみ表示)'),
              );
            }
            final o = r * 16;
            final end = o + 16 > len ? len : o + 16;
            final hex = StringBuffer();
            final asc = StringBuffer();
            for (var i = o; i < o + 16; i++) {
              if (i < end) {
                hex.write(bytes[i].toRadixString(16).padLeft(2, '0'));
                final b = bytes[i];
                asc.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x2E);
              } else {
                hex.write('  ');
              }
              hex.write(i == o + 7 ? '  ' : ' ');
            }
            return Text('${o.toRadixString(16).padLeft(6, '0')}  $hex $asc', style: _mono);
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.name, style: const TextStyle(fontSize: 16)),
            Text(fmtSize(_bytes.length), style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          if (widget.onSave != null && mode == PreviewMode.text)
            IconButton(tooltip: '編集', icon: const Icon(Icons.edit), onPressed: _edit),
          IconButton(tooltip: '保存', icon: const Icon(Icons.save_alt), onPressed: _save),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<PreviewMode>(
            segments: const [
              ButtonSegment(value: PreviewMode.text, label: Text('テキスト')),
              ButtonSegment(value: PreviewMode.hex, label: Text('HEX')),
              ButtonSegment(value: PreviewMode.image, label: Text('画像')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setState(() => mode = s.first),
          ),
        ),
        Expanded(child: _content()),
      ]),
    );
  }
}

class EditPage extends StatefulWidget {
  final String name;
  final String text;
  final Future<String?> Function(Uint8List bytes) onSave;
  const EditPage({super.key, required this.name, required this.text, required this.onSave});

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final TextEditingController ctl = TextEditingController(text: widget.text);
  bool saving = false;

  void _msg(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _save() async {
    final t = ctl.text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
    final b = sjisEncode(t);
    if (b == null) {
      _msg('Shift-JIS にできない文字が含まれています');
      return;
    }
    setState(() => saving = true);
    final err = await widget.onSave(b);
    if (!mounted) return;
    setState(() => saving = false);
    if (err != null) {
      _msg(err);
    } else {
      Navigator.of(context).pop(b);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.name} を編集', style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'ディスクへ反映',
            icon: const Icon(Icons.check),
            onPressed: saving ? null : _save,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          controller: ctl,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.3),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
      ),
    );
  }
}
