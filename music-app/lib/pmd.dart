import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
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
  static const songExts = {'m', 'm2', 'mz', 'mp', 'mdt'};

  static bool _isMdt(String path) => path.toLowerCase().endsWith('.mdt');

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
    final t = File('${pd.path}/pmdsrc/$stem.mdt');
    if (t.existsSync()) return t;
    return File('${pd.path}/pmdsrc/$stem.m');
  }

  /// PMD本体が保存されているか(同期で調べる)
  static bool hasSrc(Directory? pd, String fn) =>
      pd != null && srcFile(pd, _stemOf(fn)).existsSync();

  static Future<void> addSource(
      Directory pd, String srcPath, String stem) async {
    final d = Directory('${pd.path}/pmdsrc');
    if (!await d.exists()) await d.create(recursive: true);
    await File(srcPath).copy('${d.path}/$stem${_isMdt(srcPath) ? '.mdt' : '.m'}');
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
    final isMdt = _isMdt(pmdPath);
    final n = await _serial(() => Isolate.run(() {
          final so = DynamicLibrary.open('libpmdwav.so');
          final fn = so.lookupFunction<_ProbeC, _ProbeD>(
              isMdt ? 'mdt_probe' : 'pmd_probe');
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
    final isMdt = _isMdt(pmdPath);
    final code = await _serial(() => Isolate.run(() {
          final so = DynamicLibrary.open('libpmdwav.so');
          final fn = so.lookupFunction<_ToWavC, _ToWavD>(
              isMdt ? 'mdt_to_wav' : 'pmd_to_wav');
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
