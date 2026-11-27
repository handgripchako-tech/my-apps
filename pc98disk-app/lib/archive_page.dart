// まとめファイル（FA1 / silky's DISK）の中身を一覧で見る画面。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'archive.dart';
import 'main.dart' show PreviewPage, fmtSize;
import 'zip.dart';

class ArchivePage extends StatelessWidget {
  final String name;
  final Uint8List bytes;
  final Archive arc;
  const ArchivePage({super.key, required this.name, required this.bytes, required this.arc});

  void _snack(BuildContext c, String m) =>
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _open(BuildContext c, ArcEntry e) async {
    Uint8List d;
    try {
      d = e.read();
    } catch (x) {
      _snack(c, '取り出せませんでした: $x');
      return;
    }
    final sub = openArchive(d);
    await Navigator.of(c).push(MaterialPageRoute<void>(
      builder: (_) => sub != null
          ? ArchivePage(name: e.name, bytes: d, arc: sub)
          : PreviewPage(name: e.name, bytes: d),
    ));
  }

  Future<void> _saveOne(BuildContext c, ArcEntry e) async {
    try {
      final p = await FilePicker.platform
          .saveFile(dialogTitle: '保存先', fileName: e.name, bytes: e.read());
      if (p != null && c.mounted) _snack(c, '${e.name} を保存しました');
    } catch (x) {
      if (c.mounted) _snack(c, '保存できませんでした: $x');
    }
  }

  Future<void> _saveAll(BuildContext c) async {
    _snack(c, '展開しています…');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final z = ZipWriter();
    final used = <String>{};
    var bad = 0;
    for (final e in arc.entries) {
      var nm = e.name;
      var k = 2;
      while (!used.add(nm.toUpperCase())) {
        nm = '${e.name}_$k';
        k++;
      }
      try {
        z.add(nm, e.read());
      } catch (_) {
        bad++;
      }
    }
    final stem = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
    final p = await FilePicker.platform
        .saveFile(dialogTitle: '保存先', fileName: '$stem.zip', bytes: z.finish());
    if (p != null && c.mounted) {
      _snack(c, '${arc.entries.length - bad} 件をZIPで保存しました${bad > 0 ? '（$bad 件失敗）' : ''}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = arc.entries;
    return Scaffold(
      appBar: AppBar(
        title: Text(name, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'zip') _saveAll(context);
              if (v == 'raw') {
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => PreviewPage(name: name, bytes: bytes)));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'zip', child: Text('全部取り出してZIPで保存')),
              PopupMenuItem(value: 'raw', child: Text('まとめファイルそのものを見る')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.grey.withAlpha(40),
          child: Text('まとめファイル（${arc.kind}形式）  ${list.length} 件',
              style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (c, i) {
              final e = list[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(e.name),
                subtitle: Text('${fmtSize(e.size)}${e.packed ? '（圧縮）' : ''}'),
                onTap: () => _open(c, e),
                trailing: IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: '保存',
                  onPressed: () => _saveOne(c, e),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
