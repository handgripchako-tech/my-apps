// ゲームの「まとめファイル」（中に複数のファイルを詰めたもの）を読む。
//   - FA1   : "FA1\0" で始まる。目次は末尾（0xFF で反転）、中身は独自のLZ圧縮。
//   - DISK  : silky's の DISKA〜 など。先頭に件数、19バイトずつの目次（名前13・大きさ2・位置4）。
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
    return _fa1(b) ?? _disk(b);
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
