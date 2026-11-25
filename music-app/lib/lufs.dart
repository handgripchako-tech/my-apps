import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

/// WAV(16bit PCM)の音量(統合ラウドネス, LUFS / ITU-R BS.1770)を端末内で測る。
/// サーバーの ffmpeg (ebur128) とほぼ同じ値になる。WAVでない/読めないときは null。
class Lufs {
  static Future<double?> ofWav(String path, {int maxSec = 300}) async {
    try {
      return await Isolate.run(() => _measure(path, maxSec));
    } catch (_) {
      return null;
    }
  }

  static double? _measure(String path, int maxSec) {
    final f = File(path).openSync();
    try {
      final len = f.lengthSync();
      final head = Uint8List(12);
      if (f.readIntoSync(head, 0, 12) < 12) return null;
      if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') {
        return null;
      }
      var ch = 0, rate = 0, bits = 0, dataStart = -1, dataLen = 0;
      var pos = 12;
      while (pos + 8 <= len) {
        f.setPositionSync(pos);
        final h = Uint8List(8);
        if (f.readIntoSync(h, 0, 8) < 8) break;
        final id = String.fromCharCodes(h.sublist(0, 4));
        final size = ByteData.sublistView(h).getUint32(4, Endian.little);
        if (id == 'fmt ') {
          final b = Uint8List(16);
          f.readIntoSync(b, 0, 16);
          final d = ByteData.sublistView(b);
          ch = d.getUint16(2, Endian.little);
          rate = d.getUint32(4, Endian.little);
          bits = d.getUint16(14, Endian.little);
        } else if (id == 'data') {
          dataStart = pos + 8;
          dataLen = min(size, len - dataStart);
          break;
        }
        pos += 8 + size + (size & 1);
      }
      if (dataStart < 0 || ch < 1 || rate < 8000 || bits != 16) return null;

      final nCh = min(ch, 2);
      final frameBytes = 2 * ch;
      final totalFrames = min(dataLen ~/ frameBytes, rate * maxSec);
      final hop = (rate * 0.1).round();
      if (hop < 1 || totalFrames < hop * 4) return null;

      // K特性フィルタ(高域シェルフ + ハイパス)の係数
      const f1 = 1681.974450955533, g1 = 3.999843853973347, q1 = 0.7071752369554196;
      final k1 = tan(pi * f1 / rate);
      final vh = pow(10, g1 / 20).toDouble();
      final vb = pow(vh, 0.4996667741545416).toDouble();
      final a0 = 1 + k1 / q1 + k1 * k1;
      final b10 = (vh + vb * k1 / q1 + k1 * k1) / a0;
      final b11 = 2 * (k1 * k1 - vh) / a0;
      final b12 = (vh - vb * k1 / q1 + k1 * k1) / a0;
      final a11 = 2 * (k1 * k1 - 1) / a0;
      final a12 = (1 - k1 / q1 + k1 * k1) / a0;
      const f2 = 38.13547087602444, q2 = 0.5003270373238773;
      final k2 = tan(pi * f2 / rate);
      final c0 = 1 + k2 / q2 + k2 * k2;
      final a21 = 2 * (k2 * k2 - 1) / c0;
      final a22 = (1 - k2 / q2 + k2 * k2) / c0;

      // 状態: [x1, x2, y1, y2, u1, u2, v1, v2] をチャンネルごとに
      final st = Float64List(nCh * 8);
      final segs = <double>[]; // 100msごとの二乗和 (全チャンネル合計)
      var segAcc = 0.0, segN = 0, done = 0;
      const chunk = 32768;
      final buf = Uint8List(chunk * frameBytes);
      f.setPositionSync(dataStart);
      while (done < totalFrames) {
        final want = min(chunk, totalFrames - done);
        final got = f.readIntoSync(buf, 0, want * frameBytes) ~/ frameBytes;
        if (got <= 0) break;
        final bd = ByteData.sublistView(buf);
        for (var i = 0; i < got; i++) {
          for (var c = 0; c < nCh; c++) {
            final x = bd.getInt16(i * frameBytes + c * 2, Endian.little) / 32768.0;
            final o = c * 8;
            final y = b10 * x + b11 * st[o] + b12 * st[o + 1] - a11 * st[o + 2] - a12 * st[o + 3];
            st[o + 1] = st[o];
            st[o] = x;
            st[o + 3] = st[o + 2];
            st[o + 2] = y;
            final z = y - 2.0 * st[o + 4] + st[o + 5] - a21 * st[o + 6] - a22 * st[o + 7];
            st[o + 5] = st[o + 4];
            st[o + 4] = y;
            st[o + 7] = st[o + 6];
            st[o + 6] = z;
            segAcc += z * z;
          }
          if (++segN == hop) {
            segs.add(segAcc);
            segAcc = 0;
            segN = 0;
          }
        }
        done += got;
      }

      // 400msのブロック(100msずつずらす) → 絶対ゲート(-70) → 相対ゲート(-10LU)
      final blk = 4 * hop;
      final zs = <double>[];
      for (var i = 0; i + 4 <= segs.length; i++) {
        zs.add((segs[i] + segs[i + 1] + segs[i + 2] + segs[i + 3]) / blk);
      }
      double l(double m) => m > 0 ? -0.691 + 10 * log(m) / ln10 : -1e9;
      final g1s = zs.where((v) => l(v) > -70).toList();
      if (g1s.isEmpty) return null;
      final gr = l(g1s.reduce((a, b) => a + b) / g1s.length) - 10;
      final g2s = g1s.where((v) => l(v) > gr).toList();
      if (g2s.isEmpty) return null;
      final r = l(g2s.reduce((a, b) => a + b) / g2s.length);
      return r.isFinite ? r : null;
    } catch (_) {
      return null;
    } finally {
      f.closeSync();
    }
  }
}
