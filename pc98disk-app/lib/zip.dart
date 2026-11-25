// 依存パッケージ無しの最小 ZIP ライター (無圧縮 / UTF-8 ファイル名)。
import 'dart:convert';
import 'dart:typed_data';

class ZipWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);
  final BytesBuilder _central = BytesBuilder(copy: false);
  int _count = 0;

  static final Uint32List _table = _makeTable();

  static Uint32List _makeTable() {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      t[n] = c;
    }
    return t;
  }

  static int crc32(Uint8List data) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      c = _table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  void addDir(String name, [DateTime? time]) =>
      add(name.endsWith('/') ? name : '$name/', Uint8List(0), time);

  void add(String name, Uint8List data, [DateTime? time]) {
    final t = time ?? DateTime(1980, 1, 1);
    final dosTime = (t.hour << 11) | (t.minute << 5) | (t.second >> 1);
    final y = t.year < 1980 ? 0 : t.year - 1980;
    final dosDate = (y << 9) | (t.month << 5) | t.day;
    final nameBytes = utf8.encode(name);
    final crc = crc32(data);
    final offset = _out.length;

    final lh = ByteData(30);
    lh.setUint32(0, 0x04034B50, Endian.little);
    lh.setUint16(4, 20, Endian.little);
    lh.setUint16(6, 0x0800, Endian.little); // UTF-8 名
    lh.setUint16(8, 0, Endian.little); // 無圧縮
    lh.setUint16(10, dosTime, Endian.little);
    lh.setUint16(12, dosDate, Endian.little);
    lh.setUint32(14, crc, Endian.little);
    lh.setUint32(18, data.length, Endian.little);
    lh.setUint32(22, data.length, Endian.little);
    lh.setUint16(26, nameBytes.length, Endian.little);
    lh.setUint16(28, 0, Endian.little);
    _out.add(lh.buffer.asUint8List());
    _out.add(nameBytes);
    _out.add(data);

    final ch = ByteData(46);
    ch.setUint32(0, 0x02014B50, Endian.little);
    ch.setUint16(4, 20, Endian.little);
    ch.setUint16(6, 20, Endian.little);
    ch.setUint16(8, 0x0800, Endian.little);
    ch.setUint16(10, 0, Endian.little);
    ch.setUint16(12, dosTime, Endian.little);
    ch.setUint16(14, dosDate, Endian.little);
    ch.setUint32(16, crc, Endian.little);
    ch.setUint32(20, data.length, Endian.little);
    ch.setUint32(24, data.length, Endian.little);
    ch.setUint16(28, nameBytes.length, Endian.little);
    ch.setUint16(30, 0, Endian.little);
    ch.setUint16(32, 0, Endian.little);
    ch.setUint16(34, 0, Endian.little);
    ch.setUint16(36, 0, Endian.little);
    ch.setUint32(38, name.endsWith('/') ? 0x10 : 0, Endian.little);
    ch.setUint32(42, offset, Endian.little);
    _central.add(ch.buffer.asUint8List());
    _central.add(nameBytes);
    _count++;
  }

  Uint8List finish() {
    final cdOffset = _out.length;
    final cd = _central.takeBytes();
    _out.add(cd);
    final end = ByteData(22);
    end.setUint32(0, 0x06054B50, Endian.little);
    end.setUint16(4, 0, Endian.little);
    end.setUint16(6, 0, Endian.little);
    end.setUint16(8, _count, Endian.little);
    end.setUint16(10, _count, Endian.little);
    end.setUint32(12, cd.length, Endian.little);
    end.setUint32(16, cdOffset, Endian.little);
    end.setUint16(20, 0, Endian.little);
    _out.add(end.buffer.asUint8List());
    return _out.takeBytes();
  }
}
