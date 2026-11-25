import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' as asv;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String defaultBase = 'http://100.102.7.80:5000';

String baseUrl = defaultBase;
String gOrder = 'name'; // name / new
bool gDesc = false; // false=昇順（名前=A→Z、日付=新しい順）、true=降順（逆）
int gCols = 5; // サムネイルの列数（3〜5）
int gRev = 0; // 削除のたびに増やす（画像の番号がずれるので、キャッシュを使い回さない）
bool gRtl = true; // 右開き（右から左へめくる）が初期値

final http.Client gHttp = http.Client(); // 接続を使い回して待ち時間を減らす
final Map<String, List<Entry>> gListCache = {}; // フォルダ一覧の先出し用

late final Player gPlayer;
late final VideoController gController;
GalleryAudioHandler? audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  gPlayer = Player();
  gController = VideoController(gPlayer);
  final prefs = await SharedPreferences.getInstance();
  baseUrl = prefs.getString('base') ?? defaultBase;
  gCols = math.min(math.max(prefs.getInt('cols') ?? 5, 3), 5);
  gRtl = prefs.getBool('rtl') ?? true;
  gOrder = prefs.getString('order') ?? 'name';
  gDesc = prefs.getBool('desc') ?? false;
  try {
    // 画面を消しても止まらないための常駐サービス。失敗してもアプリ自体は動かす。
    audioHandler = await asv.AudioService.init(
      builder: () => GalleryAudioHandler(gPlayer),
      config: const asv.AudioServiceConfig(
        androidNotificationChannelId: 'com.chako.gallery_app.playback',
        androidNotificationChannelName: 'ギャラリー再生',
        androidStopForegroundOnPause: false,
      ),
    );
  } catch (_) {
    audioHandler = null;
  }
  runApp(const GalleryApp());
  _setupIntent();
}

// 端末内のファイルは「/」で始まる絶対パス（サーバー側は相対パス）
bool isLocalPath(String p) => p.startsWith('/') || p.contains('://');

String mediaSrc(Entry e) =>
    isLocalPath(e.path) ? e.path : gUri('/vid', {'p': e.path}).toString();

Uri gUri(String path, Map<String, String> q) =>
    Uri.parse('$baseUrl/gallery$path').replace(queryParameters: q);

Future<dynamic> getJson(String path, Map<String, String> q) async {
  final res = await gHttp.get(gUri(path, q)).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw Exception('HTTP ${res.statusCode}');
  }
  return jsonDecode(utf8.decode(res.bodyBytes));
}

String fmt(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  if (h > 0) return '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
}

class Entry {
  final String name;
  final String type; // dir / video / image / archive
  final String path;
  final int size;
  final int mtime;
  final int cover; // 書庫の表紙にしたページ（0始まり）
  Entry(this.name, this.type, this.path, this.size, this.mtime, {this.cover = 0});

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        j['name'] as String,
        j['type'] as String,
        j['path'] as String,
        (j['size'] as num).toInt(),
        (j['mtime'] as num).toInt(),
        cover: (j['cover'] as num?)?.toInt() ?? 0,
      );
}

// ---------------------------------------------------------------- 履歴

class HistItem {
  final String type; // set（書庫・画像フォルダ）/ video
  final String path;
  final String title;
  final int page; // set: 最後に見たページ（0始まり）
  final int count; // set: 全ページ数
  final int pos; // video: 再生位置（ミリ秒）
  final int ts; // 最後に開いた時刻（ミリ秒）
  HistItem({
    required this.type,
    required this.path,
    required this.title,
    this.page = 0,
    this.count = 0,
    this.pos = 0,
    required this.ts,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'path': path,
        'title': title,
        'page': page,
        'count': count,
        'pos': pos,
        'ts': ts,
      };

  factory HistItem.fromJson(Map<String, dynamic> j) => HistItem(
        type: j['type'] as String,
        path: j['path'] as String,
        title: j['title'] as String,
        page: (j['page'] as num?)?.toInt() ?? 0,
        count: (j['count'] as num?)?.toInt() ?? 0,
        pos: (j['pos'] as num?)?.toInt() ?? 0,
        ts: (j['ts'] as num).toInt(),
      );
}

class Hist {
  static List<HistItem>? _items;
  // 履歴が変わるたびに増える。一覧画面はこれを見て「前回」マークを付け直す
  static final ValueNotifier<int> rev = ValueNotifier<int>(0);

  static Future<List<HistItem>> all() async {
    final cached = _items;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('hist');
    var list = <HistItem>[];
    if (s != null) {
      try {
        list = (jsonDecode(s) as List)
            .map((e) => HistItem.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        list = <HistItem>[];
      }
    }
    _items = list;
    return list;
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _items ?? <HistItem>[];
    await prefs.setString('hist', jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  static Future<HistItem?> find(String type, String path) async {
    final list = await all();
    for (final h in list) {
      if (h.type == type && h.path == path) return h;
    }
    return null;
  }

  static Future<void> put(HistItem h) async {
    final list = await all();
    list.removeWhere((x) => x.type == h.type && x.path == h.path);
    list.insert(0, h);
    if (list.length > 200) {
      list.removeRange(200, list.length);
    }
    rev.value++;
    await _save();
  }

  static Future<void> remove(String type, String path) async {
    final list = await all();
    list.removeWhere((x) => x.type == type && x.path == path);
    rev.value++;
    await _save();
  }
}

// ---------------------------------------------------------------- プレイリスト

class PlaylistData {
  String name;
  List<Entry> items;
  PlaylistData(this.name, this.items);

  Map<String, dynamic> toJson() => {
        'name': name,
        'items': items.map((e) => {'path': e.path, 'name': e.name}).toList(),
      };

  factory PlaylistData.fromJson(Map<String, dynamic> j) => PlaylistData(
        j['name'] as String,
        (j['items'] as List)
            .map((e) => Entry(
                (e as Map<String, dynamic>)['name'] as String,
                'video',
                e['path'] as String,
                0,
                0))
            .toList(),
      );
}

class Playlists {
  static List<PlaylistData>? _l;

  static Future<List<PlaylistData>> all() async {
    final c = _l;
    if (c != null) return c;
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('playlists');
    var list = <PlaylistData>[];
    if (s != null) {
      try {
        list = (jsonDecode(s) as List)
            .map((e) => PlaylistData.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        list = <PlaylistData>[];
      }
    }
    _l = list;
    return list;
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _l ?? <PlaylistData>[];
    await prefs
        .setString('playlists', jsonEncode(list.map((e) => e.toJson()).toList()));
  }
}

Future<String?> askName(BuildContext context, String title, String init) async {
  final c = TextEditingController(text: init);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
      ],
    ),
  );
  final v = c.text.trim();
  if (ok != true || v.isEmpty) return null;
  return v;
}

// 動画をプレイリストに追加する（追加先を選ぶ。新規作成も可）。追加した旨のメッセージを返す。
Future<String?> addToPlaylist(BuildContext context, List<Entry> videos) async {
  if (videos.isEmpty) return null;
  final lists = await Playlists.all();
  if (!context.mounted) return null;
  final r = await showDialog<int>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('プレイリストに追加'),
      children: [
        for (var i = 0; i < lists.length; i++)
          SimpleDialogOption(
              onPressed: () => Navigator.pop(c, i),
              child: Text('${lists[i].name}（${lists[i].items.length}本）')),
        SimpleDialogOption(
            onPressed: () => Navigator.pop(c, -1),
            child: const Text('＋ 新しいプレイリスト…')),
      ],
    ),
  );
  if (r == null || !context.mounted) return null;
  PlaylistData pl;
  if (r == -1) {
    final n = await askName(context, '新しいプレイリスト', '');
    if (n == null) return null;
    pl = PlaylistData(n, []);
    lists.add(pl);
  } else {
    pl = lists[r];
  }
  var added = 0;
  for (final v in videos) {
    if (pl.items.any((x) => x.path == v.path)) continue; // 重複は入れない
    pl.items.add(Entry(v.name, 'video', v.path, 0, 0));
    added++;
  }
  await Playlists.save();
  return '「${pl.name}」に$added本追加しました';
}

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  List<PlaylistData>? lists;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final l = await Playlists.all();
    if (!mounted) return;
    setState(() => lists = l);
  }

  Future<void> create() async {
    final n = await askName(context, '新しいプレイリスト', '');
    if (n == null) return;
    (await Playlists.all()).add(PlaylistData(n, []));
    await Playlists.save();
    if (mounted) load();
  }

  Future<void> rename(PlaylistData p) async {
    final n = await askName(context, '名前を変更', p.name);
    if (n == null) return;
    p.name = n;
    await Playlists.save();
    if (mounted) setState(() {});
  }

  Future<void> remove(PlaylistData p) async {
    final ok = await confirmDelete(
        context, p.name, 'プレイリストだけを消します（動画ファイルは消えません）。');
    if (!ok) return;
    (await Playlists.all()).remove(p);
    await Playlists.save();
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) {
    final l = lists;
    return Scaffold(
      appBar: AppBar(title: const Text('プレイリスト')),
      floatingActionButton: FloatingActionButton(
          onPressed: create, child: const Icon(Icons.add)),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : l.isEmpty
              ? const Center(
                  child: Text('プレイリストはまだありません\n一覧で動画を長押しして選ぶと追加できます',
                      textAlign: TextAlign.center))
              : ListView.builder(
                  padding: EdgeInsets.only(
                      bottom: 80 + MediaQuery.of(context).padding.bottom),
                  itemCount: l.length,
                  itemBuilder: (context, i) {
                    final p = l[i];
                    return ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(p.name),
                      subtitle: Text('${p.items.length}本'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'rename') rename(p);
                          if (v == 'delete') remove(p);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('名前を変更')),
                          PopupMenuItem(value: 'delete', child: Text('削除')),
                        ],
                      ),
                      onTap: () async {
                        await Navigator.push<dynamic>(
                            context,
                            MaterialPageRoute(
                                builder: (_) => PlaylistPage(playlist: p)));
                        if (mounted) setState(() {});
                      },
                    );
                  },
                ),
    );
  }
}

class PlaylistPage extends StatefulWidget {
  final PlaylistData playlist;
  const PlaylistPage({super.key, required this.playlist});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  PlaylistData get p => widget.playlist;

  Future<void> play(int start, {bool shuffle = false}) async {
    if (p.items.isEmpty) return;
    var list = List<Entry>.from(p.items);
    var s = start;
    if (shuffle) {
      list.shuffle();
      s = 0;
    }
    await Navigator.push<dynamic>(context,
        MaterialPageRoute(builder: (_) => PlayerPage(videos: list, start: s)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: 'シャッフル再生',
              icon: const Icon(Icons.shuffle),
              onPressed: () => play(0, shuffle: true)),
          IconButton(
              tooltip: '最初から再生',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => play(0)),
        ],
      ),
      body: p.items.isEmpty
          ? const Center(child: Text('動画がありません'))
          : ReorderableListView.builder(
              padding:
                  EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
              itemCount: p.items.length,
              onReorder: (a, b) async {
                if (b > a) b -= 1;
                setState(() => p.items.insert(b, p.items.removeAt(a)));
                await Playlists.save();
              },
              itemBuilder: (context, i) {
                final e = p.items[i];
                return ListTile(
                  key: ValueKey('${e.path}#$i'),
                  leading: SizedBox(
                    width: 72,
                    height: 48,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CachedNetworkImage(
                        imageUrl: gUri('/vcover', {'p': e.path}).toString(),
                        fit: BoxFit.cover,
                        memCacheWidth: 200,
                        fadeInDuration: Duration.zero,
                        errorWidget: (_, __, ___) =>
                            const Icon(Icons.videocam, size: 24),
                      ),
                    ),
                  ),
                  title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${i + 1}本目（長押しで並べ替え）',
                      style: const TextStyle(fontSize: 11)),
                  trailing: IconButton(
                    tooltip: 'リストから外す',
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      setState(() => p.items.removeAt(i));
                      await Playlists.save();
                    },
                  ),
                  onTap: () => play(i),
                );
              },
            ),
    );
  }
}

String fmtTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
}

// ---------------------------------------------------------------- 削除

Future<bool> confirmDelete(
    BuildContext context, String name, String note) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('削除しますか？'),
      content: Text('$name\n\n$note'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.redAccent))),
      ],
    ),
  );
  return r == true;
}

/// 成功なら null、失敗ならエラーメッセージを返す。
Future<String?> deleteOnServer(String p, {int? index, String? name}) async {
  try {
    final body = <String, String>{'p': p};
    if (index != null) {
      body['i'] = '$index';
      body['n'] = name ?? '';
    }
    final res = await gHttp
        .post(gUri('/del', {}), headers: {'X-Gallery-Op': '1'}, body: body)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 200) return null;
    final t = utf8.decode(res.bodyBytes);
    return '削除できませんでした (${res.statusCode}) ${t.length > 80 ? t.substring(0, 80) : t}';
  } catch (e) {
    return '削除できませんでした: $e';
  }
}

void showMsg(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

// ---------------------------------------------------------------- mp3 保存

bool gMp3Busy = false;

String _safeName(String s) {
  final t = s
      .replaceAll(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '')
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .trim();
  return t.isEmpty ? 'video' : t;
}

/// 保存先。基本はスマホの「Music/ギャラリー」。作れないときはアプリ専用の場所。
Future<Directory> _mp3Dir() async {
  for (final path in [
    '/storage/emulated/0/Music/ギャラリー',
    '/storage/emulated/0/Android/data/com.chako.gallery_app/files/mp3',
  ]) {
    try {
      final d = Directory(path);
      await d.create(recursive: true);
      final t = File('${d.path}/.w');
      await t.writeAsString('1');
      await t.delete();
      return d;
    } catch (_) {}
  }
  throw Exception('保存先を作れません');
}

/// 1本をmp3にしてスマホへ保存。戻り値: 'ok' / 'skip'（保存済み）/ エラー文
Future<String> _saveOneMp3(Entry e, Directory dir) async {
  final f = File('${dir.path}/${_safeName(e.name)}.mp3');
  if (await f.exists() && await f.length() > 0) return 'skip';
  final part = File('${f.path}.part');
  IOSink? sink;
  try {
    final req = http.Request('GET', gUri('/api/mp3', {'p': e.path}));
    final res = await gHttp.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return 'HTTP ${res.statusCode}';
    sink = part.openWrite();
    await sink.addStream(res.stream.timeout(const Duration(seconds: 90)));
    await sink.close();
    sink = null;
    if (await part.length() < 1024) {
      await part.delete();
      return '音声を取り出せませんでした';
    }
    await part.rename(f.path);
    return 'ok';
  } catch (err) {
    try {
      await sink?.close();
      if (await part.exists()) await part.delete();
    } catch (_) {}
    return '$err';
  }
}

/// 動画をmp3にしてスマホに保存する（選択・再生画面の両方から使う）
Future<void> saveAsMp3(BuildContext context, List<Entry> list) async {
  if (list.any((e) => isLocalPath(e.path))) {
    showMsg(context, '端末内の動画はmp3保存できません（サーバーの動画のみ）');
    return;
  }
  if (list.isEmpty) return;
  if (gMp3Busy) {
    showMsg(context, 'mp3の保存中です。終わるまで待ってください');
    return;
  }
  gMp3Busy = true;
  final messenger = ScaffoldMessenger.of(context);
  void say(String t, {int sec = 4}) => messenger.showSnackBar(
      SnackBar(content: Text(t), duration: Duration(seconds: sec)));
  try {
    final dir = await _mp3Dir();
    var ok = 0, skip = 0;
    final errs = <String>[];
    for (var i = 0; i < list.length; i++) {
      say('mp3保存中 ${i + 1}/${list.length}: ${list[i].name}', sec: 120);
      final r = await _saveOneMp3(list[i], dir);
      if (r == 'ok') {
        ok++;
      } else if (r == 'skip') {
        skip++;
      } else {
        errs.add('${list[i].name}: $r');
      }
    }
    messenger.clearSnackBars();
    var msg = 'mp3を$ok件保存しました（Music/ギャラリー）';
    if (skip > 0) msg += '、保存済み$skip件はスキップ';
    if (errs.isNotEmpty) msg += '、失敗${errs.length}件（${errs.first}）';
    say(msg, sec: 8);
  } catch (err) {
    messenger.clearSnackBars();
    say('mp3の保存に失敗: $err', sec: 8);
  } finally {
    gMp3Busy = false;
  }
}

// ---------------------------------------------------------------- 通知・バックグラウンド

class GalleryAudioHandler extends asv.BaseAudioHandler with asv.SeekHandler {
  final Player player;
  List<String> titles = [];

  GalleryAudioHandler(this.player) {
    player.stream.playing.listen((_) => sync());
    player.stream.buffering.listen((_) => sync());
    player.stream.completed.listen((_) => sync());
    player.stream.duration.listen((d) {
      final cur = mediaItem.value;
      if (cur != null) mediaItem.add(cur.copyWith(duration: d));
    });
    player.stream.playlist.listen((p) {
      final i = p.index;
      final title = (i >= 0 && i < titles.length) ? titles[i] : '';
      final d = player.state.duration;
      mediaItem.add(asv.MediaItem(
        id: '$i',
        title: title,
        duration: d > Duration.zero ? d : null,
      ));
      sync();
    });
    Timer.periodic(const Duration(seconds: 5), (_) {
      if (player.state.playing) sync();
    });
  }

  void sync() {
    final playing = player.state.playing;
    playbackState.add(asv.PlaybackState(
      controls: [
        asv.MediaControl.skipToPrevious,
        playing ? asv.MediaControl.pause : asv.MediaControl.play,
        asv.MediaControl.skipToNext,
      ],
      systemActions: const {asv.MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: player.state.buffering
          ? asv.AudioProcessingState.buffering
          : asv.AudioProcessingState.ready,
      playing: playing,
      updatePosition: player.state.position,
      speed: 1.0,
    ));
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
    sync();
  }

  @override
  Future<void> skipToNext() => player.next();

  @override
  Future<void> skipToPrevious() => player.previous();

  @override
  Future<void> stop() async {
    await player.pause();
    await super.stop();
  }
}

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: gNavKey,
      title: 'ギャラリー',
      theme: ThemeData.dark(useMaterial3: true),
      home: const BrowsePage(path: '', title: 'NAS'),
    );
  }
}

// ---------------------------------------------------------------- 外部から開く（開く・共有）

final GlobalKey<NavigatorState> gNavKey = GlobalKey<NavigatorState>();
const MethodChannel _intentCh = MethodChannel('gallery/intent');

void _setupIntent() {
  _intentCh.setMethodCallHandler((call) async {
    if (call.method == 'open') await openExternal(call.arguments as String);
  });
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final v = await _intentCh.invokeMethod<String>('initial');
      if (v != null) await openExternal(v);
    } catch (_) {}
  });
}

// 他のアプリから渡された動画を開く。置き場所が分かれば、同じフォルダの動画を続けて再生する
Future<void> openExternal(String src) async {
  var nav = gNavKey.currentState;
  for (var i = 0; nav == null && i < 15; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    nav = gNavKey.currentState;
  }
  if (nav == null) return;
  var vids = <Entry>[];
  var start = 0;
  if (src.startsWith('/')) {
    try {
      if (await ensureLocalAccess()) {
        final dir = File(src).parent;
        await for (final x in dir.list(followLinks: false)) {
          if (x is! File) continue;
          final name = x.path.split('/').last;
          if (name.startsWith('.')) continue;
          final dot = name.lastIndexOf('.');
          if (dot <= 0 ||
              !_videoExts.contains(name.substring(dot + 1).toLowerCase())) {
            continue;
          }
          final st = await x.stat();
          vids.add(Entry(name, 'video', x.path, st.size,
              st.modified.millisecondsSinceEpoch ~/ 1000));
        }
        vids.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        start = vids.indexWhere((e) => e.path == src);
      }
    } catch (_) {
      vids = [];
    }
  }
  if (vids.isEmpty || start < 0) {
    var name = src.split('/').last;
    try {
      name = Uri.decodeComponent(name);
    } catch (_) {}
    vids = [Entry(name, 'video', src, 0, 0)];
    start = 0;
  }
  final list = vids;
  final st = start;
  nav.push(MaterialPageRoute<dynamic>(
      builder: (_) => PlayerPage(videos: list, start: st)));
}

// ---------------------------------------------------------------- 端末内の動画

const String _localRoot = '/storage/emulated/0';
const Set<String> _videoExts = {
  'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', 'ts', 'flv', 'wmv', '3gp',
  'mpg', 'mpeg', 'm2ts', 'ogv'
};

Future<bool> ensureLocalAccess() async {
  if (await Permission.manageExternalStorage.isGranted) return true;
  if (await Permission.videos.isGranted) return true;
  final r = await Permission.manageExternalStorage.request();
  if (r.isGranted) return true;
  final v = await Permission.videos.request();
  return v.isGranted;
}

String _fmtBytes(int b) {
  if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(2)} GB';
  if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
  return '${(b / 1024).toStringAsFixed(0)} KB';
}

class LocalBrowsePage extends StatefulWidget {
  final String dir;
  const LocalBrowsePage({super.key, this.dir = _localRoot});

  @override
  State<LocalBrowsePage> createState() => _LocalBrowsePageState();
}

class _LocalBrowsePageState extends State<LocalBrowsePage> {
  List<Entry>? dirs;
  List<Entry>? vids;
  String? error;

  String get title {
    if (widget.dir == _localRoot) return '端末内';
    return widget.dir.split('/').last;
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      if (!await ensureLocalAccess()) {
        if (mounted) setState(() => error = 'ストレージへのアクセス許可が必要です');
        return;
      }
      final ds = <Entry>[];
      final vs = <Entry>[];
      await for (final f in Directory(widget.dir).list(followLinks: false)) {
        final name = f.path.split('/').last;
        if (name.startsWith('.')) continue;
        FileStat st;
        try {
          st = await f.stat();
        } catch (_) {
          continue;
        }
        final mt = st.modified.millisecondsSinceEpoch ~/ 1000;
        if (f is Directory) {
          ds.add(Entry(name, 'dir', f.path, 0, mt));
        } else if (f is File) {
          final dot = name.lastIndexOf('.');
          if (dot > 0 &&
              _videoExts.contains(name.substring(dot + 1).toLowerCase())) {
            vs.add(Entry(name, 'video', f.path, st.size, mt));
          }
        }
      }
      int cmp(Entry a, Entry b) {
        final r = gOrder == 'new'
            ? b.mtime.compareTo(a.mtime)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return gDesc ? -r : r;
      }

      ds.sort(cmp);
      vs.sort(cmp);
      if (!mounted) return;
      setState(() {
        dirs = ds;
        vids = vs;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> openDir(String p) async {
    await Navigator.push<dynamic>(
        context, MaterialPageRoute(builder: (_) => LocalBrowsePage(dir: p)));
  }

  Widget body() {
    if (error != null) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: load, child: const Text('もう一度')),
        ]),
      ));
    }
    if (dirs == null || vids == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final ds = dirs!;
    final vs = vids!;
    if (ds.isEmpty && vs.isEmpty) {
      return const Center(child: Text('動画もフォルダもありません'));
    }
    return ListView.builder(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 8),
      itemCount: ds.length + vs.length,
      itemBuilder: (context, i) {
        if (i < ds.length) {
          final e = ds[i];
          return ListTile(
            leading: const Icon(Icons.folder, color: Colors.amber),
            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => openDir(e.path),
          );
        }
        final e = vs[i - ds.length];
        return ListTile(
          leading: const Icon(Icons.movie),
          title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(_fmtBytes(e.size), style: const TextStyle(fontSize: 11)),
          onTap: () async {
            await Navigator.push<dynamic>(
                context,
                MaterialPageRoute(
                    builder: (_) => PlayerPage(videos: vs, start: i - ds.length)));
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'よく使う場所',
            icon: const Icon(Icons.folder_special),
            onSelected: (p) => openDir(p),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _localRoot, child: Text('内部ストレージ')),
              PopupMenuItem(value: '$_localRoot/Download', child: Text('Download')),
              PopupMenuItem(value: '$_localRoot/Movies', child: Text('Movies')),
              PopupMenuItem(value: '$_localRoot/DCIM', child: Text('DCIM')),
            ],
          ),
          IconButton(
            tooltip: gOrder == 'name' ? '名前順' : '新しい順',
            icon: Icon(gOrder == 'name' ? Icons.sort_by_alpha : Icons.schedule),
            onPressed: () async {
              gOrder = gOrder == 'name' ? 'new' : 'name';
              final pr = await SharedPreferences.getInstance();
              await pr.setString('order', gOrder);
              load();
            },
          ),
          IconButton(
            tooltip: gDesc ? '降順' : '昇順',
            icon: Icon(gDesc ? Icons.arrow_downward : Icons.arrow_upward),
            onPressed: () async {
              gDesc = !gDesc;
              final pr = await SharedPreferences.getInstance();
              await pr.setBool('desc', gDesc);
              load();
            },
          ),
        ],
      ),
      body: body(),
    );
  }
}

// ---------------------------------------------------------------- 一覧

class BrowsePage extends StatefulWidget {
  final String path;
  final String title;
  const BrowsePage({super.key, required this.path, required this.title});

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  List<Entry>? items;
  String? error;
  String? lastChild; // このフォルダ内で、最後に開いたもの（のフォルダ内での名前）
  final Set<String> sel = {}; // 選択中のファイル名
  bool deletingSel = false;
  final ScrollController scrollCtl = ScrollController();
  bool scrolledToLast = false; // 「前回」の位置へのスクロールは、開いたときに1回だけ

  String get cacheKey => '${widget.path}|$gOrder|${gDesc ? 1 : 0}';

  @override
  void dispose() {
    Hist.rev.removeListener(loadMarker);
    scrollCtl.dispose();
    super.dispose();
  }

  // 前回開いたものの行まで、一覧を自動でスクロールする
  void scrollToLast() {
    if (scrolledToLast || lastChild == null || items == null) return;
    final idx = items!.indexWhere((e) => e.name == lastChild);
    if (idx < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || scrolledToLast || !scrollCtl.hasClients) return;
      scrolledToLast = true;
      final width = MediaQuery.of(context).size.width;
      final ratio = gCols >= 5 ? 0.62 : 0.72;
      final cellW = (width - 12 - 6 * (gCols - 1)) / gCols;
      final cellH = cellW / ratio;
      final row = idx ~/ gCols;
      final pos = scrollCtl.position;
      final target = 6 + row * (cellH + 6) - (pos.viewportDimension - cellH) / 2;
      scrollCtl.jumpTo(target.clamp(0.0, pos.maxScrollExtent));
    });
  }

  @override
  void initState() {
    super.initState();
    items = gListCache[cacheKey]; // 前回の一覧があれば、先にそれを出す
    load();
    loadMarker();
    // 次の巻へ進んだとき（画面の差し替え）にも、マークを最後に開いたものへ移す
    Hist.rev.addListener(loadMarker);
  }

  // 履歴から、このフォルダの中で最後に開いたもの（中のサブフォルダ経由も含む）を探す
  Future<void> loadMarker() async {
    final hist = await Hist.all(); // 新しい順
    final prefix = widget.path.isEmpty ? '' : '${widget.path}/';
    String? child;
    for (final h in hist) {
      if (isLocalPath(h.path)) continue;
      if (h.path.length > prefix.length && h.path.startsWith(prefix)) {
        final rel = h.path.substring(prefix.length);
        final k = rel.indexOf('/');
        child = k < 0 ? rel : rel.substring(0, k);
        break;
      }
    }
    if (!mounted) return;
    setState(() => lastChild = child);
    scrollToLast();
  }

  Future<void> load() async {
    final key = cacheKey;
    try {
      final j = await getJson('/api/ls', {'p': widget.path, 'o': gOrder, 'd': gDesc ? '1' : '0'})
          as Map<String, dynamic>;
      final list = (j['items'] as List)
          .map((e) => Entry.fromJson(e as Map<String, dynamic>))
          .toList();
      gListCache[key] = list;
      if (!mounted || key != cacheKey) return;
      setState(() {
        items = list;
        error = null;
      });
      loadMarker();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (items == null) error = '$e';
      });
    }
  }

  Future<void> cycleCols() async {
    setState(() {
      gCols = gCols >= 5 ? 3 : gCols + 1;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('cols', gCols);
  }

  Future<void> editServer() async {
    final c = TextEditingController(text: baseUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('サーバーのアドレス'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'http://100.x.x.x:5000'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    var v = c.text.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    if (v.isEmpty) return;
    baseUrl = v;
    gListCache.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('base', v);
    if (!mounted) return;
    setState(() {
      items = null;
      error = null;
    });
    load();
  }

  Future<void> open(Entry e, List<Entry> videos, List<Entry> images) async {
    Widget? page;
    if (e.type == 'dir') {
      page = BrowsePage(path: e.path, title: e.name);
    } else if (e.type == 'video') {
      page = PlayerPage(videos: videos, start: videos.indexOf(e));
    } else if (e.type == 'image') {
      page = ViewerPage(
          setPath: widget.path, start: images.indexOf(e), title: widget.title);
    } else if (e.type == 'archive') {
      // 前回の続きから開く
      final h = await Hist.find('set', e.path);
      final sp = h?.page ?? 0;
      if (!mounted) return;
      page = ViewerPage(
          setPath: e.path, start: sp, title: e.name, resumed: sp > 0);
    }
    if (page == null) return;
    final p = page;
    await Navigator.push<dynamic>(context, MaterialPageRoute(builder: (_) => p));
    if (mounted) load(); // 戻ったら一覧を静かに更新（削除・列数の反映）
  }

  void toggleSel(Entry e) {
    setState(() {
      if (!sel.remove(e.name)) sel.add(e.name);
    });
  }

  PreferredSizeWidget selBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(() => sel.clear()),
      ),
      title: Text('${sel.length}件選択中'),
      actions: [
        IconButton(
          tooltip: '全選択',
          icon: const Icon(Icons.select_all),
          onPressed: () => setState(() {
            for (final x in items ?? <Entry>[]) {
              if (x.type != 'dir') sel.add(x.name);
            }
          }),
        ),
        IconButton(
          tooltip: 'プレイリストに追加',
          icon: const Icon(Icons.playlist_add),
          onPressed: () async {
            final vids = (items ?? <Entry>[])
                .where((x) => x.type == 'video' && sel.contains(x.name))
                .toList();
            if (vids.isEmpty) {
              showMsg(context, '動画を選んでください');
              return;
            }
            final msg = await addToPlaylist(context, vids);
            if (msg == null || !mounted) return;
            setState(() => sel.clear());
            showMsg(context, msg);
          },
        ),
        IconButton(
          tooltip: 'mp3として保存',
          icon: const Icon(Icons.audio_file),
          onPressed: () async {
            final vids = (items ?? <Entry>[])
                .where((x) => x.type == 'video' && sel.contains(x.name))
                .toList();
            if (vids.isEmpty) {
              showMsg(context, '動画を選んでください');
              return;
            }
            setState(() => sel.clear());
            await saveAsMp3(context, vids);
          },
        ),
        IconButton(
          tooltip: '削除',
          icon: const Icon(Icons.delete_outline),
          onPressed: deleteSelected,
        ),
      ],
    );
  }

  Future<void> deleteSelected() async {
    final list = items;
    if (list == null || sel.isEmpty || deletingSel) return;
    final images = list.where((x) => x.type == 'image').toList();
    final targets =
        list.where((x) => sel.contains(x.name) && x.type != 'dir').toList();
    if (targets.isEmpty) return;
    final ok = await confirmDelete(
        context, '選択した${targets.length}件', '完全に削除します。元に戻せません。');
    if (!ok || !mounted) return;
    deletingSel = true;
    // 画像は番号で消すので、番号がずれないよう後ろから消す
    final imgs = targets.where((x) => x.type == 'image').toList()
      ..sort((a, b) => images.indexOf(b).compareTo(images.indexOf(a)));
    final others = targets.where((x) => x.type != 'image').toList();
    final doneNames = <String>{};
    String? firstErr;
    for (final e in others) {
      final err = await deleteOnServer(e.path);
      if (err == null) {
        doneNames.add(e.name);
      } else {
        firstErr ??= err;
      }
    }
    for (final e in imgs) {
      final err = await deleteOnServer(widget.path,
          index: images.indexOf(e), name: e.name);
      if (err == null) {
        doneNames.add(e.name);
      } else {
        firstErr ??= err;
      }
    }
    deletingSel = false;
    if (!mounted) return;
    gRev++;
    gListCache.clear();
    setState(() {
      items = items?.where((x) => !doneNames.contains(x.name)).toList();
      sel.removeAll(doneNames);
    });
    if (firstErr != null) {
      showMsg(context,
          '${doneNames.length}件削除、${targets.length - doneNames.length}件失敗: $firstErr');
    } else {
      showMsg(context, '${doneNames.length}件削除しました');
    }
  }

  Future<void> deleteEntry(Entry e, List<Entry> images) async {
    if (e.type == 'dir') return;
    final ok = await confirmDelete(context, e.name, '完全に削除します。元に戻せません。');
    if (!ok || !mounted) return;
    String? err;
    if (e.type == 'image') {
      err = await deleteOnServer(widget.path,
          index: images.indexOf(e), name: e.name);
    } else {
      err = await deleteOnServer(e.path);
    }
    if (!mounted) return;
    if (err != null) {
      showMsg(context, err);
      return;
    }
    gRev++;
    gListCache.clear();
    setState(() {
      items = items?.where((x) => x != e).toList();
    });
    load();
  }

  Widget thumb(Entry e, List<Entry> images) {
    String? url;
    if (e.type == 'video') {
      url = gUri('/vcover', {'p': e.path}).toString();
    } else if (e.type == 'image') {
      url = gUri('/img', {
        'p': widget.path,
        'i': '${images.indexOf(e)}',
        'v': 't',
        'r': '$gRev',
      }).toString();
    } else if (e.type == 'archive') {
      url = gUri('/img', {'p': e.path, 'i': '${e.cover}', 'v': 't'}).toString();
    }
    if (url == null) {
      return const Center(
          child: Icon(Icons.folder, size: 56, color: Colors.amber));
    }
    return Stack(fit: StackFit.expand, children: [
      CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: 240,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) =>
            const Center(child: Icon(Icons.broken_image, size: 28)),
      ),
      if (e.type == 'video')
        const Positioned(
            right: 4,
            bottom: 4,
            child: Icon(Icons.play_circle_outline, size: 20)),
      if (e.type == 'archive')
        const Positioned(
            right: 4, bottom: 4, child: Icon(Icons.collections, size: 18)),
    ]);
  }

  Widget body() {
    final list = items;
    if (list == null) {
      if (error != null) {
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('読み込めません\n$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: load, child: const Text('再読み込み')),
          ]),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (list.isEmpty) {
      return const Center(child: Text('何もありません'));
    }
    final videos = list.where((e) => e.type == 'video').toList();
    final images = list.where((e) => e.type == 'image').toList();
    // 画面下のナビゲーションバーに最後の行が隠れないように、その分の余白を足す
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return RefreshIndicator(
      onRefresh: load,
      child: GridView.builder(
        controller: scrollCtl,
        padding: EdgeInsets.fromLTRB(6, 6, 6, 12 + bottomInset),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: gCols,
          childAspectRatio: gCols >= 5 ? 0.62 : 0.72,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
        ),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final e = list[i];
          final isLast = lastChild != null && e.name == lastChild;
          final picked = sel.contains(e.name);
          return InkWell(
            onTap: () {
              if (sel.isNotEmpty) {
                if (e.type != 'dir') toggleSel(e);
              } else {
                open(e, videos, images);
              }
            },
            onLongPress: e.type == 'dir' ? null : () => toggleSel(e),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      color: Colors.white10,
                      // 最後に開いたものには、黄色の枠と「前回」の目印を付ける
                      foregroundDecoration: picked
                          ? BoxDecoration(
                              color: const Color(0x59FF5252),
                              border: Border.all(
                                  color: Colors.redAccent, width: 3))
                          : isLast
                              ? BoxDecoration(
                                  border: Border.all(
                                      color: Colors.amber, width: 3))
                              : null,
                      child: Stack(fit: StackFit.expand, children: [
                        thumb(e, images),
                        if (picked)
                          const Positioned(
                            right: 4,
                            top: 4,
                            child: Icon(Icons.check_circle,
                                color: Colors.white, size: 22),
                          ),
                        if (isLast)
                          Positioned(
                            left: 0,
                            top: 0,
                            child: Container(
                              color: Colors.amber,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              child: const Text('前回',
                                  style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(e.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: gCols >= 5 ? 9 : 11)),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRoot = widget.path.isEmpty;
    return WillPopScope(
      onWillPop: () async {
        if (sel.isNotEmpty) {
          setState(() => sel.clear());
          return false;
        }
        return true;
      },
      child: Scaffold(
      appBar: sel.isNotEmpty ? selBar() : AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: cycleCols, child: Text('$gCols列')),
          IconButton(
            tooltip: gOrder == 'name' ? '名前順' : '新しい順',
            icon: Icon(gOrder == 'name' ? Icons.sort_by_alpha : Icons.schedule),
            onPressed: () async {
              gOrder = gOrder == 'name' ? 'new' : 'name';
              final pr = await SharedPreferences.getInstance();
              await pr.setString('order', gOrder);
              setState(() {
                items = gListCache[cacheKey];
                error = null;
              });
              load();
            },
          ),
          IconButton(
            tooltip: gDesc ? '降順' : '昇順',
            icon: Icon(gDesc ? Icons.arrow_downward : Icons.arrow_upward),
            onPressed: () async {
              gDesc = !gDesc;
              final pr = await SharedPreferences.getInstance();
              await pr.setBool('desc', gDesc);
              setState(() {
                items = gListCache[cacheKey];
                error = null;
              });
              load();
            },
          ),
          if (isRoot)
            IconButton(
              tooltip: '端末内の動画',
              icon: const Icon(Icons.phone_android),
              onPressed: () => Navigator.push<dynamic>(context,
                  MaterialPageRoute(builder: (_) => const LocalBrowsePage())),
            ),
          if (isRoot)
            IconButton(
              tooltip: 'プレイリスト',
              icon: const Icon(Icons.queue_music),
              onPressed: () => Navigator.push<dynamic>(context,
                  MaterialPageRoute(builder: (_) => const PlaylistsPage())),
            ),
          if (isRoot)
            IconButton(
              tooltip: '履歴',
              icon: const Icon(Icons.history),
              onPressed: () async {
                await Navigator.push<dynamic>(context,
                    MaterialPageRoute(builder: (_) => const HistoryPage()));
                if (mounted) load();
              },
            ),
          if (isRoot)
            IconButton(icon: const Icon(Icons.settings), onPressed: editServer),
        ],
      ),
      body: body(),
    ));
  }
}

// ---------------------------------------------------------------- 動画

class PlayerPage extends StatefulWidget {
  final List<Entry> videos;
  final int start;
  const PlayerPage({super.key, required this.videos, required this.start});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  final List<StreamSubscription> subs = [];
  bool showUi = true;
  int index = 0;
  double? drag;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    index = widget.start;
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 通知（再生ボタン）を出すための許可。断られても再生はできる。
    Permission.notification.request();
    final paths = widget.videos.map((e) => e.path).toList();
    final cur = gPlayer.state.playlist.index;
    // 戻る（←）で裏再生にした動画をもう一度開いたときは、再生を続けたまま画面だけ戻す
    final sameRunning = gPlayer.state.playlist.medias.isNotEmpty &&
        paths.length == _bgPaths.length &&
        List.generate(paths.length, (i) => paths[i] == _bgPaths[i])
            .every((b) => b) &&
        cur >= 0 &&
        cur < paths.length &&
        paths[cur] == widget.videos[widget.start].path;
    _setVideoTrack(true);
    if (sameRunning) {
      index = cur;
    } else {
      _bgPaths = paths;
      audioHandler?.titles = widget.videos.map((e) => e.name).toList();
      final medias = widget.videos
          .map((e) => Media(mediaSrc(e)))
          .toList();
      gPlayer.open(Playlist(medias, index: widget.start));
      resume();
    }
    subs.add(gPlayer.stream.playlist.listen((p) {
      if (mounted) setState(() => index = p.index);
    }));
    if (sleepAt != null) {
      sleepTick = Timer.periodic(const Duration(seconds: 20), (_) {
        if (mounted) setState(() {});
      });
    }
    // 再生位置を10秒ごとに記録（次に開いたときに続きから）
    saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => savePos());
  }

  Timer? saveTimer;

  // ---- スリープタイマー（指定時間に再生を止める）
  static List<String> _bgPaths = [];
  static Timer? sleepTimer;
  Timer? sleepTick;
  static DateTime? sleepAt;

  void cancelSleep({bool update = true}) {
    sleepTimer?.cancel();
    sleepTick?.cancel();
    sleepTimer = null;
    sleepTick = null;
    sleepAt = null;
    if (update && mounted) setState(() {});
  }

  void setSleep(Duration d) {
    cancelSleep(update: false);
    sleepAt = DateTime.now().add(d);
    sleepTimer = Timer(d, sleepNow);
    sleepTick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${sleepLabel()}に停止します'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  void sleepNow() {
    cancelSleep(update: false);
    gPlayer.pause();
    savePos();
    Future.delayed(const Duration(milliseconds: 300), () => audioHandler?.sync());
    if (mounted) setState(() {});
  }

  String sleepLabel() {
    final at = sleepAt;
    if (at == null) return 'タイマー';
    final m = (at.difference(DateTime.now()).inSeconds / 60).ceil();
    return m <= 0 ? 'まもなく' : 'あと$m分';
  }

  Future<void> pickSleep() async {
    final r = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('再生を停める'),
        children: [
          for (final m in [15, 30, 45, 60, 90, 120])
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, m), child: Text('$m分後')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(c, -1),
              child: const Text('時刻を指定…')),
          if (sleepAt != null)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, -2),
                child: const Text('タイマーを解除')),
        ],
      ),
    );
    if (r == null || !mounted) return;
    if (r == -2) {
      cancelSleep();
    } else if (r == -1) {
      final t = await showTimePicker(
          context: context, initialTime: TimeOfDay.now());
      if (t == null || !mounted) return;
      final now = DateTime.now();
      var at = DateTime(now.year, now.month, now.day, t.hour, t.minute);
      if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
      setSleep(at.difference(now));
    } else {
      setSleep(Duration(minutes: r));
    }
  }

  // 前回の再生位置があれば、そこから再開する
  Future<void> resume() async {
    final v = widget.videos[widget.start];
    final h = await Hist.find('video', v.path);
    if (h == null || h.pos < 5000) return;
    try {
      final d = await gPlayer.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (h.pos < d.inMilliseconds - 10000) {
        await gPlayer.seek(Duration(milliseconds: h.pos));
      }
    } catch (_) {}
  }

  void savePos() {
    if (widget.videos.isEmpty) return;
    final v = widget.videos[math.min(math.max(index, 0), widget.videos.length - 1)];
    final pos = gPlayer.state.position.inMilliseconds;
    if (pos < 3000) return;
    Hist.put(HistItem(
      type: 'video',
      path: v.path,
      title: v.name,
      pos: pos,
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    sleepTick?.cancel();
    savePos();
    WidgetsBinding.instance.removeObserver(this);
    for (final s in subs) {
      s.cancel();
    }
    // 再生中なら止めずに音だけ続ける（映像は切る）。止まっているなら通知も消す。
    if (gPlayer.state.playing) {
      _setVideoTrack(false);
    } else {
      final h = audioHandler;
      if (h != null) {
        h.stop();
      } else {
        gPlayer.pause();
      }
      _setVideoTrack(true);
    }
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _setVideoTrack(bool on) {
    final p = gPlayer.platform;
    if (p is NativePlayer) {
      p.setProperty('vid', on ? 'auto' : 'no');
    }
  }

  // アプリが裏に回ったら映像だけ止めて音は続ける（戻ったら映像を復帰）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _setVideoTrack(false);
    } else if (state == AppLifecycleState.resumed) {
      _setVideoTrack(true);
    }
  }

  void seekBy(int sec) {
    final t = gPlayer.state.position + Duration(seconds: sec);
    gPlayer.seek(t < Duration.zero ? Duration.zero : t);
    Future.delayed(const Duration(milliseconds: 300), () => audioHandler?.sync());
  }

  Widget topBar() {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SafeArea(
        bottom: false,
        child: Row(children: [
          IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop()),
          Expanded(
            child: Text(
              widget.videos[math.min(math.max(index, 0), widget.videos.length - 1)]
                  .name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'mp3として保存',
            icon: const Icon(Icons.audio_file),
            onPressed: () => saveAsMp3(context, [
              widget.videos[
                  math.min(math.max(index, 0), widget.videos.length - 1)]
            ]),
          ),
          TextButton.icon(
            onPressed: pickSleep,
            icon: Icon(Icons.bedtime,
                color: sleepAt != null ? Colors.amber : Colors.white70),
            label: Text(sleepLabel(),
                style: TextStyle(
                    color: sleepAt != null ? Colors.amber : Colors.white70)),
          ),
        ]),
      ),
    );
  }

  Widget bottomBar() {
    return Container(
      color: Colors.black54,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          StreamBuilder<Duration>(
            stream: gPlayer.stream.position,
            builder: (context, snap) {
              final pos = snap.data ?? gPlayer.state.position;
              final dur = gPlayer.state.duration;
              final max =
                  dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
              final val = drag ?? math.min(pos.inMilliseconds.toDouble(), max);
              return Row(children: [
                const SizedBox(width: 12),
                Text(fmt(Duration(milliseconds: val.toInt()))),
                Expanded(
                  child: Slider(
                    value: val,
                    min: 0,
                    max: max,
                    onChanged: (v) => setState(() => drag = v),
                    onChangeEnd: (v) {
                      gPlayer.seek(Duration(milliseconds: v.toInt()));
                      setState(() => drag = null);
                      Future.delayed(const Duration(milliseconds: 300),
                          () => audioHandler?.sync());
                    },
                  ),
                ),
                Text(fmt(dur)),
                const SizedBox(width: 12),
              ]);
            },
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
                iconSize: 32,
                icon: const Icon(Icons.skip_previous),
                onPressed: () => gPlayer.previous()),
            IconButton(
                iconSize: 32,
                icon: const Icon(Icons.replay_10),
                onPressed: () => seekBy(-10)),
            StreamBuilder<bool>(
              stream: gPlayer.stream.playing,
              initialData: gPlayer.state.playing,
              builder: (context, snap) => IconButton(
                iconSize: 44,
                icon: Icon((snap.data ?? false) ? Icons.pause : Icons.play_arrow),
                onPressed: () => gPlayer.playOrPause(),
              ),
            ),
            IconButton(
                iconSize: 32,
                icon: const Icon(Icons.forward_10),
                onPressed: () => seekBy(10)),
            IconButton(
                iconSize: 32,
                icon: const Icon(Icons.skip_next),
                onPressed: () => gPlayer.next()),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: Video(
            controller: gController,
            controls: NoVideoControls,
            // 裏に回っても止めない（バックグラウンド再生のため）
            pauseUponEnteringBackgroundMode: false,
            resumeUponEnteringForegroundMode: false,
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => setState(() => showUi = !showUi),
            onDoubleTapDown: (d) {
              final w = MediaQuery.of(context).size.width;
              seekBy(d.localPosition.dx < w / 2 ? -10 : 10);
            },
            onDoubleTap: () {},
          ),
        ),
        if (showUi)
          Positioned.fill(
            child: Column(children: [
              topBar(),
              const Spacer(),
              bottomBar(),
            ]),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- 画像

class ViewerPage extends StatefulWidget {
  final String setPath; // フォルダ または 書庫
  final String title;
  final int start;
  final bool resumed; // 前回の続きから開いたか
  const ViewerPage({
    super.key,
    required this.setPath,
    required this.start,
    required this.title,
    this.resumed = false,
  });

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late PageController pc;
  int? count;
  String kind = '';
  List<String> names = [];
  String? err;
  int cur = 0;
  int rot = 0; // 時計回りに90°ずつ（0〜3）
  bool showUi = true;
  double? seekVal;
  Timer? histTimer;
  bool gone = false; // 削除して無くなったので、履歴に残さない
  String? nextPath; // 同じフォルダの次の巻
  String? nextName;
  bool armed = false; // 最後のページで1回目の知らせを出した
  bool replacing = false; // 次の巻へ差し替え中（画面モードを戻さない）
  double endPull = 0; // 最後のページで先へ引っ張った量

  // タップ判定用（PhotoView 標準のタップは遅いので、自前で判定する）
  int ptrs = 0;
  bool multi = false;
  Offset? downPos;
  Duration downAt = Duration.zero;

  String get rotKey => 'rotcw:${widget.setPath}';

  @override
  void initState() {
    super.initState();
    cur = widget.start;
    pc = PageController(initialPage: widget.start);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    loadCount();
    loadRot();
  }

  ScaffoldMessengerState? messenger;

  @override
  void dispose() {
    messenger?.clearSnackBars(); // 画面を離れたら、メッセージも消す
    histTimer?.cancel();
    saveHist(now: true);
    pc.dispose();
    if (!replacing) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // 開いたファイルとページを履歴に残す（次回、続きから開ける）
  void saveHist({bool now = false}) {
    histTimer?.cancel();
    void doSave() {
      final c = count;
      if (gone || c == null || c == 0) return;
      Hist.put(HistItem(
        type: 'set',
        path: widget.setPath,
        title: widget.title,
        page: cur,
        count: c,
        ts: DateTime.now().millisecondsSinceEpoch,
      ));
    }

    if (now) {
      doSave();
    } else {
      histTimer = Timer(const Duration(milliseconds: 700), doSave);
    }
  }

  void applySet(Map<String, dynamic> j) {
    count = (j['count'] as num).toInt();
    kind = '${j['kind']}';
    names = ((j['names'] as List?) ?? const []).map((e) => '$e').toList();
    final nx = j['next'];
    nextPath = (nx is String && nx.isNotEmpty) ? nx : null;
    nextName = nextPath == null ? null : '${j['next_name'] ?? nextPath}';
  }

  Future<void> loadCount() async {
    try {
      final j = await getJson('/api/set', {'p': widget.setPath})
          as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => applySet(j));
      final c = count ?? 0;
      if (c > 0 && cur >= c) {
        cur = c - 1;
        rebuildPages();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        preload(cur + 1);
        if (widget.resumed && cur > 0) {
          final m = ScaffoldMessenger.of(context);
          messenger = m;
          final ctl = m.showSnackBar(SnackBar(
            content: Text('前回の続き（${cur + 1}ページ）から開きました'),
            action: SnackBarAction(
                label: '最初から',
                onPressed: () {
                  pc.jumpToPage(0);
                }),
            duration: const Duration(seconds: 4),
          ));
          // ボタン付きのメッセージは自動では消えないことがあるので、自分で閉じる
          Future.delayed(const Duration(seconds: 4), () {
            try {
              ctl.close();
            } catch (_) {}
          });
        }
      });
      saveHist();
    } catch (e) {
      if (mounted) setState(() => err = '$e');
    }
  }

  // この書庫/フォルダで前回選んだ回転を復元
  Future<void> loadRot() async {
    final prefs = await SharedPreferences.getInstance();
    final r = prefs.getInt(rotKey) ?? 0;
    if (!mounted || r == rot) return;
    rot = r;
    rebuildPages();
  }

  // ページ送りの部品を作り直す（回転・向き・削除のあと）
  void rebuildPages() {
    final old = pc;
    pc = PageController(initialPage: cur);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  Future<void> rotateRight() async {
    rot = (rot + 1) % 4;
    rebuildPages();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(rotKey, rot);
  }

  Future<void> toggleDir() async {
    gRtl = !gRtl;
    rebuildPages();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rtl', gRtl);
  }

  Future<void> deleteCurrent() async {
    final isDir = kind == 'dir';
    if (isDir && cur >= names.length) {
      showMsg(context, 'サーバーの更新が必要です（画像の名前が取れません）');
      return;
    }
    final label = isDir ? names[cur] : widget.title;
    final ok = await confirmDelete(
        context,
        label,
        isDir
            ? 'この画像を完全に削除します。元に戻せません。'
            : 'この圧縮ファイルを丸ごと完全に削除します。元に戻せません。');
    if (!ok || !mounted) return;
    final msg = isDir
        ? await deleteOnServer(widget.setPath, index: cur, name: names[cur])
        : await deleteOnServer(widget.setPath);
    if (!mounted) return;
    if (msg != null) {
      showMsg(context, msg);
      return;
    }
    gRev++;
    gListCache.clear();
    if (!isDir) {
      gone = true;
      await Hist.remove('set', widget.setPath);
      if (!mounted) return;
      Navigator.pop(context, true);
      return;
    }
    try {
      final j = await getJson('/api/set', {'p': widget.setPath})
          as Map<String, dynamic>;
      if (!mounted) return;
      applySet(j);
      if ((count ?? 0) == 0) {
        gone = true;
        await Hist.remove('set', widget.setPath);
        if (!mounted) return;
        Navigator.pop(context, true);
        return;
      }
      cur = math.min(cur, (count ?? 1) - 1);
      rebuildPages();
      preload(cur + 1);
      saveHist();
    } catch (e) {
      if (mounted) setState(() => err = '$e');
    }
  }

  String url(int i, String v) => gUri(
          '/img', {'p': widget.setPath, 'i': '$i', 'v': v, 'r': '$gRev'})
      .toString();

  void preload(int from) {
    final c = count ?? 0;
    for (var k = from; k < from + 3 && k < c; k++) {
      precacheImage(CachedNetworkImageProvider(url(k, 'm')), context);
    }
  }

  // d>0 で次のページ、d<0 で前のページ（アニメーション無しで即切り替え）
  void go(int d) {
    final c = count ?? 0;
    final n = cur + d;
    if (d > 0 && n >= c) {
      endReached();
      return;
    }
    if (n < 0 || n >= c) return;
    pc.jumpToPage(n);
  }

  // いま見ているページを、この書庫の表紙（一覧のサムネ）にする
  Future<void> setCover() async {
    try {
      final res = await gHttp
          .post(gUri('/api/setcover', {}),
              headers: {'X-Gallery-Op': '1'},
              body: {'p': widget.setPath, 'i': '$cur'})
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (res.statusCode == 200) {
        gListCache.clear();
        showMsg(context, '${cur + 1}ページ目を表紙にしました');
      } else {
        showMsg(context, '表紙にできませんでした (${res.statusCode})');
      }
    } catch (e) {
      if (mounted) showMsg(context, '表紙にできませんでした: $e');
    }
  }

  // 最後のページで先へ進もうとした。1回目は知らせ、もう一度で次の巻へ。
  void endReached() {
    final np = nextPath;
    if (np == null) {
      showMsg(context, '最後のページです');
      return;
    }
    if (!armed) {
      armed = true;
      showMsg(context, '最後のページです。もう一度で次の巻へ\n${nextName ?? ''}');
      Future.delayed(const Duration(seconds: 3), () => armed = false);
      return;
    }
    openNext(np, nextName ?? np);
  }

  Future<void> openNext(String path, String title) async {
    final h = await Hist.find('set', path);
    final sp = h?.page ?? 0;
    if (!mounted) return;
    replacing = true;
    messenger?.clearSnackBars();
    ScaffoldMessenger.of(context).clearSnackBars();
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ViewerPage(
            setPath: path, start: sp, title: title, resumed: sp > 0)));
  }

  // タップ位置を「画像の向き」に直して、画面の左右どちらかでめくる。中央はメニュー。
  // 右開き: 左側をタップで次 / 右側で前。左開き: 右側で次 / 左側で前。
  void onTap(Offset g) {
    final s = MediaQuery.of(context).size;
    final u = g.dx / s.width;
    final v = g.dy / s.height;
    double h;
    switch (rot) {
      case 1:
        h = v;
        break;
      case 2:
        h = 1 - u;
        break;
      case 3:
        h = 1 - v;
        break;
      default:
        h = u;
    }
    if (h < 0.3) {
      go(gRtl ? 1 : -1);
    } else if (h > 0.7) {
      go(gRtl ? -1 : 1);
    } else {
      setState(() => showUi = !showUi);
    }
  }

  void onDown(PointerDownEvent e) {
    ptrs++;
    if (ptrs == 1) {
      multi = false;
      downPos = e.position;
      downAt = e.timeStamp;
    } else {
      multi = true;
    }
  }

  void onUp(PointerUpEvent e) {
    final start = downPos;
    final tap = ptrs == 1 &&
        !multi &&
        start != null &&
        (e.position - start).distance < 18 &&
        (e.timeStamp - downAt) < const Duration(milliseconds: 500);
    ptrs = math.max(0, ptrs - 1);
    if (tap) onTap(e.position);
  }

  void onCancel(PointerCancelEvent e) {
    ptrs = math.max(0, ptrs - 1);
    multi = true;
  }

  Widget gallery(int c) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: onDown,
      onPointerUp: onUp,
      onPointerCancel: onCancel,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 最後のページから先へ引っ張って離したら、次の巻の案内（タップと同じ）
          if (n is OverscrollNotification && cur == c - 1 && n.overscroll > 0) {
            endPull += n.overscroll;
          } else if (n is ScrollEndNotification) {
            final hit = endPull > 24 && cur == c - 1;
            endPull = 0;
            if (hit) endReached();
          }
          return false;
        },
        child: RotatedBox(
        quarterTurns: rot % 4,
        child: PhotoViewGallery.builder(
          key: ValueKey('$rot-$gRev-$gRtl'),
          pageController: pc,
          reverse: gRtl,
          itemCount: c,
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          onPageChanged: (i) {
            setState(() => cur = i);
            preload(i + 1);
            saveHist();
          },
          loadingBuilder: (context, event) =>
              const Center(child: CircularProgressIndicator()),
          builder: (context, i) => PhotoViewGalleryPageOptions(
            imageProvider: CachedNetworkImageProvider(url(i, 'm')),
            minScale: PhotoViewComputedScale.contained,
            initialScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.contained * 6,
            // ダブルタップ拡大はやめる（タップ送りを待たせないため）。拡大はピンチで。
            scaleStateCycle: (state) => state,
            errorBuilder: (context, error, stack) =>
                const Center(child: Icon(Icons.broken_image, size: 48)),
          ),
        ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (err != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(child: Text('読み込めません\n$err', textAlign: TextAlign.center)),
      );
    }
    final c = count;
    if (c == null) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()));
    }
    final seek = seekVal ?? cur.toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(child: gallery(c)),
        if (showUi)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Container(
              color: Colors.black54,
              child: SafeArea(
                bottom: false,
                child: Row(children: [
                  IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).pop()),
                  Text('${cur + 1} / $c'),
                  const Spacer(),
                  if (kind != 'dir')
                    IconButton(
                        tooltip: 'このページを表紙にする',
                        icon: const Icon(Icons.photo_album_outlined),
                        onPressed: setCover),
                  IconButton(
                      tooltip: '削除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: deleteCurrent),
                  TextButton(
                      onPressed: toggleDir,
                      child: Text(gRtl ? '右開き' : '左開き')),
                  IconButton(
                      tooltip: '時計回りに回転',
                      icon: const Icon(Icons.rotate_right),
                      onPressed: rotateRight),
                ]),
              ),
            ),
          ),
        if (showUi)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              child: SafeArea(
                top: false,
                child: Row(children: [
                  // 親指が届く下バーにも「戻る」を置く（上のバーまで手を伸ばさなくてよい）
                  IconButton(
                      tooltip: '戻る',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).pop()),
                  if (c > 1)
                    Expanded(
                      // 右開きのときは、シークバーも右が1ページ目になる
                      child: Directionality(
                        textDirection:
                            gRtl ? TextDirection.rtl : TextDirection.ltr,
                        child: Row(children: [
                          const SizedBox(width: 4),
                          Text('${seek.round() + 1}'),
                          Expanded(
                            child: Slider(
                              value: seek,
                              min: 0,
                              max: (c - 1).toDouble(),
                              divisions: c - 1,
                              label: '${seek.round() + 1}',
                              onChanged: (v) => setState(() => seekVal = v),
                              onChangeEnd: (v) {
                                pc.jumpToPage(v.round());
                                setState(() => seekVal = null);
                              },
                            ),
                          ),
                          Text('$c'),
                          const SizedBox(width: 12),
                        ]),
                      ),
                    ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- 履歴

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<HistItem>? items;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final l = await Hist.all();
    if (!mounted) return;
    setState(() => items = List<HistItem>.from(l));
  }

  Future<void> open(HistItem h) async {
    Widget page;
    if (h.type == 'video') {
      page = PlayerPage(
          videos: [Entry(h.title, 'video', h.path, 0, 0)], start: 0);
    } else {
      page = ViewerPage(
          setPath: h.path, start: h.page, title: h.title, resumed: h.page > 0);
    }
    await Navigator.push<dynamic>(context, MaterialPageRoute(builder: (_) => page));
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    return Scaffold(
      appBar: AppBar(title: const Text('履歴')),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? const Center(child: Text('履歴はまだありません'))
              : ListView.builder(
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).padding.bottom),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final h = list[i];
                    final sub = h.type == 'video'
                        ? '再生位置 ${fmt(Duration(milliseconds: h.pos))} ・ ${fmtTime(h.ts)}'
                        : '${h.page + 1} / ${h.count} ページ ・ ${fmtTime(h.ts)}';
                    return ListTile(
                      leading:
                          Icon(h.type == 'video' ? Icons.videocam : Icons.collections),
                      title: Text(h.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(sub),
                      trailing: IconButton(
                        tooltip: '履歴から消す',
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          await Hist.remove(h.type, h.path);
                          if (mounted) load();
                        },
                      ),
                      onTap: () => open(h),
                    );
                  },
                ),
    );
  }
}
