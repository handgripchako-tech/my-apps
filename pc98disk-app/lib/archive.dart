// ゲームの「まとめファイル」（中に複数のファイルを詰めたもの）を読む。
//   - FA1   : "FA1\0" で始まる。目次は末尾（0xFF で反転）、中身は独自のLZ圧縮。
//   - DISK  : silky's の DISKA〜 など。先頭に件数、19バイトずつの目次（名前13・大きさ2・位置4）。
//   - AFLB  : 日本ファルコム（英雄伝説III など）。"AFLB DAT"、位置は32バイト単位、中身は独自の圧縮。
import 'dart:typed_data';

class ArcEntry {
  final String name;
  final int size; // 展開後の大きさ
  final bool packed;
  final Uint8List Function() read;
  ArcEntry(this.name, this.size, this.packed, this.read);
}

class Archive {
  final String kind; // 'FA1' / 'DISK'
  final List<ArcEntry> entries;
  Archive(this.kind, this.entries);
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) => _u16(b, o) | (_u16(b, o + 2) << 16);

String _ascii(List<int> b) {
  final sb = StringBuffer();
  for (final c in b) {
    if (c == 0) break;
    sb.writeCharCode(c);
  }
  return sb.toString().trim();
}

/// まとめファイルなら中身の一覧を返す。違えば null。
Archive? openArchive(Uint8List b) {
  try {
    return _fa1(b) ?? _aflb(b) ?? _disk(b);
  } catch (_) {
    return null;
  }
}

// ---- FA1 ---------------------------------------------------------------

Archive? _fa1(Uint8List b) {
  if (b.length < 32 || b[0] != 0x46 || b[1] != 0x41 || b[2] != 0x31 || b[3] != 0) return null;
  final cnt = _u16(b, 8);
  if (cnt == 0 || cnt * 20 + 12 > b.length) return null;
  final t = b.length - cnt * 20;
  final out = <ArcEntry>[];
  var pos = 12;
  for (var i = 0; i < cnt; i++) {
    final e = List<int>.generate(20, (k) => b[t + i * 20 + k] ^ 0xFF);
    final base = _ascii(e.sublist(0, 8));
    final ext = _ascii(e.sublist(8, 11));
    final name = ext.isEmpty ? base : '$base.$ext';
    final packed = e[11] == 1;
    final psize = e[12] | (e[13] << 8) | (e[14] << 16) | (e[15] << 24);
    final usize = e[16] | (e[17] << 8) | (e[18] << 16) | (e[19] << 24);
    if (packed && (pos & 1) == 1) pos++;
    final start = pos;
    if (start + psize > t || psize < 0 || usize < 0 || usize > 64 * 1024 * 1024) return null;
    out.add(ArcEntry(name, packed ? usize : psize, packed, () {
      if (!packed) return Uint8List.sublistView(b, start, start + psize);
      return fa1Decode(b, start, usize);
    }));
    pos += psize;
  }
  return Archive('FA1', out);
}

/// FA1 の圧縮を展開する（ゲームの FAD.BIN の処理を写したもの）
Uint8List fa1Decode(Uint8List src, int start, int size) {
  final out = Uint8List(size);
  var o = 0;
  var i = start;
  var bp = 0, n = 0;
  int bit() {
    if (n == 0) {
      bp = src[i] | (src[i + 1] << 8);
      i += 2;
      n = 16;
    }
    n--;
    final r = (bp >> 15) & 1;
    bp = (bp << 1) & 0xFFFF;
    return r;
  }

  int byte() => src[i++];
  try {
    while (o < size) {
      if (bit() == 1) {
        out[o++] = byte();
        continue;
      }
      int off, len;
      if (bit() == 1) {
        final c = bit();
        var a = byte();
        if (c == 1) {
          for (var k = 0; k < 3; k++) {
            a = (a << 1) | bit();
          }
          a += 0x100;
          if (a >= 0x8FF) {
            if (bit() == 1) break;
            continue;
          }
        }
        off = a + 1;
        len = 2;
      } else {
        int a, nb;
        if (bit() == 1) {
          a = byte();
          nb = 1;
        } else if (bit() == 1) {
          a = 0x100 | byte();
          nb = 1;
        } else if (bit() == 1) {
          a = 0x100 | byte();
          nb = 2;
        } else if (bit() == 1) {
          a = 0x100 | byte();
          nb = 3;
        } else {
          a = 0x100 | byte();
          nb = 4;
        }
        for (var k = 0; k < nb; k++) {
          a = (a << 1) | bit();
        }
        if (bit() == 1) {
          len = 3;
        } else if (bit() == 1) {
          len = 4;
        } else if (bit() == 1) {
          len = 5 + bit();
        } else if (bit() == 1) {
          len = 7 + ((bit() << 1) | bit());
        } else if (bit() == 1) {
          len = 11 + ((bit() << 3) | (bit() << 2) | (bit() << 1) | bit());
        } else {
          len = 27 + byte();
        }
        off = a + 1;
      }
      for (var k = 0; k < len && o < size; k++) {
        out[o] = off <= o ? out[o - off] : 0;
        o++;
      }
    }
  } on RangeError {
    // 壊れていても、展開できたところまで返す
  }
  return out;
}

// ---- silky's DISK -------------------------------------------------------

Archive? _disk(Uint8List b) {
  if (b.length < 2 + 19) return null;
  final n = _u16(b, 0);
  if (n == 0 || n > 4096) return null;
  final head = 2 + n * 19;
  if (head > b.length) return null;
  final out = <ArcEntry>[];
  var good = 0;
  for (var i = 0; i < n; i++) {
    final e = 2 + i * 19;
    final raw = b.sublist(e, e + 13);
    final name = _ascii(raw);
    if (name.isEmpty) return null;
    for (final c in name.codeUnits) {
      if (c < 0x21 || c > 0x7E) return null;
    }
    final size = _u16(b, e + 13);
    final off = _u32(b, e + 15);
    if (off < head || off + size > b.length) return null;
    if (name.contains('.')) good++;
    out.add(ArcEntry(name, size, false, () => Uint8List.sublistView(b, off, off + size)));
  }
  if (good * 2 < n) return null; // 名前の形がそれらしくない
  return Archive('DISK', out);
}

// ---- 日本ファルコム AFLB ------------------------------------------------

Archive? _aflb(Uint8List b) {
  if (b.length < 0x20) return null;
  const sig = 'AFLB DAT';
  for (var i = 0; i < 8; i++) {
    if (b[i] != sig.codeUnitAt(i)) return null;
  }
  final n = _u16(b, 10);
  if (n == 0 || 0x10 + n * 2 + 2 > b.length) return null;
  final out = <ArcEntry>[];
  for (var i = 0; i < n; i++) {
    final a = _u16(b, 0x10 + i * 2) * 32;
    if (a == 0 || a >= b.length) break;
    var e = _u16(b, 0x12 + i * 2) * 32;
    if (e <= a || e > b.length) e = b.length;
    final start = a, end = e;
    out.add(ArcEntry('${i.toString().padLeft(3, '0')}.BIN', end - start, true,
        () => falcomDecode(b, start, end)));
  }
  return Archive('AFLB', out);
}

/// ファルコムの圧縮を戻す（2方式。ゲームの処理を写したもの）。戻せなければそのまま返す。
Uint8List falcomDecode(Uint8List s, int start, int end) {
  try {
    final out = BytesBuilder(copy: false);
    final buf = <int>[];
    var p = start;
    while (true) {
      if (p + 3 > end) throw const FormatException('');
      p = s[p + 2] == 0 ? _falBits(s, p, end, buf) : _falBytes(s, p, end, buf);
      if (p >= end) break;
      final flag = s[p++];
      if (flag == 0 || buf.length > 4 * 1024 * 1024) break;
    }
    if (buf.isEmpty) throw const FormatException('');
    out.add(Uint8List.fromList(buf));
    return out.takeBytes();
  } catch (_) {
    return Uint8List.sublistView(s, start, end);
  }
}

void _copy(List<int> out, int off, int n) {
  final src = out.length - off;
  if (src < 0) throw const FormatException('');
  for (var k = 0; k < n; k++) {
    out.add(out[src + k]);
  }
}

int _falBytes(Uint8List s, int p, int end, List<int> out) {
  final blockEnd = p + (s[p] | (s[p + 1] << 8));
  if (blockEnd > end) throw const FormatException('');
  p += 2;
  while (p < blockEnd) {
    final a = s[p++];
    if ((a & 0x80) != 0) {
      final n = ((a >> 5) & 3) + 4;
      final off = ((a & 0x1f) << 8) | s[p++];
      var src = out.length - off;
      if (src < 0) throw const FormatException('');
      for (var k = 0; k < n; k++) {
        out.add(out[src + k]);
      }
      src += n;
      while (p < blockEnd && (s[p] & 0xe0) == 0x60) {
        final m = s[p++] & 0x1f;
        for (var k = 0; k < m; k++) {
          out.add(out[src + k]);
        }
        src += m;
      }
    } else if ((a & 0x40) != 0) {
      int n;
      if ((a & 0x10) != 0) {
        n = (((a & 0xf) << 8) | s[p++]) + 4;
      } else {
        n = (a & 0xf) + 4;
      }
      final v = s[p++];
      for (var k = 0; k < n; k++) {
        out.add(v);
      }
    } else {
      int n;
      if ((a & 0x20) != 0) {
        n = ((a & 0x1f) << 8) | s[p++];
      } else {
        n = a;
      }
      if (p + n > blockEnd) throw const FormatException('');
      out.addAll(Uint8List.sublistView(s, p, p + n));
      p += n;
    }
  }
  return blockEnd;
}

int _falBits(Uint8List s, int p, int end, List<int> out) {
  p += 2;
  var bp = (s[p] << 8) | s[p + 1];
  var nb = 8;
  p += 2;
  int bit() {
    if (nb == 0) {
      bp = s[p] | (s[p + 1] << 8);
      p += 2;
      nb = 16;
    }
    final r = bp & 1;
    bp >>= 1;
    nb--;
    return r;
  }

  int byte() => s[p++];
  int bits(int k) {
    var v = 0;
    for (var i = 0; i < k; i++) {
      v = (v << 1) | bit();
    }
    return v;
  }

  while (true) {
    if (p > end) throw const FormatException('');
    if (bit() == 0) {
      out.add(byte());
      continue;
    }
    int off;
    if (bit() == 0) {
      off = byte();
    } else {
      off = (bits(5) << 8) | byte();
      if (off == 0) return p;
      if (off == 1) {
        final ah = bit();
        final c = bits(4);
        final n = (ah == 1 ? ((c << 8) | byte()) : c) + 0xe;
        final v = byte();
        for (var k = 0; k < n; k++) {
          out.add(v);
        }
        continue;
      }
    }
    int n;
    if (bit() == 1) {
      n = 2;
    } else if (bit() == 1) {
      n = 3;
    } else if (bit() == 1) {
      n = 4;
    } else if (bit() == 1) {
      n = 5;
    } else if (bit() == 0) {
      n = byte() + 0xe;
    } else {
      n = bits(3) + 6;
    }
    _copy(out, off, n);
  }
}

/// ファルコムの曲データらしいか（先頭に10パートの位置、最初の位置は32の倍数）
bool isFalcomSong(Uint8List d) {
  if (d.length < 0x40) return false;
  var prev = -1;
  for (var i = 0; i < 10; i++) {
    final w = _u16(d, i * 2);
    if (w <= prev || w >= d.length) return false;
    prev = w;
  }
  final first = _u16(d, 0);
  return first >= 0x20 && first <= 0x400 && first % 32 == 0;
}

/// ファルコムの音楽ドライバ（OPN/OPNA 版）らしいか
bool isFalcomDriver(Uint8List d) {
  const head = [0x00, 0x06, 0x1e, 0x60, 0x8c, 0xcd, 0x8e, 0xdd, 0x8e, 0xc5, 0x8b, 0xec, 0x80, 0xfc, 0x08];
  if (d.length < 0x800 || d.length > 0x1730 || d[0] != 0xe9) return false;
  for (var i = 0; i < head.length; i++) {
    if (d[3 + i] != head[i]) return false;
  }
  // OPN のポート 188h を持つもの（ビープ版は除く）
  for (var i = 0; i + 1 < d.length; i++) {
    if (d[i] == 0x88 && d[i + 1] == 0x01) return true;
  }
  return false;
}
