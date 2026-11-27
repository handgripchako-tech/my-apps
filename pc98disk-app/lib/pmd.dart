// PMD（M.Kajihara の PC-98 用音楽ドライバ）の曲データを探す部品。
//
// コンパイル済み曲データ(.M)の先頭:
//   +0     音源の種類 (0x00〜0x0F)
//   +1〜   パートA〜K と リズム表 の位置 (2byte×12)。0x1A 版はさらに音色データの位置 (2byte×13)
//          位置は +1 からの相対。最初の値はヘッダの長さそのもの (0x18 か 0x1A)
//   各パートの終わりは 0x80。パートは A〜K の順に隙間なく並ぶ。
// この並びを手がかりに、ファイルの途中に埋もれた曲データも見つける。
import 'dart:typed_data';

import 'sjis.dart';

/// 曲のファイル拡張子
const pmdSongExts = {'M', 'M2', 'MZ', 'MP', 'MS', 'MN'};

/// PCM・音色などの付属ファイル拡張子
const pmdPcmExts = {'PPC', 'P86', 'PPS', 'PZI', 'PVI', 'FF', 'FFL'};

/// MML（曲の元の文章）
const pmdMmlExts = {'MML'};

class PmdInfo {
  final int start;
  final int end; // 推定した終わり（この位置は含まない）
  final bool exactEnd; // 終わりを構造から確定できたか
  final String? title;
  final String? composer;
  final String? arranger;
  final String? pcmFile;
  final String? ppsFile;
  final String? ppzFile;
  PmdInfo(this.start, this.end, this.exactEnd,
      {this.title, this.composer, this.arranger, this.pcmFile, this.ppsFile, this.ppzFile});
}

int _w(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

/// b[s] から PMD の曲データが始まっているか調べる。limit はデータの終わり。
PmdInfo? checkPmd(Uint8List b, int s, int limit) {
  if (limit > b.length) limit = b.length;
  if (s < 0 || s + 3 > limit) return null;
  if (b[s] > 0x0F) return null;
  final h = b[s + 1];
  if ((h != 0x18 && h != 0x1A) || b[s + 2] != 0) return null;
  final n = h ~/ 2; // 12 か 13
  final base = s + 1;
  if (base + n * 2 > limit) return null;
  final p = List<int>.generate(n, (i) => _w(b, base + i * 2));
  // パートA〜Kは少なくとも 0x80 の1バイトずつあるので、位置は必ず増えていく
  for (var i = 1; i <= 10; i++) {
    if (p[i] <= p[i - 1]) return null;
  }
  for (var i = 11; i < n; i++) {
    if (p[i] < p[i - 1]) return null;
  }
  for (final x in p) {
    if (base + x >= limit) return null;
  }
  // 次のパートの直前は前のパートの終わり (0x80)
  for (var i = 1; i <= 10; i++) {
    if (b[base + p[i] - 1] != 0x80) return null;
  }
  // 全部のパートが空っぽ（0x80 だけ）は曲とみなさない
  if (p[10] - p[0] < 10 + 8) return null;

  // ---- 終わりの位置とメモ（曲名など）
  var end = -1;
  var exact = false;
  String? title, composer, arranger, pcm, pps, ppz;
  final cap = (s + 0x10000 < limit) ? s + 0x10000 : limit;
  if (n == 13) {
    final v = base + p[12]; // 音色データ
    var memoEnd = -1;
    if (v - 4 >= base + n * 2 && b[v - 1] == 0xFE && b[v - 2] >= 0x40 && b[v - 2] < 0x80) {
      final ver = b[v - 2];
      final mt = base + _w(b, v - 4);
      if (mt >= base && mt + 2 <= cap) {
        final strs = <String?>[];
        var q = mt;
        var guard = 0;
        while (q + 2 <= cap && guard++ < 64) {
          final o = _w(b, q);
          q += 2;
          if (o == 0) break;
          final a = base + o;
          if (a >= cap) break;
          var z = a;
          while (z < cap && b[z] != 0) {
            z++;
          }
          if (z >= cap) break;
          if (z + 1 > memoEnd) memoEnd = z + 1;
          strs.add(_clean(b, a, z));
        }
        if (q > memoEnd) memoEnd = q;
        // 0:PCM, (0x42〜) PPS, (0x48〜) PPZ, その後に 曲名/作曲/編曲
        var k = 0;
        String? at(int i) => i < strs.length ? strs[i] : null;
        pcm = at(k++);
        if (ver >= 0x42) pps = at(k++);
        if (ver >= 0x48) ppz = at(k++);
        title = at(k++);
        composer = at(k++);
        arranger = at(k++);
      }
    }
    // 音色データ: 26バイトずつ。番号の所が 0xFF で終わり
    var q = v;
    for (var i = 0; i < 257 && q < cap; i++) {
      if (b[q] == 0xFF) {
        end = q + 1;
        exact = true;
        break;
      }
      q += 26;
    }
    if (exact && memoEnd > end) end = memoEnd;
  }
  if (end < 0 || end > limit) {
    end = cap;
    exact = false;
  }
  return PmdInfo(s, end, exact,
      title: _nz(title),
      composer: _nz(composer),
      arranger: _nz(arranger),
      pcmFile: _nz(pcm),
      ppsFile: _nz(pps),
      ppzFile: _nz(ppz));
}

String? _nz(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

/// メモ文字列。色指定などの制御コード (ESC [ … m など) を取り除く
String _clean(Uint8List b, int a, int z) {
  final out = <int>[];
  var i = a;
  while (i < z) {
    final c = b[i];
    if (c == 0x1B) {
      i++;
      if (i < z && b[i] == 0x5B) {
        i++;
        while (i < z && !((b[i] >= 0x40 && b[i] <= 0x7E))) {
          i++;
        }
      }
      i++;
      continue;
    }
    if (c < 0x20) {
      out.add(0x20);
    } else {
      out.add(c);
    }
    i++;
  }
  return sjisDecode(out, keepControl: false).replaceAll(RegExp(r'\s+'), ' ');
}

/// b の中から PMD の曲データを全部探す。重なるものは先に見つかった方を使う。
List<PmdInfo> scanPmd(Uint8List b, {int from = 0, int? to}) {
  final lim = b.length;
  final stop = to ?? lim;
  final out = <PmdInfo>[];
  var i = from;
  while (i + 3 <= stop) {
    final h = b[i + 1];
    if (b[i + 2] == 0 && (h == 0x18 || h == 0x1A) && b[i] <= 0x0F) {
      final r = checkPmd(b, i, lim);
      if (r != null) {
        out.add(r);
        // 曲データの中身（パート部分）は飛ばす
        final skip = i + 1 + _w(b, i + 1 + 2 * 10);
        i = skip > i ? skip : i + 1;
        continue;
      }
    }
    i++;
  }
  // 終わりが確定していないものは、次の曲の手前で切る
  for (var k = 0; k + 1 < out.length; k++) {
    final a = out[k];
    final nx = out[k + 1].start;
    if (a.end > nx) {
      out[k] = PmdInfo(a.start, nx, false,
          title: a.title,
          composer: a.composer,
          arranger: a.arranger,
          pcmFile: a.pcmFile,
          ppsFile: a.ppsFile,
          ppzFile: a.ppzFile);
    }
  }
  return out;
}

/// よくある LZSS（奥村式, 窓4096, 一致長3〜18）を展開する。
/// fill はバッファの初期値、r0 は書き込み開始位置。壊れていても出来たところまで返す。
Uint8List lzssDecode(Uint8List src, int off, int maxOut,
    {int fill = 0x20, int r0 = 4096 - 18}) {
  final ring = Uint8List(4096)..fillRange(0, 4096, fill);
  final out = Uint8List(maxOut);
  var o = 0;
  var r = r0 & 0xFFF;
  var i = off;
  var flags = 0;
  final n = src.length;
  while (o < maxOut) {
    flags >>= 1;
    if ((flags & 0x100) == 0) {
      if (i >= n) break;
      flags = src[i++] | 0xFF00;
    }
    if ((flags & 1) != 0) {
      if (i >= n) break;
      final c = src[i++];
      out[o++] = c;
      ring[r] = c;
      r = (r + 1) & 0xFFF;
    } else {
      if (i + 1 >= n) break;
      var p = src[i++];
      final j = src[i++];
      p |= (j & 0xF0) << 4;
      final len = (j & 0x0F) + 3;
      for (var k = 0; k < len && o < maxOut; k++) {
        final c = ring[(p + k) & 0xFFF];
        out[o++] = c;
        ring[r] = c;
        r = (r + 1) & 0xFFF;
      }
    }
  }
  return Uint8List.sublistView(out, 0, o);
}
