import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

// native/pmd_wav.c の関数を呼ぶ
typedef _ToWavC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
    Int32, Int32, Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _ToWavD = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
    int, int, int, Pointer<Utf8>, Pointer<Utf8>);
typedef _ProbeC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ProbeD = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

/// PC-98のPMD(FM音源)曲を扱う。
/// - PMD本体は「スマホ内ファイル置き場/pmdsrc/<名前>.m」に小さいまま保存する。
/// - WAVは、再生・解析のときだけ作る。作ったWAVは最近の数曲だけ残して消す。
/// - 音色ファイル(.PPC/.P86/ドラムの2608_*.WAV)は「pmdlib」フォルダに保存する。
class Pmd {
  Pmd._();

  /// PMD曲の拡張子(中身かどうかはネイティブ側でも確認する)
  static const songExts = {'m', 'm2', 'mz', 'mp', 'mdt', 'wm', 'pai', 'fal', 'mid', 'midi', 'mus'};

  /// 標準MIDI(.mid)。SoundFont（GS対応）で鳴らす
  static bool _isMid(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.mid') || p.endsWith('.midi');
  }

  /// Libido7 などの KIN_BGM 形式(.MUS)。中のMIDIパートを SoundFont で鳴らす
  static bool _isMus(String path) => path.toLowerCase().endsWith('.mus');

  /// MIDIで鳴らす曲か（ファイル名や local:〇〇 でも判定できる）
  static bool isMidi(String path) {
    if (_isMid(path) || _isMus(path)) return true;
    final i = path.lastIndexOf('/');
    final fn = path.startsWith('local:') ? path.substring(6) : path.substring(i + 1);
    final d = _dir;
    if (d == null) return false;
    final stem = _stemOf(fn);
    return File('${d.path}/pmdsrc/$stem.mid').existsSync() ||
        File('${d.path}/pmdsrc/$stem.mus').existsSync();
  }

  static Directory? _dir;

  static bool _isMdt(String path) => path.toLowerCase().endsWith('.mdt');

  /// silky's などの WM 曲。ゲームの MUSIC.COM を音色ファイル置き場に入れて、本物のドライバで鳴らす
  static bool _isWm(String path) => path.toLowerCase().endsWith('.wm');

  /// synthia の PAI 曲。ゲームの S20S_4.BIN を音色ファイル置き場に入れて鳴らす
  static bool _isPai(String path) => path.toLowerCase().endsWith('.pai');

  /// 日本ファルコム（英雄伝説III など）の曲。ゲームのドライバ FALOPNA.DRV と組で鳴らす
  static bool _isFal(String path) => path.toLowerCase().endsWith('.fal');

  /// ネイティブ側の関数名の頭（pmd / mdt / wm）
  static String _kind(String path) =>
      _isMid(path) ? 'mid' : _isMus(path) ? 'mus' :
      _isMdt(path) ? 'mdt' : (_isWm(path) ? 'wm' : (_isPai(path) ? 'pai' : (_isFal(path) ? 'fal' : 'pmd')));

  /// 本体の保存用の拡張子
  static String _srcExt(String path) =>
      _isMid(path) ? '.mid' : _isMus(path) ? '.mus' :
      _isMdt(path) ? '.mdt' : (_isWm(path) ? '.wm' : (_isPai(path) ? '.pai' : (_isFal(path) ? '.fal' : '.m')));

  /// WM の曲を鳴らすためのドライバ(MUSIC.COM)が保存済みか
  static Future<bool> hasWmDriver() async {
    final d = await libDir();
    for (final n in const ['MUSIC.COM', 'music.com', 'Music.com']) {
      if (await File('${d.path}/$n').exists()) return true;
    }
    return false;
  }

  /// PAI の曲を鳴らすためのドライバ(S20S_4.BIN)が保存済みか
  static Future<bool> hasPaiDriver() async {
    final d = await libDir();
    for (final n in const ['S20S_4.BIN', 's20s_4.bin', 'S20S_4.bin']) {
      if (await File('${d.path}/$n').exists()) return true;
    }
    return false;
  }

  /// ファルコムの曲を鳴らすためのドライバ(FALOPNA.DRV)が保存済みか
  static Future<bool> hasFalDriver() async {
    final d = await libDir();
    for (final n in const ['FALOPNA.DRV', 'falopna.drv', 'FALOPNA.drv']) {
      if (await File('${d.path}/$n').exists()) return true;
    }
    return false;
  }

  static bool isSong(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return songExts.contains(name.substring(dot + 1).toLowerCase());
  }

  // ---- 音色ファイルの置き場 ----------------------------------------

  static Directory? _lib;

  static Future<Directory> libDir() async {
    final cached = _lib;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/pmdlib');
    if (!await d.exists()) await d.create(recursive: true);
    _lib = d;
    return d;
  }

  /// 音色ファイル・ドラムWAVなどを保存する。
  /// Androidは大文字小文字を区別するので、元の名前・大文字・小文字の3通りで置く。
  static Future<void> saveCompanion(String srcPath, String name) async {
    final d = await libDir();
    final names = <String>{name, name.toUpperCase(), name.toLowerCase()};
    for (final n in names) {
      await File(srcPath).copy('${d.path}/$n');
    }
  }

  // ---- PMD本体(小さいまま保存) ------------------------------------

  static String _stemOf(String fn) {
    final i = fn.lastIndexOf('.');
    return i > 0 ? fn.substring(0, i) : fn;
  }

  /// 保存済みの本体。東方靈異伝などの .mdt は .mdt のまま、PMDは .m で保存する。
  static File srcFile(Directory pd, String stem) {
    _dir ??= pd;
    final mi = File('${pd.path}/pmdsrc/$stem.mid');
    if (mi.existsSync()) return mi;
    final mu = File('${pd.path}/pmdsrc/$stem.mus');
    if (mu.existsSync()) return mu;
    final t = File('${pd.path}/pmdsrc/$stem.mdt');
    if (t.existsSync()) return t;
    final w = File('${pd.path}/pmdsrc/$stem.wm');
    if (w.existsSync()) return w;
    final pa = File('${pd.path}/pmdsrc/$stem.pai');
    if (pa.existsSync()) return pa;
    final fa = File('${pd.path}/pmdsrc/$stem.fal');
    if (fa.existsSync()) return fa;
    return File('${pd.path}/pmdsrc/$stem.m');
  }

  /// PMD本体が保存されているか(同期で調べる)
  static bool hasSrc(Directory? pd, String fn) =>
      pd != null && srcFile(pd, _stemOf(fn)).existsSync();

  // ---- MIDI用の SoundFont ------------------------------------------

  static const _bundledSf2 = 'GeneralUser-GS.sf2';

  /// 音色ファイル置き場に SoundFont が無ければ、アプリに同梱の GeneralUser GS を置く
  static Future<void> ensureSoundFont() async {
    final d = await libDir();
    await for (final e in d.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.sf2') && e.lengthSync() > 1024) return;
    }
    final data = await rootBundle.load('assets/$_bundledSf2');
    final tmp = File('${d.path}/$_bundledSf2.tmp');
    await tmp.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    await tmp.rename('${d.path}/$_bundledSf2');
  }

  static Future<void> addSource(
      Directory pd, String srcPath, String stem) async {
    final d = Directory('${pd.path}/pmdsrc');
    if (!await d.exists()) await d.create(recursive: true);
    await File(srcPath).copy('${d.path}/$stem${_srcExt(srcPath)}');
  }

  // ---- ネイティブ呼び出し(同時に1つだけ) --------------------------
  // pmdmini は同時に1曲しか扱えないので、順番待ちにする。

  static Future<void> _tail = Future.value();

  static Future<T> _serial<T>(Future<T> Function() job) {
    final run = _tail.then((_) => job());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// PMDとして読めて、長さがあるか調べる(変換はしない)
  static Future<bool> probe(String pmdPath) async {
    final libPath = (await libDir()).path;
    final kind = _kind(pmdPath);
    final n = await _serial(() => Isolate.run(() {
          final so = DynamicLibrary.open('libpmdwav.so');
          final fn = so.lookupFunction<_ProbeC, _ProbeD>('${kind}_probe');
          final a = pmdPath.toNativeUtf8();
          final b = libPath.toNativeUtf8();
          final title = calloc<Uint8>(256).cast<Utf8>();
          final compo = calloc<Uint8>(256).cast<Utf8>();
          try {
            return fn(a, b, title, compo);
          } finally {
            calloc.free(a);
            calloc.free(b);
            calloc.free(title);
            calloc.free(compo);
          }
        }));
    return n > 0;
  }

  /// PMD → WAV(16bit/ステレオ)。成功したら null、失敗したら理由を返す。
  static Future<String?> toWav(
    String pmdPath,
    String wavPath, {
    int loops = 2,
    int fadeSec = 4,
    int rate = 44100,
  }) async {
    final libPath = (await libDir()).path;
    final kind = _kind(pmdPath);
    if (kind == 'mid' || kind == 'mus') {
      try {
        await ensureSoundFont();
      } catch (_) {
        return 'MIDI用の音色（SoundFont）を用意できませんでした';
      }
    }
    final code = await _serial(() => Isolate.run(() {
          final so = DynamicLibrary.open('libpmdwav.so');
          final fn = so.lookupFunction<_ToWavC, _ToWavD>('${kind}_to_wav');
          final a = pmdPath.toNativeUtf8();
          final b = libPath.toNativeUtf8();
          final c = wavPath.toNativeUtf8();
          final title = calloc<Uint8>(256).cast<Utf8>();
          final compo = calloc<Uint8>(256).cast<Utf8>();
          try {
            return fn(a, b, c, rate, loops, fadeSec, title, compo);
          } finally {
            calloc.free(a);
            calloc.free(b);
            calloc.free(c);
            calloc.free(title);
            calloc.free(compo);
          }
        }));
    if (code == 0) return null;
    if (code == 1) return 'PMDとして読めませんでした';
    if (code == 2) return 'WAVを書き出せませんでした';
    if (code == 3) return 'MIDI用の音色（SoundFont）が読めませんでした';
    return '変換に失敗しました($code)';
  }

  // ---- 必要なときだけWAVを作る -------------------------------------

  static final Map<String, Future<String?>> _jobs = {};

  /// スマホ内ファイル置き場に、fn(=〇〇.wav)があればそのパスを返す。
  /// 無くてPMD本体があれば、WAVを作ってから返す。どちらも無ければ null。
  static Future<String?> ensureWav(Directory? pd, String fn) async {
    if (pd == null) return null;
    final wav = File('${pd.path}/$fn');
    try {
      if (await wav.exists()) {
        try {
          await wav.setLastModified(DateTime.now());
        } catch (_) {}
        return wav.path;
      }
      final src = srcFile(pd, _stemOf(fn));
      if (!await src.exists()) return null;
      final running = _jobs[fn];
      if (running != null) return await running;
      final job = _render(pd, fn, src, wav);
      _jobs[fn] = job;
      try {
        return await job;
      } finally {
        _jobs.remove(fn);
      }
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _render(
      Directory pd, String fn, File src, File wav) async {
    // 途中のファイルは、掃除の対象にならない pmdsrc の中に書く
    final tmp = '${pd.path}/pmdsrc/$fn.tmp';
    final err = await toWav(src.path, tmp);
    if (err != null) {
      try {
        await File(tmp).delete();
      } catch (_) {}
      return null;
    }
    await File(tmp).rename(wav.path);
    return wav.path;
  }

  /// PMD由来のWAVだけ消す(PMD本体があるので、また作れる)
  static Future<void> dropWav(Directory? pd, String fn) async {
    if (pd == null || !hasSrc(pd, fn)) return;
    if (!fn.toLowerCase().endsWith('.wav')) return; // AAC にして残したものは消さない
    try {
      await File('${pd.path}/$fn').delete();
    } catch (_) {}
  }

  /// PMD由来のWAVを、新しい順に max 個だけ残す(keepFn は必ず残す)
  static Future<void> trim(Directory? pd, String keepFn, {int max = 4}) async {
    if (pd == null) return;
    try {
      final files = <File>[];
      await for (final e in pd.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (name == keepFn) continue;
        if (!name.toLowerCase().endsWith('.wav')) continue; // AAC にして残したものは消さない
        if (!srcFile(pd, _stemOf(name)).existsSync()) continue;
        files.add(e);
      }
      if (files.length < max) return;
      final times = <String, DateTime>{};
      for (final f in files) {
        times[f.path] = f.lastModifiedSync();
      }
      files.sort((a, b) => times[b.path]!.compareTo(times[a.path]!));
      for (final f in files.skip(max - 1)) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
