// 圧縮ファイル（ZIP / LZH / GZ）の中身を読む。ディスクイメージを解凍せずに開くため。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sjis.dart';

class PackedItem {
  final String name; // フォルダ込みの名前
  final int size;
  final Uint8List Function() read;
  PackedItem(this.name, this.size, this.read);

  String get baseName => name.split('/').last;
}

const packedExts = {'zip', 'lzh', 'lha', 'gz'};

String _extOf(String name) {
  final n = name.toLowerCase();
  final i = n.lastIndexOf('.');
  return i < 0 ? '' : n.substring(i + 1);
}

bool isPacked(String name) => packedExts.contains(_extOf(name));

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) => _u16(b, o) | (_u16(b, o + 2) << 16);

String _name(List<int> raw, bool utf8) {
  if (utf8) {
    try {
      return utf8.decode(raw);
    } catch (_) {}
  }
  return sjisDecode(Uint8List.fromList(raw));
}

/// 圧縮ファイルの中身の一覧（フォルダは除く）
List<PackedItem> listPacked(String path, String fileName) {
  final b = File(path).readAsBytesSync();
  switch (_extOf(fileName)) {
    case 'zip':
      return _zip(b);
    case 'lzh':
    case 'lha':
      return _lzh(b);
    case 'gz':
      return _gz(b, fileName);
  }
  throw const FormatException('対応していない圧縮形式です');
}

// ---- ZIP ----------------------------------------------------------------

List<PackedItem> _zip(Uint8List b) {
  var eocd = -1;
  final lo = b.length - 22 - 0xFFFF;
  for (var i = b.length - 22; i >= 0 && i >= lo; i--) {
    if (b[i] == 0x50 && b[i + 1] == 0x4B && b[i + 2] == 5 && b[i + 3] == 6) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('ZIPの目次が見つかりません');
  final count = _u16(b, eocd + 10);
  var p = _u32(b, eocd + 16);
  final out = <PackedItem>[];
  for (var k = 0; k < count; k++) {
    if (p + 46 > b.length || _u32(b, p) != 0x02014B50) break;
    final flags = _u16(b, p + 8);
    final method = _u16(b, p + 10);
    final csize = _u32(b, p + 20);
    final usize = _u32(b, p + 24);
    final nl = _u16(b, p + 28), xl = _u16(b, p + 30), cl = _u16(b, p + 32);
    final local = _u32(b, p + 42);
    final name = _name(b.sublist(p + 46, p + 46 + nl), (flags & 0x800) != 0);
    p += 46 + nl + xl + cl;
    if (name.endsWith('/')) continue;
    out.add(PackedItem(name, usize, () {
      if ((flags & 1) != 0) throw const FormatException('パスワード付きのZIPは開けません');
      final ln = _u16(b, local + 26), lx = _u16(b, local + 28);
      final s = local + 30 + ln + lx;
      final data = Uint8List.sublistView(b, s, s + csize);
      if (method == 0) return Uint8List.fromList(data);
      if (method == 8) return Uint8List.fromList(ZLibDecoder(raw: true).convert(data));
      throw FormatException('ZIPの圧縮方式($method)に対応していません');
    }));
  }
  return out;
}

// ---- GZ -----------------------------------------------------------------

List<PackedItem> _gz(Uint8List b, String fileName) {
  var name = fileName.substring(0, fileName.length - 3);
  if (b.length > 10 && (b[3] & 8) != 0) {
    var p = 10;
    if ((b[3] & 4) != 0) p += 2 + _u16(b, 10);
    final s = p;
    while (p < b.length && b[p] != 0) {
      p++;
    }
    if (p > s) name = _name(b.sublist(s, p), false);
  }
  return [PackedItem(name, -1, () => Uint8List.fromList(GZipCodec().decode(b)))];
}

// ---- LZH ----------------------------------------------------------------

List<PackedItem> _lzh(Uint8List b) {
  final out = <PackedItem>[];
  var p = 0;
  while (p + 22 <= b.length && b[p] != 0) {
    final level = b[p + 20];
    final method = String.fromCharCodes(b.sublist(p + 2, p + 7));
    var packed = _u32(b, p + 7);
    final orig = _u32(b, p + 11);
    String name = '';
    String dir = '';
    int data;
    void ext(int q, int next) {
      while (next > 0 && q + next <= b.length) {
        final type = b[q];
        final body = b.sublist(q + 1, q + next - 2);
        if (type == 1) name = _name(body, false);
        if (type == 2) {
          dir = _name(body.map((c) => c == 0xFF ? 0x2F : c).toList(), false);
          if (dir.isNotEmpty && !dir.endsWith('/')) dir += '/';
        }
        if (level == 1) packed -= next;
        final n = _u16(b, q + next - 2);
        q += next;
        next = n;
      }
      data = q;
    }

    if (level == 0 || level == 1) {
      final hs = b[p];
      final nl = b[p + 21];
      name = _name(b.sublist(p + 22, p + 22 + nl), false).replaceAll('\\', '/');
      data = p + 2 + hs;
      if (level == 1) {
        final next = _u16(b, p + 2 + hs - 2);
        ext(p + 2 + hs, next);
      }
    } else if (level == 2) {
      final total = _u16(b, p);
      data = p + total;
      ext(p + 26, _u16(b, p + 24));
      data = p + total;
    } else {
      throw FormatException('LZHのヘッダ形式(レベル$level)に対応していません');
    }
    final start = data;
    final len = packed;
    final full = '$dir$name';
    if (method != '-lhd-') {
      out.add(PackedItem(full, orig, () {
        final src = Uint8List.sublistView(b, start, start + len);
        switch (method) {
          case '-lh0-':
          case '-lz4-':
            return Uint8List.fromList(src);
          case '-lh5-':
            return _lhDecode(src, orig, 13, 14, 4);
          case '-lh6-':
            return _lhDecode(src, orig, 15, 16, 5);
          case '-lh7-':
            return _lhDecode(src, orig, 16, 17, 5);
        }
        throw FormatException('LZHの圧縮方式($method)に対応していません');
      }));
    }
    p = start + len;
  }
  return out;
}

/// 長さの表から、ハフマン符号を読むための表を作る（短い符号ほど小さい値）
class _Huff {
  final List<int> count = List.filled(17, 0);
  final List<int> sym;
  final int constant;
  _Huff(List<int> len, int n)
      : sym = [],
        constant = -1 {
    for (var i = 0; i < n; i++) {
      if (len[i] > 16) throw const FormatException('LZHのデータが壊れています');
      count[len[i]]++;
    }
    count[0] = 0;
    for (var l = 1; l <= 16; l++) {
      for (var i = 0; i < n; i++) {
        if (len[i] == l) sym.add(i);
      }
    }
  }
  _Huff.only(this.constant) : sym = [];
}

class _Bits {
  final Uint8List s;
  int p = 0;
  int buf = 0; // 下位ビットから詰める
  int n = 0;
  _Bits(this.s);
  int get(int k) {
    if (k == 0) return 0;
    while (n < k) {
      buf = (buf << 8) | (p < s.length ? s[p] : 0);
      p++;
      n += 8;
    }
    n -= k;
    final r = (buf >> n) & ((1 << k) - 1);
    buf &= (1 << n) - 1;
    return r;
  }

  int decode(_Huff h) {
    if (h.constant >= 0) return h.constant;
    var code = 0, first = 0, index = 0;
    for (var l = 1; l <= 16; l++) {
      code |= get(1);
      final c = h.count[l];
      if (code - c < first) return h.sym[index + (code - first)];
      index += c;
      first += c;
      first <<= 1;
      code <<= 1;
    }
    throw const FormatException('LZHのデータが壊れています');
  }
}

Uint8List _lhDecode(Uint8List src, int size, int dicbit, int np, int pbit) {
  final out = Uint8List(size);
  final bits = _Bits(src);
  var o = 0;
  _Huff readPt(int nn, int nbit, int special) {
    final n = bits.get(nbit);
    if (n == 0) return _Huff.only(bits.get(nbit));
    final len = List.filled(nn > n ? nn : n, 0);
    var i = 0;
    while (i < n) {
      var c = bits.get(3);
      if (c == 7) {
        while (bits.get(1) == 1) {
          c++;
        }
      }
      len[i++] = c;
      if (i == special) {
        var z = bits.get(2);
        while (z-- > 0 && i < len.length) {
          len[i++] = 0;
        }
      }
    }
    return _Huff(len, len.length);
  }

  _Huff readC(_Huff pt) {
    const nc = 510;
    final n = bits.get(9);
    if (n == 0) return _Huff.only(bits.get(9));
    final len = List.filled(nc, 0);
    var i = 0;
    while (i < n && i < nc) {
      var c = bits.decode(pt);
      if (c <= 2) {
        if (c == 0) {
          c = 1;
        } else if (c == 1) {
          c = bits.get(4) + 3;
        } else {
          c = bits.get(9) + 20;
        }
        while (c-- > 0 && i < nc) {
          len[i++] = 0;
        }
      } else {
        len[i++] = c - 2;
      }
    }
    return _Huff(len, nc);
  }

  while (o < size) {
    var block = bits.get(16);
    if (bits.p > src.length + 4) break;
    final t = readPt(19, 5, 3);
    final c = readC(t);
    final p = readPt(np, pbit, -1);
    while (block-- > 0 && o < size) {
      final ch = bits.decode(c);
      if (ch < 256) {
        out[o++] = ch;
        continue;
      }
      final len = ch - 256 + 3;
      var d = bits.decode(p);
      if (d != 0) d = (1 << (d - 1)) + bits.get(d - 1);
      final from = o - d - 1;
      for (var k = 0; k < len && o < size; k++) {
        out[o] = from + k >= 0 ? out[from + k] : 0x20;
        o++;
      }
    }
  }
  return out;
}
