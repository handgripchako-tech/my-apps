// MUSIC - test-server 音楽プレーヤー (Flutter / just_audio / audio_service)
// サーバー側は music.py の /music/api/* を使う。リストはウェブ版と共通 (state.json)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'lufs.dart';
import 'pmd.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data' as vz_td;

// ------------------------------------------------------------ 設定・配色
const String kDefaultBase = 'https://test-server.tail71fb16.ts.net';
const String kMono = 'DotGothic16';
const double kRow = 46.0;

const Color kBg = Color(0xFF000000);
const Color kLine = Color(0xFFC8C8C8);
const Color kYellow = Color(0xFFFFE600);
const Color kCyan = Color(0xFF00E5E5);
const Color kGreen = Color(0xFF39FF39);
const Color kRed = Color(0xFFFF4040);
const Color kBtn = Color(0xFFB4B4B4);
const Color kTxt = Color(0xFFF2F2F2);
const Color kMut = Color(0xFF9A9A9A);

final GlobalKey<ScaffoldMessengerState> msgKey =
    GlobalKey<ScaffoldMessengerState>();

void toast(String m) {
  final st = msgKey.currentState;
  if (st == null) return;
  st.hideCurrentSnackBar();
  st.showSnackBar(SnackBar(
    content: Text(m, style: const TextStyle(fontFamily: kMono, color: kTxt)),
    duration: const Duration(milliseconds: 1800),
    backgroundColor: const Color(0xFF262626),
    behavior: SnackBarBehavior.floating,
  ));
}

// ------------------------------------------------------------ モデル
int _uidN = 0;
final Random _rnd = Random();
String _uid() =>
    '${(_uidN++).toRadixString(36)}${_rnd.nextInt(1 << 30).toRadixString(36)}';

// 保存ファイルの名前用の短いハッシュ (曲ごとに固定)
String _hash(String s) {
  var a = 0x811c9dc5;
  var b = 0x9747b28c;
  for (final x in utf8.encode(s)) {
    a = ((a ^ x) * 0x01000193) & 0xFFFFFFFF;
    b = ((b ^ (x + 31)) * 0x01000193) & 0xFFFFFFFF;
  }
  return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
}

String _stem(String path) {
  final n = path.split('/').last;
  final i = n.lastIndexOf('.');
  return i > 0 ? n.substring(0, i) : n;
}

String _fmt(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class Item {
  final String u;
  final String p;
  final String? m;
  final String t;
  double? l; // スマホ内の曲の音量(LUFS)。サーバーで測ってもらった値
  Item({required this.u, required this.p, this.m, required this.t, this.l});

  // サーバー上の同じ曲なら同じキー (スマホ保存の識別に使う)
  late final String key = _hash('$p|${m ?? ''}');

  // スマホ内のファイルから追加した曲 (サーバーには無い)
  bool get isPhone => p.startsWith('local:');

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        u: (j['u'] ?? _uid()).toString(),
        p: j['p'].toString(),
        m: j['m']?.toString(),
        t: (j['t'] ?? '').toString(),
        l: (j['l'] is num && (j['l'] as num) != 0) ? (j['l'] as num).toDouble() : null, // 0.0 は測定失敗の印
      );

  Map<String, dynamic> toJson() =>
      {'u': u, 'p': p, 'm': m, 't': t, if (l != null) 'l': l};
}

class PList {
  String id;
  String name;
  List<Item> items;
  bool offline;
  PList({
    required this.id,
    required this.name,
    required this.items,
    this.offline = false,
  });
}

class AppState {
  List<PList> pls;
  String? cur;
  bool shuffle;
  bool norm;
  bool viz; // スペアナ・鍵盤の表示 (OFFなら描画も解析データの取得もしない。電池節約)
  String dir;

  AppState({
    List<PList>? pls,
    this.cur,
    this.shuffle = false,
    this.norm = true,
    this.viz = false,
    this.dir = '',
  }) : pls = pls ?? [];

  factory AppState.fromJson(Map<String, dynamic> j) {
    final s = AppState();
    final pls = j['pls'];
    if (pls is List) {
      for (final p in pls) {
        if (p is! Map) continue;
        final items = <Item>[];
        final its = p['items'];
        if (its is List) {
          for (final x in its) {
            if (x is Map && x['p'] != null) {
              items.add(Item.fromJson(x.cast<String, dynamic>()));
            }
          }
        }
        s.pls.add(PList(
          id: (p['id'] ?? _uid()).toString(),
          name: (p['name'] ?? 'リスト').toString(),
          items: items,
          offline: p['off'] == true,
        ));
      }
    }
    s.cur = j['cur']?.toString();
    s.shuffle = j['shuffle'] == true;
    s.norm = j['norm'] != false;
    s.viz = j['viz'] == true;
    s.dir = (j['dir'] ?? '').toString();
    return s;
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'pls': [
          for (final p in pls)
            {
              'id': p.id,
              'name': p.name,
              'off': p.offline,
              'items': [for (final i in p.items) i.toJson()],
            }
        ],
        'cur': cur,
        'shuffle': shuffle,
        'norm': norm,
        'viz': viz,
        'dir': dir,
      };
}

// ------------------------------------------------------------ サーバーAPI
class ApiError implements Exception {
  final String msg;
  ApiError(this.msg);
  @override
  String toString() => msg;
}

class Api {
  String base;
  final http.Client c = http.Client();
  Api(this.base);

  Uri _u(String path, [Map<String, String>? q]) {
    final b = Uri.parse(base);
    return b.replace(path: '/music/api/$path', queryParameters: q);
  }

  Future<dynamic> _get(Uri u, {int sec = 30}) async {
    final r = await c.get(u).timeout(Duration(seconds: sec));
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (r.statusCode != 200) {
      throw ApiError(body is Map && body['error'] != null
          ? body['error'].toString()
          : 'HTTP ${r.statusCode}');
    }
    return body;
  }

  Future<Map<String, dynamic>?> loadState() async {
    final j = await _get(_u('state'));
    if (j is Map) return j.cast<String, dynamic>();
    return null;
  }

  Future<void> saveState(Map<String, dynamic> s) async {
    await c
        .post(_u('state'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode(s))
        .timeout(const Duration(seconds: 20));
  }

  Future<Map<String, dynamic>> ls(String d) async {
    final j = await _get(_u('ls', {'d': d}));
    return (j as Map).cast<String, dynamic>();
  }

  Future<List<Item>> tracks(String p) async {
    final j = await _get(_u('tracks', {'p': p}), sec: 300);
    final l = (j as Map)['items'] as List;
    return [
      for (final e in l) Item.fromJson((e as Map).cast<String, dynamic>())
    ];
  }

  Map<String, String> _q(Item it) {
    final m = it.m;
    return {'p': it.p, if (m != null && m.isNotEmpty) 'm': m};
  }

  Uri fileUri(Item it) => _u('file', _q(it));
  // 端末に保存する用 (FLAC/WAV はサーバーでAAC 192kに圧縮されて届く)
  Uri dlUri(Item it) => _u('file_dl', _q(it));

  // 音量情報 {lufs, gain, ref}。plId を渡すと「そのリストで一番小さい曲」に揃えた補正値になる
  Future<Map?> gainInfo(Item it, [String? plId, int sec = 40, double? lufs]) async {
    try {
      final q = _q(it);
      if (plId != null) q['pl'] = plId;
      if (lufs != null) q['l'] = lufs.toString();
      final j = await _get(_u('gain', q), sec: sec);
      return j is Map ? j : null;
    } catch (_) {
      return null;
    }
  }

  Future<double> gain(Item it, [String? plId]) async {
    final j = await gainInfo(it, plId);
    final g = j == null ? null : j['gain'];
    return g is num ? g.toDouble() : 0.0;
  }

  // スマホ内の曲をサーバーに一度だけ送って、音量(LUFS)を測ってもらう (サーバーには残らない)
  Future<double?> uploadLufs(File f, String ext) async {
    try {
      final len = await f.length();
      if (len > 150 * 1024 * 1024) return null;
      final req = http.StreamedRequest('POST', _u('lufs_upload', {'x': ext}));
      req.contentLength = len;
      req.headers['Content-Type'] = 'application/octet-stream';
      f.openRead().listen(req.sink.add,
          onDone: req.sink.close, onError: (_) => req.sink.close());
      final res = await c.send(req).timeout(const Duration(minutes: 5));
      final body = await res.stream.bytesToString();
      if (res.statusCode != 200) return null;
      final j = jsonDecode(body);
      final l = j is Map ? j['lufs'] : null;
      return (l is num && l != 0) ? l.toDouble() : null;
    } catch (_) {
      return null;
    }
  }

  // スマホ内の WAV/FLAC をサーバーに送って AAC に圧縮してもらい、dst に保存する (サーバーには残らない)
  Future<bool> compressUpload(File src, File dst, String ext) async {
    final tmp = File('${dst.path}.part');
    try {
      final len = await src.length();
      if (len > 150 * 1024 * 1024) return false;
      final req = http.StreamedRequest('POST', _u('compress_upload', {'x': ext}));
      req.contentLength = len;
      req.headers['Content-Type'] = 'application/octet-stream';
      src.openRead().listen(req.sink.add,
          onDone: req.sink.close, onError: (_) => req.sink.close());
      final res = await c.send(req).timeout(const Duration(minutes: 15));
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        return false;
      }
      final sink = tmp.openWrite();
      try {
        await sink.addStream(res.stream.timeout(const Duration(minutes: 2)));
      } finally {
        await sink.close();
      }
      if (await tmp.length() < 1024) {
        await tmp.delete();
        return false;
      }
      await tmp.rename(dst.path);
      return true;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  // リスト内の未測定の曲を、サーバーが裏で測っておく
  Future<void> measureList(String plId) async {
    try {
      await _get(_u('measure', {'pl': plId}), sec: 10);
    } catch (_) {}
  }

  // 圧縮ファイル内の曲を先に展開させる (次の曲の先読み)
  void warm(Item it) {
    c.get(fileUri(it), headers: {'Range': 'bytes=0-0'}).then((_) {}, onError: (_) {});
  }
}

// ------------------------------------------------------------ スマホへの保存
// 「保存ON」のリストの曲を端末に保存し、リストの増減に合わせてファイルも増減する。
class Offline {
  Offline(this.h);
  final MusicHandler h;
  Directory? dir;
  Directory? phoneDir; // スマホ内のファイルを取り込む場所
  Map<String, dynamic> idx = {}; // key -> {f: ファイル名, l: 音量LUFS, n: サイズ}
  String status = '';
  bool _syncing = false;
  bool _again = false;
  bool _force = false;

  Future<void> init() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}/music_offline');
      if (!await d.exists()) await d.create(recursive: true);
      dir = d;
      final pd = Directory('${base.path}/music_local');
      if (!await pd.exists()) await pd.create(recursive: true);
      phoneDir = pd;
      final f = File('${d.path}/index.json');
      if (await f.exists()) {
        idx = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
      }
    } catch (_) {
      dir = null;
    }
    try {
      Connectivity().onConnectivityChanged.listen((r) {
        if (_isWifi(r)) requestSync();
      });
    } catch (_) {}
  }

  bool _isWifi(List<ConnectivityResult> r) =>
      r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);

  Future<bool> _wifi() async {
    try {
      return _isWifi(await Connectivity().checkConnectivity());
    } catch (_) {
      return false;
    }
  }

  Future<String> netInfo() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.map((e) => e.name).join(',');
    } catch (_) {
      return '不明';
    }
  }

  bool has(Item it) => it.isPhone
      ? (localPath(it) != null || Pmd.hasSrc(phoneDir, it.p.substring(6)))
      : idx.containsKey(it.key);

  String? localPath(Item it) {
    if (it.isPhone) {
      final pd = phoneDir;
      if (pd == null) return null;
      final pp = '${pd.path}/${it.p.substring(6)}';
      return File(pp).existsSync() ? pp : null;
    }
    final d = dir;
    final e = idx[it.key];
    if (d == null || e == null) return null;
    final p = '${d.path}/${e['f']}';
    return File(p).existsSync() ? p : null;
  }

  double? localLufs(Item it) {
    final e = idx[it.key];
    final l = e == null ? null : e['l'];
    return (l is num && l != 0) ? l.toDouble() : null; // 0.0 は測定失敗の印
  }

  int get bytes {
    var n = 0;
    for (final v in idx.values) {
      final x = v['n'];
      if (x is num) n += x.toInt();
    }
    return n;
  }

  String get summary =>
      '保存: ${idx.length}曲 / ${(bytes / 1048576).toStringAsFixed(0)}MB';

  // 端末内の使用量の内訳 (設定画面に出す。どこが大きいか調べる用)
  Future<String> usage() async {
    Future<int> sz(Directory d, {String? skip}) async {
      var n = 0;
      try {
        if (!await d.exists()) return 0;
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          if (skip != null && e.path.contains('/$skip/')) continue;
          n += await e.length();
        }
      } catch (_) {}
      return n;
    }

    String mb(int n) => '${(n / 1048576).toStringAsFixed(0)}MB';
    try {
      final base = await getApplicationDocumentsDirectory();
      final srv = await sz(Directory('${base.path}/music_offline'));
      final loc = await sz(Directory('${base.path}/music_local'), skip: 'pmdsrc');
      final src = await sz(Directory('${base.path}/music_local/pmdsrc'));
      final viz = await sz(Directory('${base.path}/music_viz'));
      final lib = await sz(Directory('${base.path}/pmdlib'));
      return '内訳: サーバー曲 ${mb(srv)} / スマホ曲(WAV含む) ${mb(loc)} / PMD本体 ${mb(src)} / 解析 ${mb(viz)} / 音色 ${mb(lib)}';
    } catch (_) {
      return '';
    }
  }

  Future<void> _saveIdx() async {
    final d = dir;
    if (d == null) return;
    try {
      await File('${d.path}/index.json').writeAsString(jsonEncode(idx));
    } catch (_) {}
  }

  // スマホ内の曲のうち音量が未測定のものを、サーバーに送って測ってもらう (Wi-Fi のとき)
  Future<void> _measurePhone() async {
    final todo = <Item>[];
    for (final pl in h.S.pls) {
      for (final it in pl.items) {
        if (it.isPhone && it.l == null) todo.add(it);
      }
    }
    if (todo.isEmpty) return;
    if (!_force && !await _wifi()) return;
    final seen = <String, double>{};
    var changed = false;
    for (final it in todo) {
      var l = seen[it.p];
      if (l == null) {
        final fn0 = it.p.substring(6);
        final had = localPath(it) != null;
        final path = had ? localPath(it) : await Pmd.ensureWav(phoneDir, fn0);
        if (path == null) continue;
        status = 'スマホ内の曲の音量を測定中';
        h.notifyUi();
        // WAV(PMD由来など)は端末内で測る (送らないので速く、オフラインでも可)。測れなければサーバーに送る
        l = await Lufs.ofWav(path) ?? await h.api.uploadLufs(File(path), it.p.split('.').last);
        if (!had) await Pmd.dropWav(phoneDir, fn0);
        if (l == null) break;
        seen[it.p] = l;
      }
      it.l = l;
      changed = true;
    }
    if (changed) h.saveSoon();
  }

  // PMD本体が無い、大きいスマホ内の WAV/FLAC を、サーバーで AAC 192k に圧縮して置き換える (Wi-Fi のとき)
  Future<void> _compressPhone() async {
    final pd = phoneDir;
    if (pd == null || !h.stateReady) return;
    if (!_force && !await _wifi()) return;
    final todo = <String>[];
    for (final pl in h.S.pls) {
      for (final it in pl.items) {
        if (!it.isPhone) continue;
        final fn = it.p.substring(6);
        final low = fn.toLowerCase();
        if (!(low.endsWith('.wav') || low.endsWith('.flac'))) continue;
        if (Pmd.hasSrc(pd, fn)) continue; // PMD本体があれば、WAVは自動で整理される
        if (todo.contains(fn)) continue;
        final f = File('${pd.path}/$fn');
        try {
          if (!f.existsSync() || f.lengthSync() < 8 * 1024 * 1024) continue;
        } catch (_) {
          continue;
        }
        todo.add(fn);
      }
    }
    if (todo.isEmpty) return;
    var done = 0;
    var fail = 0;
    for (final fn in todo) {
      if (!_force && !await _wifi()) break;
      if (h.nowItem?.p == 'local:$fn') continue; // 再生中のファイルは、次の機会に
      status = 'スマホ内の曲を圧縮中 ${done + 1}/${todo.length}';
      h.notifyUi();
      final dot = fn.lastIndexOf('.');
      final stem = fn.substring(0, dot);
      final dst = File('${pd.path}/$stem.m4a');
      final ok = await h.api.compressUpload(
          File('${pd.path}/$fn'), dst, fn.substring(dot + 1).toLowerCase());
      if (!ok) {
        if (++fail >= 3) break; // サーバーが落ちているときは、続けない
        continue;
      }
      h.replacePhoneFile('local:$fn', 'local:$stem.m4a');
      try {
        await File('${pd.path}/$fn').delete();
      } catch (_) {}
      done++;
    }
    h.notifyUi();
  }

  // どのリストにも無くなったスマホ内ファイルの取り込みコピーを消す
  Future<void> gcPhone() async {
    final pd = phoneDir;
    if (pd == null || !h.stateReady) return;
    try {
      final used = <String>{};
      for (final pl in h.S.pls) {
        for (final it in pl.items) {
          if (it.isPhone) used.add(it.p.substring(6));
        }
      }
      await for (final e in pd.list()) {
        if (e is File && !used.contains(e.uri.pathSegments.last)) {
          try {
            // 圧縮の置き換え直後のファイルを巻き込まないよう、できたばかりのものは残す
            if (DateTime.now().difference(e.lastModifiedSync()).inMinutes < 3) continue;
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> requestSync({bool force = false}) async {
    if (dir == null) return;
    if (force) _force = true;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _again = false;
        await _run();
      } while (_again);
    } catch (_) {
    } finally {
      _syncing = false;
      _force = false;
      h.notifyUi();
    }
  }

  Future<void> _run() async {
    final d = dir!;
    if (!h.stateReady) return; // リストを読み込む前は、何も消さない・何も落とさない
    final want = <String, Item>{};
    for (final pl in h.S.pls) {
      if (!pl.offline) continue;
      for (final it in pl.items) {
        if (it.isPhone) continue;
        want.putIfAbsent(it.key, () => it);
      }
    }
    // 1) リストから無くなった曲・消えたファイルを整理
    var changed = false;
    for (final k in idx.keys.toList()) {
      final f = idx[k]['f'].toString();
      final missing = !File('${d.path}/$f').existsSync();
      if (!want.containsKey(k) || missing) {
        try {
          if (!missing) await File('${d.path}/$f').delete();
        } catch (_) {}
        idx.remove(k);
        changed = true;
      }
    }
    try {
      final known = <String>{'index.json'};
      for (final v in idx.values) {
        known.add(v['f'].toString());
      }
      await for (final e in d.list()) {
        if (e is! File) continue;
        final n = e.uri.pathSegments.last;
        if (!known.contains(n)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (changed) await _saveIdx();

    // 音量(LUFS)が未記録の保存済み曲は、つながるときに補っておく (オフラインでも揃えられるように)
    for (final k in idx.keys.toList()) {
      final it = want[k];
      if (it == null || (idx[k]['l'] != null && idx[k]['l'] != 0)) continue;
      final j = await h.api.gainInfo(it, null, 15);
      final l = j == null ? null : j['lufs'];
      if (l is! num) break;
      idx[k]['l'] = l.toDouble();
      await _saveIdx();
    }

    await _compressPhone();
    await _measurePhone();
    if (_force || await _wifi()) {
      // 全リストの音量測定をサーバーに頼む (基準になる一番静かな曲を、先に確定させる)
      if (h.S.norm) {
        for (final pl in h.S.pls.toList()) {
          await h.api.measureList(pl.id);
        }
      }
      if (h.S.viz) await VizStore.prefetchAll(h);
    }

    // 2) 足りない曲をダウンロード (Wi-Fi のときだけ。「今すぐ保存」は回線を問わない)
    // 無圧縮・可逆圧縮(FLAC/WAV)のまま保存してある曲は、圧縮版に入れ替える (古いファイルは後で自動で消える)
    bool big(String k) {
      final f = (idx[k]['f'] ?? '').toString().toLowerCase();
      return f.endsWith('.flac') || f.endsWith('.wav');
    }

    final todo = want.entries.where((e) => !idx.containsKey(e.key) || big(e.key)).toList();
    final total = want.length;
    var done = total - todo.length;
    if (todo.isEmpty) {
      status = total == 0 ? '' : '保存済み $total曲';
      h.notifyUi();
      return;
    }
    var failed = 0;
    for (final e in todo) {
      if (!_force && !await _wifi()) {
        status = 'Wi-Fi待ち $done/$total曲';
        h.notifyUi();
        return;
      }
      status = '保存中 ${done + 1}/$total曲';
      h.notifyUi();
      if (await _download(e.key, e.value)) {
        done++;
      } else {
        failed++;
      }
      if (_again) return;
    }
    status = failed == 0 ? '保存済み $done/$total曲' : '保存済み $done/$total曲（失敗$failed）';
    h.notifyUi();
  }

  String _extOf(String? ct) {
    final c = (ct ?? '').toLowerCase();
    if (c.contains('mpeg')) return 'mp3';
    if (c.contains('mp4')) return 'm4a';
    if (c.contains('aac')) return 'aac';
    if (c.contains('flac')) return 'flac';
    if (c.contains('ogg')) return 'ogg';
    if (c.contains('wav')) return 'wav';
    return 'bin';
  }

  Future<bool> _download(String key, Item it) async {
    final d = dir!;
    final tmp = File('${d.path}/$key.part');
    try {
      final req = http.Request('GET', h.api.dlUri(it));
      // 圧縮に時間がかかる曲があるので、最初の返事は長めに待つ
      final res = await h.api.c.send(req).timeout(const Duration(minutes: 10));
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        return false;
      }
      final name = '$key.${_extOf(res.headers['content-type'])}';
      final sink = tmp.openWrite();
      try {
        await sink.addStream(res.stream.timeout(const Duration(seconds: 60)));
      } finally {
        await sink.close();
      }
      await tmp.rename('${d.path}/$name');
      final j = await h.api.gainInfo(it, null, 30);
      final l = j == null ? null : j['lufs'];
      final n = await File('${d.path}/$name').length();
      final old = idx[key] == null ? null : idx[key]['f']?.toString();
      idx[key] = {'f': name, 'l': l is num ? l.toDouble() : null, 'n': n};
      if (old != null && old != name) {
        try {
          await File('${d.path}/$old').delete(); // 入れ替え前の大きいファイルを消す
        } catch (_) {}
      }
      await _saveIdx();
      return true;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }
}

// ------------------------------------------------------------ プレーヤー本体
late MusicHandler handler;
String? svcError; // 通知サービスの初期化エラー (診断用)

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    handler = await AudioService.init(
      builder: () => MusicHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.chako.music_app.playback',
        androidNotificationChannelName: 'MUSIC再生',
      ),
    );
  } catch (e) {
    svcError = '$e';
    handler = MusicHandler();
  }
  runApp(const MusicApp());
}

class MusicHandler extends BaseAudioHandler with SeekHandler {
  // 他アプリ(ゲーム等)に音声フォーカスを奪われても止めない。着信など一時的な割り込みだけ止める
  final AudioPlayer player = AudioPlayer(handleInterruptions: false);
  bool _pausedByCall = false;
  final ValueNotifier<int> rev = ValueNotifier<int>(0);
  Api api = Api(kDefaultBase);
  AppState S = AppState();
  late final Offline off = Offline(this);

  String? playPl;
  String? playU;
  List<String> order = [];
  double gainDb = 0;
  bool loading = true;
  // リスト情報を読み込めた後だけ true。読み込み前に保存の同期が走って、保存済みの曲を消さないための印
  bool stateReady = false;
  String? error;

  int _seq = 0;
  int _err = 0;
  int _errSeq = -1;
  int _endSeq = -1;
  Timer? _saveT;
  bool _inited = false;

  MusicHandler() {
    _ensureDefault();
    _initSession();
    player.playbackEventStream.listen((_) => _pushState(),
        onError: (Object e, StackTrace st) {
      _onError();
    });
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed && playU != null && _endSeq != _seq) {
        _endSeq = _seq;
        _step(1);
      }
      _notify();
    });
    player.playerStateStream.listen((s) {
      if (s.playing && s.processingState == ProcessingState.ready) _err = 0;
      _pushState();
      _notify();
    });
  }

  Future<void> _initSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      session.interruptionEventStream.listen((e) {
        if (e.begin) {
          // pause = 着信など一時的な割り込みのみ。duck/unknown(ゲームの恒久フォーカス)は無視
          if (e.type == AudioInterruptionType.pause && player.playing) {
            _pausedByCall = true;
            player.pause();
          }
        } else if (_pausedByCall) {
          _pausedByCall = false;
          player.play();
        }
      });
    } catch (_) {}
  }

  void _notify() => rev.value++;
  void notifyUi() => _notify();

  void _pushState() {
    try {
      final ps = player.processingState;
      final loading =
          ps == ProcessingState.loading || ps == ProcessingState.buffering;
      playbackState.add(PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (player.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: ps == ProcessingState.idle
            ? AudioProcessingState.idle
            : (loading ? AudioProcessingState.buffering : AudioProcessingState.ready),
        playing: player.playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ));
    } catch (_) {}
  }

  // ---------------- 状態
  void _ensureDefault() {
    if (S.pls.isEmpty) {
      S.pls.add(PList(id: _uid(), name: 'リスト1', items: []));
    }
    if (_pl(S.cur) == null) S.cur = S.pls.first.id;
  }

  PList? _pl(String? id) {
    for (final p in S.pls) {
      if (p.id == id) return p;
    }
    return null;
  }

  PList get curPl => _pl(S.cur) ?? S.pls.first;

  Item? get nowItem {
    final pl = _pl(playPl);
    final u = playU;
    if (pl == null || u == null) return null;
    for (final i in pl.items) {
      if (i.u == u) return i;
    }
    return null;
  }

  bool get isPlaying => player.playing && playU != null;

  String get subText {
    final it = nowItem;
    final pl = _pl(playPl);
    if (it == null || pl == null) return '';
    final n = pl.items.indexWhere((x) => x.u == it.u) + 1;
    var s = '${pl.name}  $n/${pl.items.length}';
    if (S.norm && gainDb < 0) s += '  補正 ${gainDb.toStringAsFixed(1)}dB';
    return s;
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final prefs = await SharedPreferences.getInstance();
    api = Api(prefs.getString('base') ?? kDefaultBase);
    await off.init();
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {}
    await reload();
  }

  Future<void> reload() async {
    loading = true;
    error = null;
    _notify();
    Map<String, dynamic>? j;
    try {
      j = await api.loadState();
    } catch (e) {
      error = 'サーバーに接続できません';
    }
    if (j == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final c = prefs.getString('state');
        if (c != null) j = (jsonDecode(c) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    final got = j != null && j['pls'] is List && (j['pls'] as List).isNotEmpty;
    S = AppState.fromJson(j ?? {});
    _ensureDefault();
    stateReady = got;
    loading = false;
    _notify();
    unawaited(off.requestSync());
  }

  Future<void> setBase(String s) async {
    var b = s.replaceAll(RegExp('[\'"`\\s]'), '');
    if (b.isEmpty) b = kDefaultBase;
    if (!b.contains('://')) b = b.contains('.ts.net') ? 'https://$b' : 'http://$b';
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base', b);
    api.base = b;
    await reload();
  }

  void saveSoon() => _save();

  // スマホ内ファイルの名前が変わったとき (圧縮して .m4a になったとき) に、全リストの曲を差し替える
  void replacePhoneFile(String oldP, String newP) {
    for (final pl in S.pls) {
      for (var i = 0; i < pl.items.length; i++) {
        final it = pl.items[i];
        if (it.p == oldP) {
          pl.items[i] = Item(u: it.u, p: newP, m: it.m, t: it.t, l: it.l);
        }
      }
    }
    _save();
    _notify();
  }

  void _save() {
    _saveT?.cancel();
    _saveT = Timer(const Duration(milliseconds: 500), () async {
      final js = S.toJson();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('state', jsonEncode(js));
      } catch (_) {}
      unawaited(off.requestSync());
      unawaited(off.gcPhone());
      try {
        await api.saveState(js);
      } catch (_) {}
    });
  }

  // ---------------- 再生
  List<String> _buildOrder(PList pl, String? first) {
    final us = pl.items.map((i) => i.u).toList();
    if (!S.shuffle) return us;
    final rest = us.where((u) => u != first).toList()..shuffle(_rnd);
    return us.contains(first) ? [first!, ...rest] : rest;
  }

  Future<void> _setGain(double g) async {
    gainDb = g;
    var v = pow(10, g / 20).toDouble();
    if (v > 1) v = 1.0;
    if (v < 0) v = 0.0;
    await player.setVolume(v);
  }

  Future<void> playItem(String plId, String u) async {
    final pl = _pl(plId);
    if (pl == null) return;
    final idx = pl.items.indexWhere((x) => x.u == u);
    if (idx < 0) return;
    final it = pl.items[idx];
    final changed = playPl != plId;
    playPl = plId;
    playU = u;
    if (changed || !order.contains(u)) order = _buildOrder(pl, u);
    final my = ++_seq;
    mediaItem.add(MediaItem(id: it.u, title: it.t, album: pl.name, artist: pl.name));
    _pushState();
    _notify();
    try {
      if (it.isPhone &&
          off.localPath(it) == null &&
          Pmd.hasSrc(off.phoneDir, it.p.substring(6))) {
        toast('PMDを変換中…');
      }
      if (it.isPhone) await Pmd.ensureWav(off.phoneDir, it.p.substring(6));
      final local = off.localPath(it);
      var g = 0.0;
      if (S.norm) {
        final mk = '$plId:${pl.items.length}';
        if (_measKey != mk) {
          _measKey = mk;
          unawaited(api.measureList(plId));
        }
        g = await _gainFor(it, pl, local != null);
        if (my != _seq) return;
      }
      await _setGain(g);
      Duration? dur;
      if (local != null) {
        try {
          dur = await player.setFilePath(local);
        } catch (_) {
          dur = await player.setUrl(api.fileUri(it).toString());
        }
      } else {
        dur = await player.setUrl(api.fileUri(it).toString());
      }
      if (my != _seq) return;
      if (dur != null) {
        mediaItem.add(MediaItem(
            id: it.u, title: it.t, album: pl.name, artist: pl.name, duration: dur));
      }
      unawaited(player.play());
      _pushState();
      _notify();
      unawaited(Pmd.trim(off.phoneDir, it.p.substring(6)));
      _prepNext();
    } catch (e) {
      if (my == _seq) _onError();
    }
  }

  String _measKey = '';

  final Map<String, double> _refCache = {}; // リストID → サーバーが返した基準(一番小さい音量)

  Future<void> _refreshRef(Item it, PList pl, double l) async {
    try {
      final j = await api.gainInfo(it, pl.id, 6, it.isPhone ? l : null);
      final r = j == null ? null : j['ref'];
      if (r is num && r != 0) _refCache[pl.id] = r.toDouble();
    } catch (_) {}
  }

  // リスト内で一番小さい曲に揃える補正値(dB, 0以下)。サーバーに届かないときは端末内の測定値で計算する
  Future<double> _gainFor(Item it, PList pl, bool isLocal) async {
    double? lu(Item x) => x.isPhone ? x.l : off.localLufs(x);
    final l = lu(it);
    if (it.isPhone && l == null) return 0.0; // まだ測定前のスマホ内の曲は補正なし
    final allLocal = pl.items.every((x) => (x.isPhone && x.l == null) || lu(x) != null);
    if (isLocal && l != null) {
      // 保存済みの曲は、サーバーを待たずに端末内の値で決める (車など圏外で曲送りが遅れないように)。
      // サーバーが知っている基準(リスト全体で一番小さい音量)は、前に聞けたぶんを使い、裏で更新しておく
      if (!allLocal) unawaited(_refreshRef(it, pl, l));
      var ref = l;
      for (final x in pl.items) {
        final v = lu(x);
        if (v != null && v < ref) ref = v;
      }
      final c = _refCache[pl.id];
      if (c != null && c < ref) ref = c;
      return max(-30.0, min(0.0, ref - l));
    }
    if (!(isLocal && l != null && allLocal)) {
      final j = await api.gainInfo(it, pl.id, isLocal ? 10 : 40, it.isPhone ? l : null);
      if (j != null) {
        final g = j['gain'];
        return g is num ? g.toDouble() : 0.0;
      }
    }
    if (l == null) return 0.0;
    var ref = l;
    for (final x in pl.items) {
      final v = lu(x);
      if (v != null && v < ref) ref = v;
    }
    return max(-30.0, min(0.0, ref - l));
  }

  void _prepNext() {
    final pl = _pl(playPl);
    if (pl == null || pl.items.length < 2 || order.isEmpty) return;
    final i = order.indexOf(playU ?? '');
    final nu = order[(i + 1) % order.length];
    for (final it in pl.items) {
      if (it.u != nu) continue;
      if (it.isPhone) {
        unawaited(Pmd.ensureWav(off.phoneDir, it.p.substring(6)));
        break;
      }
      if (off.has(it)) break;
      if (S.norm) {
        api.gainInfo(it, playPl);
      } else if (it.m != null && it.m!.isNotEmpty) {
        api.warm(it);
      }
      break;
    }
  }

  Future<void> _step(int d) async {
    final pl = _pl(playPl);
    if (pl == null || pl.items.isEmpty) return;
    if (order.isEmpty) order = _buildOrder(pl, playU);
    final n = order.length;
    final i = order.indexOf(playU ?? '');
    final nu = order[(((i + d) % n) + n) % n];
    await playItem(pl.id, nu);
  }

  void _onError() {
    if (_errSeq == _seq) return;
    _errSeq = _seq;
    _err++;
    toast('再生できません');
    if (_err < 4) {
      Future.delayed(const Duration(milliseconds: 500), () => _step(1));
    } else {
      _err = 0;
      stop();
    }
  }

  Future<void> startViewed() async {
    final pl = curPl;
    if (pl.items.isEmpty) {
      toast('曲がありません');
      return;
    }
    final it = S.shuffle ? pl.items[_rnd.nextInt(pl.items.length)] : pl.items.first;
    order = [];
    await playItem(pl.id, it.u);
  }

  bool get _hasSource =>
      playU != null && player.processingState != ProcessingState.idle;

  Future<void> togglePlay() async {
    if (_hasSource && player.playing) {
      await pause();
      return;
    }
    if (_hasSource && playPl == S.cur) {
      unawaited(player.play());
      return;
    }
    await startViewed();
  }

  // 通知バー・ロック画面・ヘッドセットからの操作
  @override
  Future<void> play() async {
    if (_hasSource) {
      unawaited(player.play());
    } else {
      await startViewed();
    }
  }

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() async {
    _seq++;
    await player.stop();
    playU = null;
    order = [];
    gainDb = 0;
    mediaItem.add(null);
    _notify();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (playU != null) {
      await _step(1);
    } else {
      await startViewed();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (playU == null) return;
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
    } else {
      await _step(-1);
    }
  }

  void toggleShuffle() {
    S.shuffle = !S.shuffle;
    final pl = _pl(playPl);
    if (pl != null) order = _buildOrder(pl, playU);
    _save();
    _notify();
    toast(S.shuffle ? 'シャッフル ON' : 'シャッフル OFF');
  }

  void toggleViz() {
    S.viz = !S.viz;
    _save();
    _notify();
    toast(S.viz ? 'スペアナ ON' : 'スペアナ OFF');
  }

  Future<void> toggleNorm() async {
    S.norm = !S.norm;
    _save();
    _notify();
    toast(S.norm ? 'ノーマライズ ON' : 'ノーマライズ OFF');
    final it = nowItem;
    if (it == null) return;
    if (S.norm) {
      final pl = _pl(playPl);
      if (pl != null) unawaited(api.measureList(pl.id));
      final g = pl == null ? 0.0 : await _gainFor(it, pl, off.has(it));
      if (nowItem?.u == it.u) await _setGain(g);
    } else {
      await _setGain(0);
    }
    _notify();
  }

  // ---------------- リスト・曲の操作
  void selectPl(String id) {
    if (S.cur == id) return;
    S.cur = id;
    _save();
    _notify();
  }

  void newPl(String name) {
    final pl = PList(
        id: _uid(), name: name.trim().isEmpty ? 'リスト' : name.trim(), items: []);
    S.pls.add(pl);
    S.cur = pl.id;
    _save();
    _notify();
  }

  void renamePl(String name) {
    final n = name.trim();
    if (n.isEmpty) return;
    curPl.name = n;
    _save();
    _notify();
  }

  void toggleOffline() {
    final pl = curPl;
    pl.offline = !pl.offline;
    _save();
    _notify();
    toast(pl.offline ? 'スマホに保存: ON（Wi-Fiで保存します）' : 'スマホに保存: OFF（保存済みを削除します）');
  }

  void syncNow() {
    toast('保存を開始します');
    off.requestSync(force: true);
  }

  Future<void> clearPl() async {
    final pl = curPl;
    if (playPl == pl.id) await stop();
    pl.items = [];
    _save();
    _notify();
  }

  Future<void> deletePl() async {
    final pl = curPl;
    if (playPl == pl.id) await stop();
    final i = S.pls.indexOf(pl);
    S.pls.removeAt(i);
    if (S.pls.isEmpty) {
      S.pls.add(PList(id: _uid(), name: 'リスト1', items: []));
    }
    S.cur = S.pls[max(0, i - 1)].id;
    _save();
    _notify();
  }

  void addItems(List<Item> items) {
    final pl = curPl;
    final add = [
      for (final x in items) Item(u: _uid(), p: x.p, m: x.m, t: x.t, l: x.l)
    ];
    pl.items.addAll(add);
    if (playPl == pl.id && order.isNotEmpty) {
      final us = add.map((x) => x.u).toList();
      if (S.shuffle) us.shuffle(_rnd);
      order.addAll(us);
    }
    _save();
    _notify();
    toast('${add.length}曲を追加しました');
  }

  // スマホ内の音楽ファイルを選んで、いまのリストに追加する (アプリ内にコピーして保持)
  Future<void> addPhoneFiles() async {
    try {
      final r = await FilePicker.platform
          .pickFiles(type: FileType.audio, allowMultiple: true);
      if (r == null) return;
      final pd = off.phoneDir;
      if (pd == null) {
        toast('保存場所を用意できません');
        return;
      }
      final items = <Item>[];
      for (final f in r.files) {
        final src = f.path;
        if (src == null) continue;
        final dot = f.name.lastIndexOf('.');
        final ext = dot > 0 ? f.name.substring(dot + 1).toLowerCase() : 'mp3';
        final fn = '${_hash('${f.name}|${f.size}')}.$ext';
        final dst = File('${pd.path}/$fn');
        if (!await dst.exists()) await File(src).copy(dst.path);
        items.add(Item(u: _uid(), p: 'local:$fn', m: null, t: _stem(f.name)));
      }
      if (items.isEmpty) return;
      addItems(items);
    } catch (e) {
      toast('追加できませんでした');
    }
  }

  // PMD(PC-98のFM音源曲)を選んで、WAVに変換していまのリストに追加する。
  // 音色ファイル(.PPC/.P86 とドラムの 2608_*.WAV)も一緒に選べば、アプリ内に保存される。
  Future<void> addPmdFiles() async {
    try {
      final r = await FilePicker.platform
          .pickFiles(type: FileType.any, allowMultiple: true);
      if (r == null) return;
      final pd = off.phoneDir;
      if (pd == null) {
        toast('保存場所を用意できません');
        return;
      }
      const companionExts = {'ppc', 'p86', 'pzi', 'pvi', 'pps', 'ppz', 'wav'};
      final songs = <PlatformFile>[];
      var saved = 0;
      for (final f in r.files) {
        final src = f.path;
        if (src == null) continue;
        final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
        if (Pmd.isSong(f.name)) {
          songs.add(f);
        } else if (companionExts.contains(ext)) {
          await Pmd.saveCompanion(src, f.name);
          saved++;
        }
      }
      final items = <Item>[];
      var fail = 0;
      String? lastErr;
      for (var i = 0; i < songs.length; i++) {
        final f = songs[i];
        if (!await Pmd.probe(f.path!)) {
          fail++;
          lastErr = 'PMDとして読めませんでした';
          continue;
        }
        final stem = _hash('pmd|${f.name}|${f.size}');
        try {
          await Pmd.addSource(pd, f.path!, stem);
        } catch (_) {
          fail++;
          lastErr = '保存できませんでした';
          continue;
        }
        items.add(Item(u: _uid(), p: 'local:$stem.wav', m: null, t: _stem(f.name)));
      }
      if (items.isNotEmpty) addItems(items);
      if (fail > 0) {
        toast('$fail曲を変換できませんでした: $lastErr');
      } else if (items.isEmpty && saved > 0) {
        toast('音色ファイル$saved個を保存しました');
      } else if (items.isEmpty) {
        toast('PMDの曲が選ばれていません');
      }
    } catch (e) {
      toast('PMDを追加できませんでした');
    }
  }

  Future<void> delItem(String plId, String u) async {
    final pl = _pl(plId);
    if (pl == null) return;
    final i = pl.items.indexWhere((x) => x.u == u);
    if (i < 0) return;
    if (playPl == plId && playU == u) {
      final wasPlaying = player.playing;
      String? nu;
      if (pl.items.length > 1) {
        final o = order.isNotEmpty ? order : _buildOrder(pl, u);
        final k = o.indexOf(u);
        final cand = o[(k + 1) % o.length];
        if (cand != u) nu = cand;
      }
      pl.items.removeAt(i);
      order = order.where((x) => x != u).toList();
      _save();
      if (nu != null && wasPlaying) {
        _notify();
        await playItem(plId, nu);
      } else {
        await stop();
      }
      return;
    }
    pl.items.removeAt(i);
    if (playPl == plId) order = order.where((x) => x != u).toList();
    _save();
    _notify();
  }
}

// ------------------------------------------------------------ 画面の部品 (ダッシュボード風)
// 省電力: 画面の動き(スペアナ・流れる曲名)は約30fpsに抑え、アプリが見えていないときは止める
// (画面のリフレッシュレート(最大120Hz)ごとに描き直すと電池を食うため)
class LowFps with WidgetsBindingObserver {
  LowFps(this.onTick) {
    WidgetsBinding.instance.addObserver(this);
    final st = WidgetsBinding.instance.lifecycleState;
    _visible = st == null || st == AppLifecycleState.resumed;
  }
  final VoidCallback onTick;
  static const Duration period = Duration(milliseconds: 33);
  Timer? _t;
  bool _want = false;
  bool _visible = true;
  bool get isRunning => _want;
  void start() {
    _want = true;
    _apply();
  }

  void stop() {
    _want = false;
    _apply();
  }

  void _apply() {
    final run = _want && _visible;
    if (run && _t == null) {
      _t = Timer.periodic(period, (_) => onTick());
    } else if (!run && _t != null) {
      _t!.cancel();
      _t = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _apply();
  }

  void dispose() {
    stop();
    WidgetsBinding.instance.removeObserver(this);
  }
}

// 長い曲名を右から左へ流して全部見せる (収まるときは固定表示。run=false なら流さない)
class Marquee extends StatefulWidget {
  const Marquee(this.text, {super.key, required this.style, this.run = true});
  final String text;
  final bool run;
  final TextStyle style;
  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> {
  static const double _gap = 56;
  static const double _speed = 45; // px/秒
  static const double _pause = 1.5; // 秒 (先頭で止まる)
  late final LowFps _fps = LowFps(() {
    if (mounted) setState(() {});
  });
  final Stopwatch _sw = Stopwatch();
  double _travel = 0;

  @override
  void dispose() {
    _fps.dispose();
    super.dispose();
  }

  void _setup(double textW) {
    final travel = textW + _gap;
    if ((travel - _travel).abs() < 0.5 && _fps.isRunning) return;
    _travel = travel;
    _sw
      ..reset()
      ..start();
    _fps.start();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      final h = tp.height;
      if (w <= box.maxWidth || !widget.run) {
        if (_fps.isRunning) _fps.stop();
        _travel = 0;
        return Text(widget.text,
            maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: widget.style);
      }
      _setup(w);
      final total = _travel / _speed + _pause;
      return SizedBox(
        height: h,
        child: ClipRect(
          child: Builder(
            builder: (context) {
              final sec = (_sw.elapsedMilliseconds / 1000.0) % total;
              final t = sec <= _pause ? 0.0 : (sec - _pause) / (total - _pause);
              return OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                child: Transform.translate(
                  offset: Offset(-_travel * t, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.text, maxLines: 1, softWrap: false, style: widget.style),
                      const SizedBox(width: _gap),
                      Text(widget.text, maxLines: 1, softWrap: false, style: widget.style),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    });
  }
}

class Dbl extends StatelessWidget {
  const Dbl({super.key, required this.child, this.pad = const EdgeInsets.all(10)});
  final Widget child;
  final EdgeInsets pad;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: kLine, width: 1.2)),
      padding: const EdgeInsets.all(2.5),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: kLine, width: 1.2)),
        padding: pad,
        child: child,
      ),
    );
  }
}

class RBtn extends StatelessWidget {
  const RBtn(
    this.label, {
    super.key,
    this.onTap,
    this.bg = kBtn,
    this.fg = Colors.black,
    this.border,
    this.bevel = false,
    this.fontSize = 15,
    this.pad = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  });
  final String label;
  final VoidCallback? onTap;
  final Color bg;
  final Color fg;
  final Color? border;
  final bool bevel;
  final double fontSize;
  final EdgeInsets pad;

  @override
  Widget build(BuildContext context) {
    BoxBorder? bd;
    if (bevel) {
      bd = const Border(
        top: BorderSide(color: Colors.white70, width: 2),
        left: BorderSide(color: Colors.white70, width: 2),
        bottom: BorderSide(color: Color(0xFF555555), width: 2),
        right: BorderSide(color: Color(0xFF555555), width: 2),
      );
    } else if (border != null) {
      bd = Border.all(color: border!, width: 1.2);
    }
    return Material(
      color: bg,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: bd == null ? null : BoxDecoration(border: bd),
          padding: pad,
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              fontFamily: kMono,
            ),
          ),
        ),
      ),
    );
  }
}

class StatCell extends StatelessWidget {
  const StatCell(this.label, this.on, this.onTap, {super.key});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: kLine, width: 1)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(color: kTxt, fontSize: 14, fontFamily: kMono)),
            Text(on ? '■ON' : '□OFF',
                style: TextStyle(
                    color: on ? kGreen : kRed,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    fontFamily: kMono)),
          ],
        ),
      ),
    );
  }
}

const TextStyle kTitle =
    TextStyle(color: kYellow, fontSize: 15, fontWeight: FontWeight.bold, fontFamily: kMono);
const TextStyle kMutS = TextStyle(color: kMut, fontSize: 12, fontFamily: kMono);

// ------------------------------------------------------------ ダイアログ
Future<String?> promptText(BuildContext ctx, String title, String initial,
    {String ok = 'OK', String? hint}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: ctx,
    builder: (c) => AlertDialog(
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(side: BorderSide(color: kLine, width: 1.2)),
      title: Text(title, style: kTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: ctl,
            autofocus: true,
            style: const TextStyle(color: kTxt, fontFamily: kMono),
            decoration: const InputDecoration(
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: kLine)),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: kCyan)),
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(hint, style: kMutS),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('キャンセル', style: TextStyle(color: kMut, fontFamily: kMono)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, ctl.text),
          child: Text(ok,
              style: const TextStyle(
                  color: kCyan, fontFamily: kMono, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
}

Future<bool> confirmBox(BuildContext ctx, String msg) async {
  final r = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(side: BorderSide(color: kLine, width: 1.2)),
      content: Text(msg, style: const TextStyle(color: kTxt, fontFamily: kMono)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('いいえ', style: TextStyle(color: kMut, fontFamily: kMono)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('はい',
              style: TextStyle(color: kRed, fontFamily: kMono, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  return r == true;
}

// ------------------------------------------------------------ アプリ
class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MUSIC',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: msgKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        fontFamily: kMono,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(primary: kCyan, surface: kBg),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MusicHandler h = handler;
  final ScrollController _sc = ScrollController();
  double? _drag;
  String? _lastU;

  @override
  void initState() {
    super.initState();
    h.init();
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _ensureVisible() {
    final u = h.playU;
    if (u == _lastU) return;
    _lastU = u;
    final pl = h.curPl;
    if (u == null || h.playPl != pl.id || !_sc.hasClients) return;
    final i = pl.items.indexWhere((e) => e.u == u);
    if (i < 0) return;
    final top = i * kRow;
    final pos = _sc.position;
    if (top < pos.pixels || top > pos.pixels + pos.viewportDimension - kRow) {
      _sc.animateTo(
        min(max(top - kRow * 2, 0.0), pos.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _settings() async {
    final net = await h.off.netInfo();
    final use = await h.off.usage();
    if (!mounted) return;
    final r = await promptText(context, '[ サーバーのアドレス ]', h.api.base,
        ok: '保存',
        hint: '例: http://100.102.7.80:5000' +
            (svcError != null ? '\n通知サービス異常: $svcError' : '\n通知サービス: 初期化OK') +
            '\n${h.off.summary}\n$use\n通信: $net');
    if (r != null) await h.setBase(r);
  }

  Future<void> _newPl() async {
    final r = await promptText(context, '[ 新しいリスト ]', 'リスト${h.S.pls.length + 1}',
        ok: '作成');
    if (r != null) h.newPl(r);
  }

  Future<void> _menuPl() async {
    Widget mi(BuildContext c, String label, String key, {Color fg = Colors.black}) =>
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: RBtn(label, fg: fg, onTap: () => Navigator.pop(c, key)),
        );
    final a = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        backgroundColor: kBg,
        shape: const RoundedRectangleBorder(side: BorderSide(color: kLine, width: 1.2)),
        title: Text('[ ${h.curPl.name} ]', style: kTitle),
        children: [
          mi(c, 'PMD（PC-98）を追加', 'pmd'),
          mi(c, 'スマホ内のファイルを追加', 'phone'),
          mi(c, '名前を変更', 'ren'),
          mi(c, h.curPl.offline ? 'スマホに保存: ON（タップでOFF）' : 'スマホに保存: OFF（タップでON）', 'off'),
          if (h.curPl.offline) mi(c, '今すぐ保存（回線を問わない）', 'now'),
          mi(c, '曲を全部消す', 'clr', fg: const Color(0xFF8A0000)),
          mi(c, 'このリストを削除', 'del', fg: const Color(0xFF8A0000)),
          mi(c, '閉じる', 'x'),
        ],
      ),
    );
    if (!mounted || a == null) return;
    if (a == 'ren') {
      final r = await promptText(context, '[ 名前を変更 ]', h.curPl.name, ok: '変更');
      if (r != null) h.renamePl(r);
    } else if (a == 'phone') {
      h.addPhoneFiles();
    } else if (a == 'pmd') {
      h.addPmdFiles();
    } else if (a == 'off') {
      h.toggleOffline();
    } else if (a == 'now') {
      h.syncNow();
    } else if (a == 'clr') {
      if (await confirmBox(context, '「${h.curPl.name}」の曲を全部消しますか？')) {
        await h.clearPl();
      }
    } else if (a == 'del') {
      if (await confirmBox(context, 'リスト「${h.curPl.name}」を削除しますか？')) {
        await h.deletePl();
      }
    }
  }

  void _openBrowser() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => BrowserPage(h: h)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: h.rev,
          builder: (context, _) {
            final pl = h.curPl;
            WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible());
            return Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Column(
                children: [
                  _header(),
                  if (h.error != null) _errBox(),
                  const SizedBox(height: 8),
                  _nowBox(),
                  const SizedBox(height: 8),
                  _controls(),
                  const SizedBox(height: 8),
                  _tabs(pl),
                  const SizedBox(height: 8),
                  Expanded(child: _list(pl)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Text('C:\\MUSIC>',
            style: TextStyle(
                color: kCyan, fontSize: 20, fontWeight: FontWeight.bold, fontFamily: kMono)),
        const SizedBox(width: 4),
        Container(width: 16, height: 22, color: kBtn),
        const Spacer(),
        RBtn('追加', bevel: true, onTap: _openBrowser),
        const SizedBox(width: 6),
        RBtn('設定', bevel: true, onTap: _settings),
      ],
    );
  }

  Widget _errBox() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: kRed)),
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: Text('${h.error}',
                  style: const TextStyle(color: kRed, fontSize: 13, fontFamily: kMono)),
            ),
            RBtn('再接続', bevel: true, fontSize: 13, onTap: h.reload),
          ],
        ),
      ),
    );
  }

  Widget _nowBox() {
    final it = h.nowItem;
    return Dbl(
      pad: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('[ 再生中 ]', style: kTitle),
          const SizedBox(height: 6),
          RepaintBoundary(child: Marquee(
            it?.t ?? '待機中',
            run: h.player.playing,
            style: TextStyle(
                color: it == null ? kMut : kGreen,
                fontSize: 17,
                fontWeight: FontWeight.bold,
                fontFamily: kMono),
          )),
          Text(h.subText, maxLines: 1, overflow: TextOverflow.ellipsis, style: kMutS),
          if (h.S.viz) RepaintBoundary(child: VizPanel(h: h, item: it)),
          _seekBar(),
        ],
      ),
    );
  }

  Widget _seekBar() {
    return StreamBuilder<Duration?>(
      stream: h.player.durationStream,
      builder: (context, ds) {
        final dur = ds.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: h.player.positionStream,
          builder: (context, ps) {
            final pos = ps.data ?? Duration.zero;
            final maxMs = max(dur.inMilliseconds, 1).toDouble();
            final cur =
                (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, maxMs).toDouble();
            return Row(
              children: [
                Text(_fmt(Duration(milliseconds: cur.toInt())), style: kMutS),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: kCyan,
                      inactiveTrackColor: const Color(0xFF444444),
                      thumbColor: kCyan,
                    ),
                    child: Slider(
                      value: cur,
                      min: 0,
                      max: maxMs,
                      onChanged:
                          dur == Duration.zero ? null : (v) => setState(() => _drag = v),
                      onChangeEnd: (v) async {
                        await h.seek(Duration(milliseconds: v.toInt()));
                        if (mounted) setState(() => _drag = null);
                      },
                    ),
                  ),
                ),
                Text(_fmt(dur), style: kMutS),
              ],
            );
          },
        );
      },
    );
  }

  Widget _controls() {
    final playing = h.isPlaying;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 12,
              child: RBtn('⏮', bg: kBg, fg: kTxt, border: kLine, onTap: h.skipToPrevious),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 30,
              child: RBtn(playing ? '⏸ 一時停止' : '▶ 再生',
                  bg: const Color(0xFFB00000), fg: Colors.white, onTap: h.togglePlay),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 22,
              child: RBtn('■ 停止',
                  bg: const Color(0xFFB35900), fg: Colors.white, onTap: h.stop),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 12,
              child: RBtn('⏭', bg: kBg, fg: kTxt, border: kLine, onTap: h.skipToNext),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(child: StatCell('シャッフル', h.S.shuffle, h.toggleShuffle)),
            const SizedBox(width: 6),
            Expanded(child: StatCell('ノーマライズ', h.S.norm, h.toggleNorm)),
          ],
        ),
        const SizedBox(height: 6),
        StatCell('スペアナ', h.S.viz, h.toggleViz),
      ],
    );
  }

  Widget _tabs(PList cur) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final p in h.S.pls)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: RBtn(
                      ((h.playPl == p.id && h.isPlaying) ? '♪ ' : '') + (p.offline ? '↓' : '') + p.name,
                      bevel: p.id == cur.id,
                      bg: p.id == cur.id ? kBtn : kBg,
                      fg: p.id == cur.id ? Colors.black : kTxt,
                      border: p.id == cur.id ? null : kLine,
                      onTap: () => h.selectPl(p.id),
                    ),
                  ),
                RBtn('＋', bg: kBg, fg: kCyan, border: kCyan, onTap: _newPl),
              ],
            ),
          ),
          const SizedBox(width: 6),
          RBtn('⋯', bg: kBg, fg: kTxt, border: kLine, onTap: _menuPl),
        ],
      ),
    );
  }

  Widget _list(PList pl) {
    return Dbl(
      pad: const EdgeInsets.fromLTRB(8, 6, 4, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text('[ ${pl.name} ]',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: kTitle),
              ),
              if (pl.offline && h.off.status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(h.off.status,
                      style: const TextStyle(color: kCyan, fontSize: 12, fontFamily: kMono)),
                ),
              Text('${pl.items.length}曲', style: kMutS),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: pl.items.isEmpty
                ? const Center(
                    child: Text('「追加」で曲を選んでください', style: kMutS),
                  )
                : ListView.builder(
                    controller: _sc,
                    itemExtent: kRow,
                    itemCount: pl.items.length,
                    itemBuilder: (context, i) {
                      final it = pl.items[i];
                      final now = h.playPl == pl.id && h.playU == it.u;
                      return InkWell(
                        onTap: () => h.playItem(pl.id, it.u),
                        child: Container(
                          color: now ? const Color(0xFF0A2A0A) : null,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 34,
                                child: Text('${i + 1}',
                                    textAlign: TextAlign.right, style: kMutS),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  (now ? '▶ ' : '') + (h.off.has(it) ? '↓ ' : '') + it.t,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: now ? kGreen : kTxt,
                                    fontSize: 16,
                                    letterSpacing: 0.8,
                                    fontWeight: now ? FontWeight.bold : FontWeight.normal,
                                    fontFamily: kMono,
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => h.delItem(pl.id, it.u),
                                child: const SizedBox(
                                  width: 44,
                                  height: kRow,
                                  child: Center(
                                    child: Text('✕',
                                        style: TextStyle(color: kRed, fontSize: 16)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ ファイル選択
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.h});
  final MusicHandler h;
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  String dir = '';
  String? parent;
  List<Map<String, dynamic>> ents = [];
  String? err;
  bool loading = true;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load(widget.h.S.dir);
  }

  Future<void> _load(String d) async {
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final j = await widget.h.api.ls(d);
      if (!mounted) return;
      setState(() {
        dir = (j['d'] ?? '').toString();
        parent = j['parent']?.toString();
        ents = [
          for (final e in (j['entries'] as List)) (e as Map).cast<String, dynamic>()
        ];
        loading = false;
      });
      widget.h.S.dir = dir;
      widget.h.saveSoon();
    } catch (e) {
      if (d.isNotEmpty) {
        await _load('');
        return;
      }
      if (!mounted) return;
      setState(() {
        err = '開けません: $e';
        loading = false;
      });
    }
  }

  Future<void> _add(String kind, String rel) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      List<Item> items;
      if (kind == 'audio') {
        items = [Item(u: _uid(), p: rel, t: _stem(rel))];
      } else {
        toast('読み込み中…');
        items = await widget.h.api.tracks(rel);
      }
      if (items.isEmpty) {
        toast('曲が見つかりません');
      } else {
        widget.h.addItems(items);
      }
    } catch (e) {
      toast('追加できません: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Column(
            children: [
              Row(
                children: [
                  RBtn('‹ 上へ',
                      bevel: true,
                      onTap: parent == null ? null : () => _load(parent!)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('/$dir',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kCyan, fontSize: 14, fontFamily: kMono)),
                  ),
                  const SizedBox(width: 8),
                  RBtn('閉じる', bevel: true, onTap: () => Navigator.pop(context)),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Dbl(
                  pad: const EdgeInsets.fromLTRB(6, 6, 2, 4),
                  child: loading
                      ? const Center(child: Text('読み込み中…', style: kMutS))
                      : err != null
                          ? Center(
                              child: Text(err!,
                                  style: const TextStyle(color: kRed, fontFamily: kMono)))
                          : ents.isEmpty
                              ? const Center(
                                  child: Text('（曲もフォルダもありません）', style: kMutS))
                              : ListView.builder(
                                  itemCount: ents.length,
                                  itemExtent: kRow,
                                  itemBuilder: (context, i) => _row(ents[i]),
                                ),
                ),
              ),
              const SizedBox(height: 8),
              RBtn('この階層の曲を全部追加',
                  bg: const Color(0xFF00A8A8),
                  onTap: busy ? null : () => _add('dir', dir)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> e) {
    final k = (e['k'] ?? '').toString();
    final n = (e['n'] ?? '').toString();
    final rel = dir.isEmpty ? n : '$dir/$n';
    final tag = k == 'dir' ? '[DIR]' : (k == 'arc' ? '[ARC]' : '[ ♪ ]');
    final col = k == 'dir' ? kCyan : (k == 'arc' ? kYellow : kTxt);
    return InkWell(
      onTap: () {
        if (k == 'dir') {
          _load(rel);
        } else {
          _add(k, rel);
        }
      },
      child: Row(
        children: [
          Text(tag, style: TextStyle(color: col, fontSize: 13, fontFamily: kMono)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(n,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: col, fontSize: 15, fontFamily: kMono)),
          ),
          InkWell(
            onTap: busy ? null : () => _add(k, rel),
            child: const SizedBox(
              width: 48,
              height: kRow,
              child: Center(
                child: Text('＋',
                    style: TextStyle(
                        color: kGreen, fontSize: 22, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===== ここから: スペアナ＋鍵盤 (patch_viz_app.py が追加) =====
// 音と表示がずれるときの調整 (ミリ秒)。表示が遅れて見えるなら + に、先走るなら - にする
const int kVizOffsetMs = 0;

class VizData {
  final int nb;
  final int nk;
  final int keyLo;
  final double fps;
  final int n;
  final vz_td.Uint8List _b;
  VizData._(this.nb, this.nk, this.keyLo, this.fps, this.n, this._b);

  static VizData? parse(vz_td.Uint8List d) {
    if (d.length < 13 || d[0] != 0x56 || d[1] != 0x5A || d[2] != 0x30 || d[3] != 0x31) {
      return null;
    }
    final bd = vz_td.ByteData.sublistView(d);
    final nb = d[4];
    final nk = d[5];
    final lo = d[6];
    final fps = bd.getUint16(7, vz_td.Endian.little) / 100.0;
    final n = bd.getUint32(9, vz_td.Endian.little);
    if (nb == 0 || nk == 0 || fps <= 0 || d.length < 13 + n * (nb + nk)) return null;
    return VizData._(nb, nk, lo, fps, n, d);
  }

  int band(int f, int i) => _b[13 + f * (nb + nk) + i];
  int key(int f, int k) => _b[13 + f * (nb + nk) + nb + k];
}

class VizPanel extends StatefulWidget {
  final MusicHandler h;
  final Item? item;
  const VizPanel({Key? key, required this.h, required this.item}) : super(key: key);

  @override
  State<VizPanel> createState() => _VizPanelState();
}

class _VizPanelState extends State<VizPanel> {
  static final Map<String, VizData> _cache = <String, VizData>{};
  late final LowFps _ac;
  StreamSubscription<bool>? _sub;
  VizData? _data;
  String _status = '';
  int _seq = 0;
  int _last = 0;
  List<double> _bars = List<double>.filled(32, 0.0);
  List<double> _peaks = List<double>.filled(32, 0.0);
  List<double> _keys = List<double>.filled(61, 0.0);
  int _keyLo = 36;

  @override
  void initState() {
    super.initState();
    _ac = LowFps(() {
      if (mounted) setState(() {});
    });
    _sub = widget.h.player.playingStream.listen((_) => _sync());
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(VizPanel old) {
    super.didUpdateWidget(old);
    if (old.item?.key != widget.item?.key) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ac.dispose();
    super.dispose();
  }

  void _clear() {
    for (var i = 0; i < _bars.length; i++) {
      _bars[i] = 0.0;
      _peaks[i] = 0.0;
    }
    for (var i = 0; i < _keys.length; i++) {
      _keys[i] = 0.0;
    }
  }

  void _sync() {
    if (!mounted) return;
    if (_data != null && widget.h.player.playing) {
      if (!_ac.isRunning) _ac.start();
    } else {
      if (_ac.isRunning) _ac.stop();
      _clear();
      setState(() {});
    }
  }

  void _setData(VizData d) {
    setState(() {
      _data = d;
      _status = '';
      if (_bars.length != d.nb) {
        _bars = List<double>.filled(d.nb, 0.0);
        _peaks = List<double>.filled(d.nb, 0.0);
      }
      if (_keys.length != d.nk) _keys = List<double>.filled(d.nk, 0.0);
      _keyLo = d.keyLo;
    });
    _sync();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final it = widget.item;
    final my = ++_seq;
    if (_ac.isRunning) _ac.stop();
    _clear();
    if (it == null) {
      setState(() {
        _data = null;
        _status = 'NO DATA';
      });
      return;
    }
    final c = _cache[it.key];
    if (c != null) {
      _setData(c);
      return;
    }
    setState(() {
      _data = null;
      _status = 'ANALYZING...';
    });
    final d = await VizStore.get(widget.h, it);
    if (!mounted || my != _seq) return;
    if (d == null) {
      setState(() => _status = 'NO SIGNAL');
      return;
    }
    if (_cache.length >= 4) _cache.remove(_cache.keys.first);
    _cache[it.key] = d;
    _setData(d);
  }

  // 1フレーム分、表示の値を進める (上がるときは即、下がるときはゆっくり)
  void _step() {
    final now = DateTime.now().microsecondsSinceEpoch;
    double dt = _last == 0 ? 0.016 : (now - _last) / 1000000.0;
    if (dt > 0.1) dt = 0.1;
    _last = now;
    final d = _data;
    int f = -1;
    if (d != null && widget.h.player.playing) {
      f = ((widget.h.player.position.inMilliseconds + kVizOffsetMs) * d.fps / 1000.0).floor();
      if (f < 0 || f >= d.n) f = -1;
    }
    for (var i = 0; i < _bars.length; i++) {
      final double t = (f >= 0 && d != null && i < d.nb) ? d.band(f, i) / 255.0 : 0.0;
      _bars[i] = t >= _bars[i] ? t : max(t, _bars[i] - dt * 2.5);
      _peaks[i] = _bars[i] >= _peaks[i] ? _bars[i] : max(_bars[i], _peaks[i] - dt * 0.4);
    }
    for (var k = 0; k < _keys.length; k++) {
      final double t = (f >= 0 && d != null && k < d.nk) ? d.key(f, k).toDouble() : 0.0;
      _keys[k] = t >= _keys[k] ? t : max(t, _keys[k] - dt * 8.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Builder(
        builder: (context) {
          _step();
          return Stack(
            children: [
          Column(
            children: [
              SizedBox(
                height: 64,
                width: double.infinity,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _VzSpecPainter(_bars, _peaks)),
                    ),
                    if (_status.isNotEmpty) Center(child: Text(_status, style: kMutS)),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              SizedBox(
                height: 30,
                width: double.infinity,
                child: CustomPaint(painter: _VzKeyPainter(_keys, _keyLo)),
              ),
              SizedBox(
                height: 12,
                width: double.infinity,
                child: CustomPaint(painter: _VzLabelPainter(_keyLo, _keys.length)),
              ),
            ],
          ),
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _VzScanPainter())),
          ),
            ],
          );
        },
      ),
    );
  }
}

// スペアナ: ドットの積み木風。下から緑 → 黄 → 赤。白い点はピークホールド
class _VzSpecPainter extends CustomPainter {
  final List<double> v;
  final List<double> pk;
  _VzSpecPainter(this.v, this.pk);

  @override
  void paint(Canvas canvas, Size s) {
    final n = v.length ~/ 2;
    if (n == 0) return;
    const double gap = 3.0;
    const double segH = 6.0;
    const double segGap = 2.0;
    final bw = (s.width - gap * (n - 1)) / n;
    final segs = (s.height / (segH + segGap)).floor();
    final p = Paint();
    for (var i = 0; i < n; i++) {
      final x = i * (bw + gap);
      final lit = (max(v[2 * i], v[2 * i + 1]) * segs).round();
      final pks = (max(pk[2 * i], pk[2 * i + 1]) * segs).round() - 1;
      for (var j = 0; j < segs; j++) {
        final y = s.height - (j + 1) * (segH + segGap) + segGap;
        final t = j / segs;
        if (j < lit) {
          p.color = t < 0.6
              ? const Color(0xFF55FF55)
              : (t < 0.85 ? const Color(0xFFFFFF55) : const Color(0xFFFF5555));
        } else if (j == pks && j > 0) {
          p.color = const Color(0xFFFFFFFF);
        } else {
          p.color = const Color(0xFF1E1E1E);
        }
        canvas.drawRect(Rect.fromLTWH(x, y, bw, segH), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// 鍵盤: 鳴っている音の鍵が光る。強さで 水色 → 黄色 → ピンク
class _VzKeyPainter extends CustomPainter {
  final List<double> kd;
  final int lo;
  _VzKeyPainter(this.kd, this.lo);

  static const List<int> _wi = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6];
  static const List<bool> _bk = [
    false, true, false, true, false, false, true, false, true, false, true, false
  ];
  static const List<Color> _wc = [
    Color(0xFFE6E6E6),
    Color(0xFF55FFFF),
    Color(0xFFFFFF55),
    Color(0xFFFF55FF),
  ];
  static const List<Color> _kc = [
    Color(0xFF111111),
    Color(0xFF00AAAA),
    Color(0xFFAAAA00),
    Color(0xFFAA00AA),
  ];

  static int _idx(int m) => ((m - 36) ~/ 12) * 7 + _wi[m % 12];

  int _lv(double x) {
    if (x < 0.15) return 0;
    final c = x.ceil();
    return c < 1 ? 1 : (c > 3 ? 3 : c);
  }

  @override
  void paint(Canvas canvas, Size s) {
    final nk = kd.length;
    if (nk == 0) return;
    final base = _idx(lo);
    final whites = _idx(lo + nk - 1) - base + 1;
    final wk = s.width / whites;
    final p = Paint();
    for (var k = 0; k < nk; k++) {
      final m = lo + k;
      if (_bk[m % 12]) continue;
      final x = (_idx(m) - base) * wk;
      p.color = _wc[_lv(kd[k])];
      canvas.drawRect(Rect.fromLTWH(x, 0, wk - 1, s.height), p);
    }
    final bw = wk * 0.62;
    for (var k = 0; k < nk; k++) {
      final m = lo + k;
      if (!_bk[m % 12]) continue;
      final cx = (_idx(m) - base + 1) * wk;
      p.color = _kc[_lv(kd[k])];
      canvas.drawRect(Rect.fromLTWH(cx - bw / 2, 0, bw, s.height * 0.62), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// 解析データの保存 (スマホ内)。サーバーに繋がらなくても表示できるようにする
class VizStore {
  static Directory? _dir;

  static Future<Directory?> _d() async {
    if (_dir != null) return _dir;
    try {
      final base = await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}/music_viz');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
    } catch (_) {}
    return _dir;
  }

  static Future<File?> _file(Item it) async {
    final d = await _d();
    return d == null ? null : File('${d.path}/${it.key}.bin');
  }

  static Future<bool> has(Item it) async {
    final f = await _file(it);
    return f != null && await f.exists();
  }

  static Future<void> _save(Item it, vz_td.Uint8List b) async {
    final f = await _file(it);
    if (f == null) return;
    try {
      final tmp = File('${f.path}.part');
      await tmp.writeAsBytes(b, flush: true);
      await tmp.rename(f.path);
      await _prune(f.parent);
    } catch (_) {}
  }

  // 古いものから消して、200曲分までにする
  static Future<void> _prune(Directory d) async {
    try {
      final fs = <File>[];
      await for (final e in d.list()) {
        if (e is File && e.path.endsWith('.bin')) fs.add(e);
      }
      if (fs.length <= 200) return;
      fs.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (var i = 0; i < fs.length - 200; i++) {
        await fs[i].delete();
      }
    } catch (_) {}
  }

  // スマホにあればそれを、なければサーバーで解析してもらって保存する
  static Future<VizData?> get(MusicHandler h, Item it) async {
    try {
      final f = await _file(it);
      if (f != null && await f.exists()) {
        final cd = VizData.parse(await f.readAsBytes());
        if (cd != null) return cd;
      }
      vz_td.Uint8List? b;
      if (it.isPhone) {
        final path = h.off.localPath(it) ??
            await Pmd.ensureWav(h.off.phoneDir, it.p.substring(6));
        if (path == null) return null;
        b = await h.api.uploadViz(File(path), it.p.split('.').last);
      } else {
        final r = await http
            .get(h.api.fileUri(it).replace(path: '/music/api/viz'))
            .timeout(const Duration(seconds: 180));
        if (r.statusCode == 200) b = r.bodyBytes;
      }
      if (b == null) return null;
      final d = VizData.parse(b);
      if (d == null) return null;
      await _save(it, b);
      return d;
    } catch (_) {
      return null;
    }
  }

  // スマホに保存済みの曲 (とスマホ内ファイル) の解析データを、先に集めておく
  static Future<void> prefetchAll(MusicHandler h) async {
    final its = <Item>[];
    final seen = <String>{};
    for (final pl in h.S.pls) {
      for (final it in pl.items) {
        if (seen.add(it.key) && h.off.has(it)) its.add(it);
      }
    }
    const msg = '解析データを保存中';
    var shown = false;
    for (final it in its) {
      if (await has(it)) continue;
      if (!shown) {
        shown = true;
        h.off.status = msg;
        h.notifyUi();
      }
      final d = await get(h, it);
      if (d == null) break; // サーバーに繋がらない等は次回に回す
    }
    if (shown && h.off.status == msg) {
      h.off.status = '';
      h.notifyUi();
    }
  }
}

extension VizApi on Api {
  // スマホ内の曲をサーバーに一度だけ送って、解析データを受け取る (サーバーには残らない)
  Future<vz_td.Uint8List?> uploadViz(File f, String ext) async {
    try {
      final len = await f.length();
      if (len > 150 * 1024 * 1024) return null;
      final req = http.StreamedRequest('POST', _u('viz_upload', {'x': ext}));
      req.contentLength = len;
      req.headers['Content-Type'] = 'application/octet-stream';
      f.openRead().listen(req.sink.add,
          onDone: req.sink.close, onError: (_) => req.sink.close());
      final res = await c.send(req).timeout(const Duration(minutes: 5));
      final bytes = await res.stream.toBytes();
      if (res.statusCode != 200) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
// スキャンライン: ブラウン管っぽい薄い横線
class _VzScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = const Color(0x50000000);
    for (double y = 1; y < s.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, s.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// 鍵盤の下の音名 (C の位置に C2〜C7)
class _VzLabelPainter extends CustomPainter {
  final int lo;
  final int nk;
  _VzLabelPainter(this.lo, this.nk);

  @override
  void paint(Canvas canvas, Size s) {
    if (nk == 0) return;
    final base = _VzKeyPainter._idx(lo);
    final whites = _VzKeyPainter._idx(lo + nk - 1) - base + 1;
    final wk = s.width / whites;
    for (var m = lo; m < lo + nk; m++) {
      if (m % 12 != 0) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: 'C${m ~/ 12 - 1}',
          style: TextStyle(color: const Color(0xFF8A8A8A), fontSize: 9, fontFamily: kMono),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((_VzKeyPainter._idx(m) - base) * wk, 1));
    }
  }

  @override
  bool shouldRepaint(covariant _VzLabelPainter old) => old.lo != lo || old.nk != nk;
}

// ===== ここまで =====
