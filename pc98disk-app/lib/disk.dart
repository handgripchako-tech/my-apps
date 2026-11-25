// PC-98 ディスクイメージ (HDI / FDI / D88 / 生イメージ) と FAT12/16 の解析。
// test/disk.js で検証済みのロジックを Dart に移したもの。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'sjis.dart';

const List<int> _secSizes = [128, 256, 512, 1024, 2048, 4096];

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xFFFFFFFF;

// ---------------------------------------------------------------- ByteSource

abstract class ByteSource {
  int get length;

  /// off から len バイト読む。範囲外は 0 で埋めて必ず len バイト返す。
  Uint8List read(int off, int len);

  /// off へ data を書く（書き込み不可の元なら例外）。
  void write(int off, Uint8List data);

  void close();
}

class FileSource implements ByteSource {
  final RandomAccessFile raf;
  @override
  final int length;
  FileSource(this.raf, this.length);

  @override
  Uint8List read(int off, int len) {
    final out = Uint8List(len);
    if (off < 0 || off >= length || len <= 0) return out;
    final n = math.min(len, length - off);
    raf.setPositionSync(off);
    final got = raf.readSync(n);
    out.setRange(0, got.length, got);
    return out;
  }

  @override
  void write(int off, Uint8List data) =>
      throw const FormatException('このイメージは書き込みできません');

  @override
  void close() => raf.closeSync();
}

class MemSource implements ByteSource {
  final Uint8List buf;
  MemSource(this.buf);

  @override
  void close() {}

  @override
  void write(int off, Uint8List data) {
    if (off < 0 || off + data.length > buf.length) {
      throw const FormatException('イメージの範囲外には書き込めません');
    }
    buf.setRange(off, off + data.length, data);
  }

  @override
  int get length => buf.length;

  @override
  Uint8List read(int off, int len) {
    final out = Uint8List(len);
    if (off < 0 || off >= buf.length || len <= 0) return out;
    final n = math.min(len, buf.length - off);
    out.setRange(0, n, buf, off);
    return out;
  }
}

class SubSource implements ByteSource {
  final ByteSource base;
  final int offset;
  @override
  final int length;
  SubSource(this.base, this.offset, this.length);

  @override
  void close() => base.close();

  @override
  void write(int off, Uint8List data) {
    if (off < 0 || off + data.length > length) {
      throw const FormatException('イメージの範囲外には書き込めません');
    }
    base.write(offset + off, data);
  }

  @override
  Uint8List read(int off, int len) {
    final out = Uint8List(len);
    if (off < 0 || off >= length || len <= 0) return out;
    final n = math.min(len, length - off);
    out.setRange(0, n, base.read(offset + off, n));
    return out;
  }
}

// ---------------------------------------------------------------------- Disk

class Disk {
  final String format; // HDI / FDI / D88 / RAW
  final ByteSource src; // ヘッダを除いたデータ部
  final int sectorSize;
  final int sectors; // 1トラックあたり (不明なら0)
  final int heads;
  final int cylinders;
  final bool isHdd;

  /// ファイル全体（ヘッダ込み）。メモリ上にあって編集できるときだけ非 null。
  Uint8List? image;

  /// 編集して未保存の変更があるか
  bool modified = false;

  bool get writable => image != null;

  Disk(this.format, this.src, this.sectorSize, this.sectors, this.heads,
      this.cylinders, this.isHdd);

  void close() => src.close();

  String get geometry => sectors > 0
      ? '$cylinders cyl x $heads head x $sectors sec x $sectorSize byte'
      : '$sectorSize byte/sector (ジオメトリ不明)';
}

Disk _parseAnex(ByteSource f, String format) {
  final h = f.read(0, 32);
  // HDI/FDI 共通: +8 ヘッダ長, +16 セクタ長, +20 sec, +24 head, +28 cyl
  const base = 4;
  final headSize = _u32(h, 4 + base);
  final secSize = _u32(h, 12 + base);
  final sectors = _u32(h, 16 + base);
  final heads = _u32(h, 20 + base);
  final cyl = _u32(h, 24 + base);
  if (!_secSizes.contains(secSize)) {
    throw FormatException('ヘッダのセクタサイズが不正です ($secSize)');
  }
  if (sectors < 1 ||
      sectors > 255 ||
      heads < 1 ||
      heads > 255 ||
      cyl < 1 ||
      cyl > 65535) {
    throw FormatException('ヘッダのジオメトリが不正です ($cyl/$heads/$sectors)');
  }
  if (headSize < 28 || headSize > f.length) {
    throw FormatException('ヘッダサイズが不正です ($headSize)');
  }
  return Disk(format, SubSource(f, headSize, f.length - headSize), secSize,
      sectors, heads, cyl, format == 'HDI');
}

class _D88Sec {
  final int r;
  final Uint8List data;
  _D88Sec(this.r, this.data);
}

Disk _parseD88(ByteSource f) {
  final hdr = f.read(0, 0x2B0);
  final diskSize = _u32(hdr, 0x1C);
  final limit = (diskSize > 0 && diskSize <= f.length) ? diskSize : f.length;
  final tracks = <List<_D88Sec>>[];
  var lastNonEmpty = -1;
  var secSize = 0;
  var spt = 0;
  for (var t = 0; t < 164; t++) {
    final off = _u32(hdr, 0x20 + t * 4);
    final secs = <_D88Sec>[];
    if (off != 0 && off + 16 <= limit) {
      var pos = off;
      var nsec = -1;
      var i = 0;
      while (pos + 16 <= limit && (nsec < 0 || i < nsec)) {
        final sh = f.read(pos, 16);
        if (nsec < 0) nsec = _u16(sh, 4);
        if (nsec == 0 || nsec > 64) break;
        final size = _u16(sh, 14);
        if (size == 0 || size > 8192 || pos + 16 + size > limit) break;
        secs.add(_D88Sec(sh[2], f.read(pos + 16, size)));
        pos += 16 + size;
        i++;
      }
    }
    if (secs.isNotEmpty) {
      lastNonEmpty = t;
      if (secSize == 0) {
        secSize = secs[0].data.length;
        spt = secs.length;
      }
    }
    tracks.add(secs);
  }
  if (lastNonEmpty < 0) {
    throw const FormatException('D88 にセクタがありません');
  }
  final flat = BytesBuilder(copy: false);
  var lastLen = 0;
  for (var t = 0; t <= lastNonEmpty; t++) {
    final secs = tracks[t];
    if (secs.isEmpty) {
      flat.add(Uint8List(lastLen));
      continue;
    }
    secs.sort((a, b) => a.r.compareTo(b.r));
    var len = 0;
    for (final s in secs) {
      flat.add(s.data);
      len += s.data.length;
    }
    lastLen = len;
  }
  return Disk('D88', MemSource(flat.takeBytes()), secSize, spt, 2,
      (lastNonEmpty + 2) ~/ 2, false);
}

/// これより大きいイメージはメモリに載せず、読み取り専用で開く
const int _maxEditable = 160 * 1024 * 1024;

/// path のイメージを開く。形式は拡張子と中身から判定。
/// HDI / FDI / 生イメージはメモリに読み込み、編集できる状態で返す。
Disk openDisk(String path) {
  final file = File(path);
  final name = path.split('/').last.toLowerCase();
  final ext = name.contains('.') ? name.split('.').last : '';
  final isD88 = const ['d88', '88d', 'd98', '98d', 'd68'].contains(ext);

  ByteSource f;
  Uint8List? image;
  if (!isD88 && file.lengthSync() <= _maxEditable) {
    image = file.readAsBytesSync();
    f = MemSource(image);
  } else {
    final raf = file.openSync();
    f = FileSource(raf, raf.lengthSync());
  }
  try {
    if (ext == 'hdi') return _parseAnex(f, 'HDI')..image = image;
    if (ext == 'fdi') return _parseAnex(f, 'FDI')..image = image;
    if (isD88) {
      final d = _parseD88(f);
      f.close(); // D88 は全部メモリに展開済み（読み取り専用）
      return d;
    }
  } catch (_) {
    f.close();
    rethrow;
  }
  // 生イメージ (hdm, dsk, img, xdf, dup, tfd ...)
  var ss = 512, spt = 0, heads = 0, cyl = 0;
  switch (f.length) {
    case 1261568:
      ss = 1024; spt = 8; heads = 2; cyl = 77;
      break;
    case 1228800:
      ss = 512; spt = 15; heads = 2; cyl = 80;
      break;
    case 737280:
      ss = 512; spt = 9; heads = 2; cyl = 80;
      break;
    case 1474560:
      ss = 512; spt = 18; heads = 2; cyl = 80;
      break;
  }
  return Disk('RAW', f, ss, spt, heads, cyl, false)..image = image;
}

// ----------------------------------------------------------------------- FAT

class DirEntry {
  final String name;
  final bool isDir;
  final int attr;
  final int cluster;
  final int size;
  final DateTime? time;

  /// このエントリ自身が置かれている位置（src 上のオフセット）と、親フォルダのクラスタ（0=ルート）
  final int entryOff;
  final int parent;
  DirEntry(this.name, this.isDir, this.attr, this.cluster, this.size, this.time,
      {this.entryOff = -1, this.parent = 0});
}

class Fat {
  final ByteSource src;
  final int start;
  final int bps, spc, reserved, nfats, rootEntries, spf, total, media;
  final int rootSectors, clusters, bits;
  final int rootOffset, dataOffset;
  final Uint8List fat;
  String label = '';

  Fat._(
      this.src,
      this.start,
      this.bps,
      this.spc,
      this.reserved,
      this.nfats,
      this.rootEntries,
      this.spf,
      this.total,
      this.media,
      this.rootSectors,
      this.clusters,
      this.bits,
      this.rootOffset,
      this.dataOffset,
      this.fat);

  static Fat? tryParse(ByteSource src, int start) {
    if (start < 0 || start + 512 > src.length) return null;
    final b = src.read(start, 512);
    final bps = _u16(b, 0x0B);
    final spc = b[0x0D];
    final res = _u16(b, 0x0E);
    final nf = b[0x10];
    final rootEnt = _u16(b, 0x11);
    final t16 = _u16(b, 0x13);
    final media = b[0x15];
    final spf = _u16(b, 0x16);
    final t32 = _u32(b, 0x20);
    if (!_secSizes.contains(bps)) return null;
    if (spc < 1 || spc > 128 || (spc & (spc - 1)) != 0) return null;
    if (res < 1 || nf < 1 || nf > 2 || rootEnt < 1 || spf < 1) return null;
    if ((media & 0xF0) != 0xF0) return null;
    final total = t16 != 0 ? t16 : t32;
    if (total < 1) return null;
    final rootSectors = (rootEnt * 32 + bps - 1) ~/ bps;
    final dataSectors = total - res - nf * spf - rootSectors;
    if (dataSectors < 1) return null;
    final clusters = dataSectors ~/ spc;
    int bits;
    if (clusters < 4085) {
      bits = 12;
    } else if (clusters < 65525) {
      bits = 16;
    } else {
      return null; // FAT32 は未対応
    }
    if (start + (res + nf * spf) * bps > src.length) return null;
    final rootOffset = start + (res + nf * spf) * bps;
    final dataOffset = rootOffset + rootSectors * bps;
    final fatBytes = src.read(start + res * bps, spf * bps);
    return Fat._(src, start, bps, spc, res, nf, rootEnt, spf, total, media,
        rootSectors, clusters, bits, rootOffset, dataOffset, fatBytes);
  }

  int next(int c) {
    if (bits == 12) {
      final o = c + (c >> 1);
      if (o + 1 >= fat.length) return 0xFFF;
      final w = fat[o] | (fat[o + 1] << 8);
      return (c & 1) == 0 ? (w & 0xFFF) : (w >> 4);
    }
    final o = c * 2;
    if (o + 1 >= fat.length) return 0xFFFF;
    return fat[o] | (fat[o + 1] << 8);
  }

  int get _eoc => bits == 12 ? 0xFF8 : 0xFFF8;
  int get clusterBytes => spc * bps;
  int get totalBytes => clusters * clusterBytes;

  List<int> chain(int c) {
    final out = <int>[];
    final seen = <int>{};
    while (c >= 2 && c < clusters + 2 && !seen.contains(c)) {
      seen.add(c);
      out.add(c);
      c = next(c);
      if (c >= _eoc) break;
    }
    return out;
  }

  Uint8List readCluster(int c) =>
      src.read(dataOffset + (c - 2) * clusterBytes, clusterBytes);

  Uint8List readChain(int c) {
    final bb = BytesBuilder(copy: false);
    for (final x in chain(c)) {
      bb.add(readCluster(x));
    }
    return bb.takeBytes();
  }

  Uint8List readFile(DirEntry e) {
    if (e.size == 0) return Uint8List(0);
    final all = readChain(e.cluster);
    return e.size >= all.length ? all : Uint8List.sublistView(all, 0, e.size);
  }

  /// cluster == 0 でルートディレクトリ。
  List<DirEntry> list(int cluster) {
    final dirChain = cluster == 0 ? const <int>[] : chain(cluster);
    final raw = cluster == 0
        ? src.read(rootOffset, rootEntries * 32)
        : () {
            final bb = BytesBuilder(copy: false);
            for (final x in dirChain) {
              bb.add(readCluster(x));
            }
            return bb.takeBytes();
          }();
    int offOf(int o) => cluster == 0
        ? rootOffset + o
        : dataOffset + (dirChain[o ~/ clusterBytes] - 2) * clusterBytes + (o % clusterBytes);
    final out = <DirEntry>[];
    for (var o = 0; o + 32 <= raw.length; o += 32) {
      final first = raw[o];
      if (first == 0x00) break;
      if (first == 0xE5) continue;
      final attr = raw[o + 11];
      if (attr == 0x0F) continue; // LFN
      if ((attr & 0x08) != 0) {
        if (cluster == 0) {
          label = sjisDecode(raw.sublist(o, o + 11)).trimRight();
        }
        continue;
      }
      final nm = Uint8List.fromList(raw.sublist(o, o + 8));
      if (nm[0] == 0x05) nm[0] = 0xE5;
      final base = sjisDecode(nm).trimRight();
      final ext = sjisDecode(raw.sublist(o + 8, o + 11)).trimRight();
      final name = ext.isEmpty ? base : '$base.$ext';
      if (name == '.' || name == '..') continue;
      final time = _u16(raw, o + 22);
      final date = _u16(raw, o + 24);
      DateTime? dt;
      final mo = (date >> 5) & 15, d = date & 31;
      if (mo >= 1 && mo <= 12 && d >= 1) {
        dt = DateTime(1980 + (date >> 9), mo, d, math.min(time >> 11, 23),
            math.min((time >> 5) & 63, 59));
      }
      out.add(DirEntry(name, (attr & 0x10) != 0, attr, _u16(raw, o + 26),
          _u32(raw, o + 28), dt,
          entryOff: offOf(o), parent: cluster));
    }
    return out;
  }

  // ---------------------------------------------------------------- 書き込み

  int get _eocValue => bits == 12 ? 0xFFF : 0xFFFF;

  void _setNext(int c, int v) {
    if (bits == 12) {
      final o = c + (c >> 1);
      if ((c & 1) == 0) {
        fat[o] = v & 0xFF;
        fat[o + 1] = (fat[o + 1] & 0xF0) | ((v >> 8) & 0x0F);
      } else {
        fat[o] = (fat[o] & 0x0F) | ((v << 4) & 0xF0);
        fat[o + 1] = (v >> 4) & 0xFF;
      }
    } else {
      fat[c * 2] = v & 0xFF;
      fat[c * 2 + 1] = (v >> 8) & 0xFF;
    }
  }

  /// FAT を全コピー分ディスクへ書き戻す
  void _flushFat() {
    for (var i = 0; i < nfats; i++) {
      src.write(start + (reserved + i * spf) * bps, fat);
    }
  }

  void _freeChain(int c) {
    for (final x in chain(c)) {
      _setNext(x, 0);
    }
  }

  List<int> _alloc(int n) {
    final out = <int>[];
    for (var c = 2; c < clusters + 2 && out.length < n; c++) {
      if (next(c) == 0) out.add(c);
    }
    if (out.length < n) throw const FormatException('ディスクの空きが足りません');
    return out;
  }

  /// data を空きクラスタへ書いてチェーンを作り、使ったクラスタ一覧を返す
  List<int> _writeData(Uint8List data) {
    if (data.isEmpty) return const [];
    final n = (data.length + clusterBytes - 1) ~/ clusterBytes;
    final cl = _alloc(n);
    for (var i = 0; i < n; i++) {
      final chunk = Uint8List(clusterBytes);
      final from = i * clusterBytes;
      chunk.setRange(0, math.min(clusterBytes, data.length - from), data, from);
      src.write(dataOffset + (cl[i] - 2) * clusterBytes, chunk);
      _setNext(cl[i], i + 1 < n ? cl[i + 1] : _eocValue);
    }
    return cl;
  }

  /// フォルダ内の空きエントリの位置を返す。足りなければサブフォルダは1クラスタ増やす。
  int _freeSlot(int dir) {
    if (dir == 0) {
      for (var i = 0; i < rootEntries; i++) {
        final o = rootOffset + i * 32;
        final b = src.read(o, 1)[0];
        if (b == 0x00 || b == 0xE5) return o;
      }
      throw const FormatException('ルートディレクトリに空きがありません（ファイル数の上限）');
    }
    final cl = chain(dir);
    if (cl.isEmpty) throw const FormatException('フォルダが壊れています');
    for (final c in cl) {
      final base = dataOffset + (c - 2) * clusterBytes;
      final raw = src.read(base, clusterBytes);
      for (var o = 0; o < clusterBytes; o += 32) {
        if (raw[o] == 0x00 || raw[o] == 0xE5) return base + o;
      }
    }
    final nc = _alloc(1).first;
    src.write(dataOffset + (nc - 2) * clusterBytes, Uint8List(clusterBytes));
    _setNext(cl.last, nc);
    _setNext(nc, _eocValue);
    return dataOffset + (nc - 2) * clusterBytes;
  }

  /// フォルダ内の使用中エントリの (位置, 32バイト)
  List<MapEntry<int, Uint8List>> _scan(int dir) {
    final out = <MapEntry<int, Uint8List>>[];
    void eat(int base, int len) {
      final raw = src.read(base, len);
      for (var o = 0; o + 32 <= len; o += 32) {
        if (raw[o] == 0x00) return;
        if (raw[o] == 0xE5) continue;
        out.add(MapEntry(base + o, Uint8List.fromList(raw.sublist(o, o + 32))));
      }
    }

    if (dir == 0) {
      eat(rootOffset, rootEntries * 32);
    } else {
      for (final c in chain(dir)) {
        eat(dataOffset + (c - 2) * clusterBytes, clusterBytes);
      }
    }
    return out;
  }

  bool _exists(int dir, Uint8List name83, {int exceptOff = -1}) {
    for (final e in _scan(dir)) {
      if (e.key == exceptOff) continue;
      var same = true;
      for (var i = 0; i < 11; i++) {
        if (e.value[i] != name83[i]) {
          same = false;
          break;
        }
      }
      if (same) return true;
    }
    return false;
  }

  /// "name.ext" を 8.3 形式の11バイトにする。使えない名前は null。
  static Uint8List? make83(String name) {
    final n = name.trim();
    final dot = n.lastIndexOf('.');
    final base = (dot < 0 ? n : n.substring(0, dot)).toUpperCase();
    final ext = (dot < 0 ? '' : n.substring(dot + 1)).toUpperCase();
    if (base.isEmpty) return null;
    const bad = '"*+,/:;<=>?[\\]|. ';
    for (final ch in (base + ext).split('')) {
      if (bad.contains(ch) || ch.codeUnitAt(0) < 0x20) return null;
    }
    final b = sjisEncode(base);
    final x = sjisEncode(ext);
    if (b == null || x == null || b.length > 8 || x.length > 3) return null;
    final out = Uint8List(11)..fillRange(0, 11, 0x20);
    out.setRange(0, b.length, b);
    out.setRange(8, 8 + x.length, x);
    if (out[0] == 0xE5) out[0] = 0x05;
    return out;
  }

  static void _stamp(Uint8List e) {
    final n = DateTime.now();
    final y = math.min(math.max(n.year, 1980), 2107);
    final t = (n.hour << 11) | (n.minute << 5) | (n.second ~/ 2);
    final d = ((y - 1980) << 9) | (n.month << 5) | n.day;
    e[22] = t & 0xFF;
    e[23] = t >> 8;
    e[24] = d & 0xFF;
    e[25] = d >> 8;
  }

  Uint8List _mkEntry(Uint8List name83, int attr, int cluster, int size) {
    final e = Uint8List(32);
    e.setRange(0, 11, name83);
    e[11] = attr;
    _stamp(e);
    e[26] = cluster & 0xFF;
    e[27] = (cluster >> 8) & 0xFF;
    e[28] = size & 0xFF;
    e[29] = (size >> 8) & 0xFF;
    e[30] = (size >> 16) & 0xFF;
    e[31] = (size >> 24) & 0xFF;
    return e;
  }

  /// 失敗したら FAT を元に戻して例外を投げ直す
  void _tx(void Function() body) {
    final backup = Uint8List.fromList(fat);
    try {
      body();
      _flushFat();
    } catch (_) {
      fat.setAll(0, backup);
      rethrow;
    }
  }

  /// 削除（フォルダは中身ごと）
  void delete(DirEntry e) {
    if (e.entryOff < 0) throw const FormatException('位置が分からないエントリです');
    _tx(() => _delete(e));
  }

  void _delete(DirEntry e) {
    if (e.isDir) {
      for (final c in list(e.cluster)) {
        _delete(c);
      }
    }
    if (e.cluster >= 2) _freeChain(e.cluster);
    src.write(e.entryOff, Uint8List.fromList([0xE5]));
  }

  /// 名前を変える
  void rename(DirEntry e, String newName) {
    final n = make83(newName);
    if (n == null) {
      throw const FormatException('名前は 8.3 形式（本体8文字・拡張子3文字、記号の一部は不可）にしてください');
    }
    if (_exists(e.parent, n, exceptOff: e.entryOff)) {
      throw const FormatException('同じ名前がすでにあります');
    }
    src.write(e.entryOff, n);
  }

  bool _isInside(int ancestor, int d) {
    var cur = d;
    var guard = 0;
    while (cur >= 2 && guard++ < 64) {
      if (cur == ancestor) return true;
      final b = src.read(dataOffset + (cur - 2) * clusterBytes + 32, 32);
      if (b[0] != 0x2E || b[1] != 0x2E) return false;
      cur = _u16(b, 26);
    }
    return false;
  }

  /// 別のフォルダへ移す（中身は動かさず、エントリだけ移す）
  void move(DirEntry e, int destDir) {
    if (destDir == e.parent) return;
    if (e.isDir && _isInside(e.cluster, destDir)) {
      throw const FormatException('フォルダを自分自身の中には移せません');
    }
    final raw = src.read(e.entryOff, 32);
    if (_exists(destDir, Uint8List.sublistView(raw, 0, 11))) {
      throw FormatException('移動先に同じ名前があります: ${e.name}');
    }
    _tx(() {
      final slot = _freeSlot(destDir);
      src.write(slot, raw);
      src.write(e.entryOff, Uint8List.fromList([0xE5]));
      if (e.isDir && e.cluster >= 2) {
        final dd = dataOffset + (e.cluster - 2) * clusterBytes + 32;
        final b = src.read(dd, 32);
        if (b[0] == 0x2E && b[1] == 0x2E) {
          src.write(dd + 26, Uint8List.fromList([destDir & 0xFF, (destDir >> 8) & 0xFF]));
        }
      }
    });
  }

  /// ファイルの中身を丸ごと置き換える（編集の保存）
  void replaceFile(DirEntry e, Uint8List data) {
    _tx(() {
      if (e.cluster >= 2) _freeChain(e.cluster);
      final cl = _writeData(data);
      final raw = src.read(e.entryOff, 32);
      final first = cl.isEmpty ? 0 : cl.first;
      raw[26] = first & 0xFF;
      raw[27] = (first >> 8) & 0xFF;
      raw[28] = data.length & 0xFF;
      raw[29] = (data.length >> 8) & 0xFF;
      raw[30] = (data.length >> 16) & 0xFF;
      raw[31] = (data.length >> 24) & 0xFF;
      _stamp(raw);
      src.write(e.entryOff, raw);
    });
  }

  /// フォルダ dir にファイルを追加
  void addFile(int dir, String name, Uint8List data) {
    final n = make83(name);
    if (n == null) {
      throw FormatException('「$name」は 8.3 形式の名前にできません。名前を変えてください');
    }
    if (_exists(dir, n)) throw FormatException('同じ名前がすでにあります: $name');
    _tx(() {
      final slot = _freeSlot(dir);
      final cl = _writeData(data);
      src.write(slot, _mkEntry(n, 0x20, cl.isEmpty ? 0 : cl.first, data.length));
    });
  }

  /// フォルダ dir に新しいフォルダを作る
  void mkdir(int dir, String name) {
    final n = make83(name);
    if (n == null) throw const FormatException('フォルダ名は 8.3 形式にしてください');
    if (_exists(dir, n)) throw const FormatException('同じ名前がすでにあります');
    _tx(() {
      final slot = _freeSlot(dir);
      final c = _alloc(1).first;
      final buf = Uint8List(clusterBytes);
      final dot = Uint8List(11)..fillRange(0, 11, 0x20);
      dot[0] = 0x2E;
      final dd = Uint8List(11)..fillRange(0, 11, 0x20);
      dd[0] = 0x2E;
      dd[1] = 0x2E;
      buf.setRange(0, 32, _mkEntry(dot, 0x10, c, 0));
      buf.setRange(32, 64, _mkEntry(dd, 0x10, dir, 0));
      src.write(dataOffset + (c - 2) * clusterBytes, buf);
      _setNext(c, _eocValue);
      src.write(slot, _mkEntry(n, 0x10, c, 0));
    });
  }

  int freeClusters() {
    var n = 0;
    for (var c = 2; c < clusters + 2; c++) {
      if (next(c) == 0) n++;
    }
    return n;
  }
}

class Volume {
  final String name;
  final Fat fat;
  Volume(this.name, this.fat);
}

List<Volume> findVolumes(Disk disk) {
  final out = <Volume>[];
  final ss = disk.sectorSize;
  if (disk.isHdd && disk.sectors > 0) {
    // PC-98 のパーティション表は 2番目のセクタ (LBA 1)
    final t = disk.src.read(ss, ss);
    final n = math.min(16, ss ~/ 32);
    for (var i = 0; i < n; i++) {
      final e = Uint8List.sublistView(t, i * 32, i * 32 + 32);
      if (e[1] == 0) continue;
      final sec = e[8], head = e[9], cyl = _u16(e, 10);
      final lba = (cyl * disk.heads + head) * disk.sectors + sec;
      final fat = Fat.tryParse(disk.src, lba * ss);
      if (fat != null) {
        var name = sjisDecode(e.sublist(16, 32)).replaceAll(RegExp(r'[\u0000 ]+$'), '');
        if (name.isEmpty) name = 'パーティション${out.length + 1}';
        out.add(Volume(name, fat));
      }
    }
    if (out.isEmpty) {
      for (final off in [0, disk.heads * disk.sectors * ss]) {
        final fat = Fat.tryParse(disk.src, off);
        if (fat != null) out.add(Volume('ボリューム', fat));
      }
    }
    return out;
  }
  final fat = Fat.tryParse(disk.src, 0);
  if (fat != null) out.add(Volume('ボリューム', fat));
  return out;
}
