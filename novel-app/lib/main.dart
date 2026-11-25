import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kDefaultUrl = 'http://100.102.7.80:5056';

void main() => runApp(const NovelApp());

class NovelApp extends StatelessWidget {
  const NovelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ノベル',
      debugShowCheckedModeBanner: false,
      // 日本語の字形で表示する（指定がないと中国語風の字形になることがある）
      locale: const Locale('ja', 'JP'),
      // 日本語を指定すると、これがないと説明パネルやダイアログが開けず、一覧が灰色になる
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ja', 'JP'), Locale('en', 'US')],
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF111111),
      ),
      home: const BookListPage(),
    );
  }
}

// ---------------------------------------------------------------- データ

class Line {
  final String sp; // 話者（地の文は空）
  final String t; // 本文
  final String? r; // ルビ付き本文（｜漢字《よみ》）
  final String? v; // 視点（この視点のときだけ表示）
  final String? bId; // 分岐: 選択肢ID
  final int bIdx; // 分岐: 番号
  final String? ocId; // 選択肢の行: 選択肢ID
  final int ocIdx; // 選択肢の行: 番号
  final bool h; // 分岐の見出し行
  final int k; // ページの共通番号（ルートが違っても同じ場面は同じ番号）
  final int vo; // 声の番号（なければ -1）。サーバーの /api/voice/番号 で再生する
  final Map<String, dynamic>? g; // この行から見える絵（背景層 b=[[番号,z],..] と立ち絵 s=[[スロット,番号,x],..]）
  final int? bgm; // この行からBGMが変わる（番号。-1 は停止、null は変化なし）
  final List<String> tm; // この行に出てくる用語（色を変えて、タップで説明を見せる）
  Line(this.sp, this.t, this.r,
      {this.k = -1,
      this.vo = -1,
      this.bgm,
      this.g,
      this.v,
      this.bId,
      this.bIdx = -1,
      this.ocId,
      this.ocIdx = -1,
      this.h = false,
      this.tm = const []});
}

class Term {
  final String reading; // 読み
  final String desc; // 説明
  Term(this.reading, this.desc);
}

class Book {
  final String title;
  final Map<String, Term> terms = {}; // 用語辞典（見出し → 読み・説明）
  final List<String> sceneIds = [];
  final List<int> sceneStart = []; // 各場面の最初のページ番号
  final List<int> sceneOf = []; // ページ番号 → 場面番号
  final List<List<Line>> pages = [];
  final Set<String> views = {};
  final Set<String> choices = {};
  final List<int> choicePages = []; // 選択肢のあるページ番号

  Book.fromJson(Map<String, dynamic> j) : title = (j['title'] as String?) ?? '' {
    final tj = j['terms'];
    if (tj is Map) {
      tj.forEach((k, v) {
        if (v is Map) terms['$k'] = Term('${v['r'] ?? ''}', '${v['d'] ?? ''}');
      });
    }
    final scenes = j['scenes'] as List;
    for (var si = 0; si < scenes.length; si++) {
      final s = scenes[si] as Map<String, dynamic>;
      sceneIds.add(s['id'] as String);
      sceneStart.add(pages.length);
      for (final p in (s['pages'] as List)) {
        final lines = <Line>[];
        for (final l in (p as List)) {
          final m = l as Map<String, dynamic>;
          final b = m['b'] as List?;
          final oc = m['oc'] as List?;
          final v = m['v'] as String?;
          if (v != null) views.add(v);
          if (oc != null) choices.add(oc[0] as String);
          lines.add(Line((m['sp'] as String?) ?? '', m['t'] as String, m['r'] as String?,
              k: (m['k'] as num?)?.toInt() ?? pages.length,
              vo: (m['vo'] as num?)?.toInt() ?? -1,
              bgm: (m['bgm'] as num?)?.toInt(),
              g: m['g'] as Map<String, dynamic>?,
              v: v,
              bId: b == null ? null : b[0] as String,
              bIdx: b == null ? -1 : (b[1] as num).toInt(),
              ocId: oc == null ? null : oc[0] as String,
              ocIdx: oc == null ? -1 : (oc[1] as num).toInt(),
              h: m['h'] != null,
              tm: [
                for (final x in (m['tm'] as List? ?? const <dynamic>[]))
                  if (terms.containsKey(x.toString())) x.toString()
              ]));
        }
        pages.add(lines);
        if (lines.any((x) => x.ocId != null)) choicePages.add(pages.length - 1);
        sceneOf.add(si);
      }
    }
  }
}

// ---------------------------------------------------------------- 縦書き部品

class VCol {
  final String text; // 1列ぶんの文字
  final bool speaker; // 話者名の列
  final String sp;
  final int page; // 元のページ番号
  final String? ocId;
  final int ocIdx;
  final List<String?>? marks; // 1文字ごとの用語名（用語でなければ null）
  VCol(this.text, this.speaker, this.sp, this.page, {this.ocId, this.ocIdx = -1, this.marks});
}

const String kNoStart = '、。，．」』）】〕！？ー…‥・ゝゞ々〜ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ'; // 行頭に置かない
const String kNoEnd = '「『（【〔'; // 行末に置かない
const String kRot = 'ー―—…‥〜～「」『』（）()【】〔〕-'; // 90度回す
const String kShift = '、。，．'; // 右上に寄せる

/// 1列ぶんずつの区切り位置（文字番号の [始め, 終わり)）。
List<List<int>> chunkRanges(String s, int n) {
  final ch = s.runes.map(String.fromCharCode).toList();
  final out = <List<int>>[];
  var i = 0;
  while (i < ch.length) {
    var end = math.min(i + n, ch.length);
    if (end < ch.length) {
      while (end > i + 1 && (kNoStart.contains(ch[end]) || kNoEnd.contains(ch[end - 1]))) {
        end--;
      }
    }
    out.add([i, end]);
    i = end;
  }
  return out;
}

/// 本文の1文字ごとに、その文字が属する用語名（用語でなければ null）。用語がなければ null。
List<String?>? termMarks(String body, List<String> tm) {
  if (tm.isEmpty) return null;
  final br = body.runes.toList();
  final out = List<String?>.filled(br.length, null);
  var any = false;
  final ts = [...tm]..sort((a, b) => b.runes.length.compareTo(a.runes.length));
  for (final t in ts) {
    final tr = t.runes.toList();
    if (tr.isEmpty) continue;
    for (var i = 0; i + tr.length <= br.length; i++) {
      var ok = true;
      for (var j = 0; j < tr.length; j++) {
        if (br[i + j] != tr[j] || out[i + j] != null) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      for (var j = 0; j < tr.length; j++) {
        out[i + j] = t;
      }
      any = true;
      i += tr.length - 1;
    }
  }
  return any ? out : null;
}

List<String> chunkText(String s, int n) {
  final ch = s.runes.map(String.fromCharCode).toList();
  final out = <String>[];
  var i = 0;
  while (i < ch.length) {
    var end = math.min(i + n, ch.length);
    if (end < ch.length) {
      while (end > i + 1 && (kNoStart.contains(ch[end]) || kNoEnd.contains(ch[end - 1]))) {
        end--;
      }
    }
    out.add(ch.sublist(i, end).join());
    i = end;
  }
  return out;
}

class RItem {
  final int page; // 代表の元ページ番号
  final List<List<Line>> parts; // 1つ=通常 / 2つ=並べ表示（上・下）
  final List<String> labels;
  RItem(this.page, this.parts, [this.labels = const []]);
}

class LP {
  final Line l;
  final int p;
  LP(this.l, this.p);
}

Future<File> cacheFile(String id) async {
  final dir = await getApplicationDocumentsDirectory();
  final d = Directory('${dir.path}/books');
  if (!await d.exists()) {
    await d.create(recursive: true);
  }
  return File('${d.path}/$id.json');
}

// ---------------------------------------------------------------- 本の一覧

class BookListPage extends StatefulWidget {
  const BookListPage({super.key});

  @override
  State<BookListPage> createState() => _BookListPageState();
}

class _BookListPageState extends State<BookListPage> {
  SharedPreferences? prefs;
  String baseUrl = kDefaultUrl;
  List<Map<String, dynamic>> books = [];
  Map<String, bool> cached = {};
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    prefs = await SharedPreferences.getInstance();
    baseUrl = prefs!.getString('server_url') ?? kDefaultUrl;
    await _loadList();
  }

  Future<void> _loadList() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/books'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final list = (jsonDecode(utf8.decode(res.bodyBytes)) as List)
          .map((e) => e as Map<String, dynamic>)
          .toList();
      final c = <String, bool>{};
      for (final b in list) {
        c[b['id'] as String] = await (await cacheFile(b['id'] as String)).exists();
      }
      if (!mounted) return;
      setState(() {
        books = list;
        cached = c;
        loading = false;
      });
    } catch (e) {
      // サーバーに繋がらなくても、保存済みの本は読めるようにする
      final saved = await _savedBooks();
      if (!mounted) return;
      setState(() {
        books = saved;
        cached = {for (final b in saved) b['id'] as String: true};
        error = saved.isEmpty ? '接続できません' : '接続できません（保存済みの本を表示）';
        loading = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _savedBooks() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/books');
    if (!await d.exists()) return [];
    final out = <Map<String, dynamic>>[];
    for (final f in d.listSync()) {
      if (f is File && f.path.endsWith('.json')) {
        final name = f.path.split('/').last;
        final id = name.substring(0, name.length - 5);
        out.add({
          'id': id,
          'title': prefs?.getString('title_$id') ?? id,
          'series': prefs?.getString('series_$id') ?? '',
          'route': prefs?.getString('route_$id') ?? '',
        });
      }
    }
    return out;
  }

  Future<void> _download(String id) async {
    final res = await http
        .get(Uri.parse('$baseUrl/api/book/$id'))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    await (await cacheFile(id)).writeAsBytes(res.bodyBytes);
    cached[id] = true;
  }

  Future<void> _open(Map<String, dynamic> b, {bool force = false}) async {
    final id = b['id'] as String;
    try {
      var downloaded = false;
      if (force || cached[id] != true) {
        _snack('ダウンロード中...');
        await _download(id);
        downloaded = true;
      }
      final text = await (await cacheFile(id)).readAsString();
      final book = Book.fromJson(jsonDecode(text) as Map<String, dynamic>);
      await prefs!.setString('title_$id', book.title);
      await prefs!.setString('series_$id', (b['series'] as String?) ?? '');
      await prefs!.setString('route_$id', (b['route'] as String?) ?? '');
      if (downloaded) {
        if (mounted) {
          setState(() {});
          _snack('ダウンロードしました');
        }
        return;
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ReaderPage(
                id: id,
                book: book,
                prefs: prefs!,
                siblings: _siblingIds(b))),
      );
      if (mounted) setState(() {});
    } catch (e) {
      _snack('開けませんでした: $e');
    }
  }

  List<String> _siblingIds(Map<String, dynamic> b) {
    final s = (b['series'] as String?) ?? '';
    if (s.isEmpty) return [];
    return [for (final x in _seriesBooks(s)) x['id'] as String];
  }

  List<String> _seriesNames() {
    final out = <String>[];
    for (final b in books) {
      final s = (b['series'] as String?) ?? '';
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  List<Map<String, dynamic>> _seriesBooks(String name) =>
      books.where((b) => (b['series'] as String?) == name).toList();

  final Set<String> _openSeries = {}; // 開いているシリーズ（最初は全部たたむ）

  Widget _bookTile(Map<String, dynamic> b, bool inSeries) {
    final route = (b['route'] as String?) ?? '';
    final title = (inSeries && route.isNotEmpty)
        ? route
        : ((b['title'] as String?)?.isNotEmpty == true ? b['title'] as String : b['id'] as String);
    return ListTile(
      contentPadding: EdgeInsets.only(left: inSeries ? 40 : 16, right: 16),
      title: Text(title),
      subtitle: Text(b['pages'] != null ? '${b['scenes']}場面 / ${b['pages']}ページ' : '保存済み'),
      trailing: Icon(cached[b['id']] == true ? Icons.check_circle : Icons.cloud_download),
      onTap: () => _open(b),
      onLongPress: () => _open(b, force: true), // 長押しで再ダウンロード
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _editUrl() async {
    final ctrl = TextEditingController(text: baseUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('サーバーのURL'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'http://100.x.x.x:5056'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    baseUrl = result.endsWith('/') ? result.substring(0, result.length - 1) : result;
    await prefs?.setString('server_url', baseUrl);
    await _loadList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ノベル  (ビルド 11/15 03:05)', style: TextStyle(fontSize: 18)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadList),
          IconButton(icon: const Icon(Icons.settings), onPressed: _editUrl),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (error != null)
                  Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
                for (final b in books.where((b) => ((b['series'] as String?) ?? '').isEmpty))
                  _bookTile(b, false),
                for (final name in _seriesNames()) ...[
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(name),
                    subtitle: Text('${_seriesBooks(name).length}冊（ルート別）'),
                    trailing: Icon(_openSeries.contains(name) ? Icons.expand_less : Icons.expand_more),
                    onTap: () => setState(() {
                      if (!_openSeries.remove(name)) _openSeries.add(name);
                    }),
                  ),
                  if (_openSeries.contains(name))
                    for (final b in _seriesBooks(name)) _bookTile(b, true),
                ],
                if (books.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('長押しで、本文を再ダウンロードします',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------- 読む画面

class ReaderPage extends StatefulWidget {
  final String id;
  final Book book;
  final SharedPreferences prefs;
  final List<String> siblings; // 同じゲームの他のルートの本のid（既読の共有用）
  const ReaderPage(
      {super.key,
      required this.id,
      required this.book,
      required this.prefs,
      this.siblings = const []});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late PageController pc;
  late PageController vpc;
  late bool vertical;
  late bool hflipV; // 横書きを連続スクロールで読む
  ScrollController sc = ScrollController();
  final Key _ctr = UniqueKey();
  final GlobalKey _flowBox = GlobalKey();
  final Map<int, GlobalKey> _ik = {};
  int sCenter = 0;
  int topIdx = 0;
  bool get scrollMode => !vertical && hflipV && !sideBySide;
  String _key = '';
  String? viewSel;
  final Set<int> readThis = {}; // この本で読んだページ
  final Set<int> readOther = {}; // 他のルートで読んだページ
  late int otherMode; // 0=色を変える 1=飛ばす 2=そのまま
  late bool dimRead;
  late bool choose;
  final Map<String, int> picks = {};
  List<int> hv = [];
  List<RItem> hitems = [];
  late bool sideBySide; // 視点を並べて表示
  List<List<VCol>?> screens2 = [];
  List<List<VCol>> screens = [];
  List<int> sStart = [];
  late int cur;
  bool bars = false;
  late double font;
  late bool ruby;
  late bool light;
  final AudioPlayer _ap = AudioPlayer();
  List<int> _vq = []; // これから再生する声の番号
  bool voicePlaying = false;
  final AudioPlayer _bp = AudioPlayer();
  Map<String, dynamic>? _g; // いま見えている絵
  bool gfxOn = true;
  late final bool hasGfx = widget.book.pages.any((p) => p.any((l) => l.g != null));
  int _bgmNow = -1; // いま鳴らしているBGM番号
  bool bgmOn = true;
  late final bool hasBgm = widget.book.pages.any((p) => p.any((l) => l.bgm != null));
  bool autoVoice = true;
  int _lastVoiceCur = -1;
  final Set<int> _vSeen = {}; // ページが進むたびに、その声を自動で鳴らす
  late final bool hasVoice = widget.book.pages.any((p) => p.any((l) => l.vo >= 0));

  Book get book => widget.book;

  @override
  void initState() {
    super.initState();
    _ap.onPlayerComplete.listen((_) => _playNextVoice());
    final p = widget.prefs;
    final saved = p.getInt('pos_${widget.id}') ?? 0;
    final last = book.pages.length - 1;
    cur = saved < 0 ? 0 : (saved > last ? last : saved);
    font = p.getDouble('font') ?? 18;
    ruby = p.getBool('ruby') ?? false;
    light = p.getBool('light') ?? false;
    autoVoice = p.getBool('autoVoice') ?? true;
    bgmOn = p.getBool('bgmOn') ?? true;
    gfxOn = p.getBool('gfxOn') ?? true;
    _bp.setReleaseMode(ReleaseMode.loop);
    _bp.setVolume(0.6);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      updateBgm();
      updateGfx();
    });
    vertical = p.getBool('vertical') ?? true;
    hflipV = p.getBool('hflipV') ?? true;
    viewSel = p.getString('view_${widget.id}');
    for (final x in p.getStringList('rk_${widget.id}') ?? const <String>[]) {
      final n = int.tryParse(x);
      if (n != null) readThis.add(n);
    }
    for (final sid in widget.siblings) {
      if (sid == widget.id) continue;
      for (final x in p.getStringList('rk_$sid') ?? const <String>[]) {
        final n = int.tryParse(x);
        if (n != null) readOther.add(n);
      }
    }
    otherMode = p.getInt('otherMode') ?? 0;
    sideBySide = p.getBool('split_${widget.id}') ?? false;
    dimRead = p.getBool('dimRead') ?? true;
    choose = p.getBool('choose') ?? false;
    final pre = 'pick_${widget.id}_';
    for (final k in p.getKeys()) {
      if (k.startsWith(pre)) picks[k.substring(pre.length)] = p.getInt(k) ?? 0;
    }
    rebuildHv();
    pc = PageController(initialPage: hpos(cur));
    vpc = PageController();
    sCenter = hpos(cur);
    topIdx = sCenter;
  }

  @override
  void dispose() {
    _ap.dispose();
    _bp.dispose();
    sc.dispose();
    pc.dispose();
    vpc.dispose();
    super.dispose();
  }

  Color get bg => light ? const Color(0xFFF5F0E6) : const Color(0xFF111111);
  Color get fg => light ? const Color(0xFF222222) : const Color(0xFFE0E0E0);

  static const List<Color> _spColors = [
    Color(0xFFFFB74D),
    Color(0xFF64B5F6),
    Color(0xFF81C784),
    Color(0xFFBA68C8),
    Color(0xFFE57373),
    Color(0xFF4DD0E1),
  ];

  Color spColor(String name) {
    var h = 0;
    for (final r in name.runes) {
      h = (h * 31 + r) & 0x7fffffff;
    }
    final c = _spColors[h % _spColors.length];
    return light ? Color.lerp(c, Colors.black, 0.45)! : c;
  }

  Color termColor(int st) =>
      tone(light ? const Color(0xFF0277BD) : const Color(0xFF4FC3F7), st);

  void showTerm(String name) {
    final t = book.terms[name];
    if (t == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                if (t.reading.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('（${t.reading}）',
                        style: const TextStyle(fontSize: 14, color: Colors.grey)),
                  ),
                const SizedBox(height: 14),
                Text(t.desc, style: const TextStyle(fontSize: 16, height: 1.8)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void showDictionary() {
    final names = book.terms.keys.toList();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: ListView.builder(
          itemCount: names.length,
          itemBuilder: (c, i) {
            final t = book.terms[names[i]]!;
            return ListTile(
              dense: true,
              title: Text(t.reading.isEmpty ? names[i] : '${names[i]}（${t.reading}）'),
              subtitle:
                  Text(t.desc.replaceAll('\n', ' '), maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(ctx);
                showTerm(names[i]);
              },
            );
          },
        ),
      ),
    );
  }

  // 横書き: 用語の部分だけ色を変えて下線を引き、タップで説明を出す
  Widget termText(String body, List<String> tm, TextStyle style, int st) {
    final marks = termMarks(body, tm);
    if (marks == null) return Text(body, style: style);
    final ch = body.runes.map(String.fromCharCode).toList();
    final spans = <InlineSpan>[];
    var i = 0;
    while (i < ch.length) {
      final name = marks[i];
      var j = i + 1;
      while (j < ch.length && marks[j] == name) {
        j++;
      }
      final seg = ch.sublist(i, j).join();
      if (name == null) {
        spans.add(TextSpan(text: seg));
      } else {
        final c = termColor(st);
        spans.add(TextSpan(
          text: seg,
          style: TextStyle(color: c, decoration: TextDecoration.underline, decorationColor: c),
          recognizer: TapGestureRecognizer()..onTap = () => showTerm(name),
        ));
      }
      i = j;
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }

  String rubyToParen(String s) {
    return s.replaceAllMapped(RegExp(r'｜([^《]+)《([^》]+)》'), (m) => '${m[1]}（${m[2]}）');
  }

  Widget lineWidget(Line l) {
    final st = stateOfK(l.k);
    final body = (ruby && l.r != null) ? rubyToParen(l.r!) : l.t;
    final style = TextStyle(fontSize: font, height: 1.8, color: tone(fg, st));
    if (choose && l.ocId != null) {
      final on = picks[l.ocId!] == l.ocIdx;
      final c = on ? Colors.amber : fg;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
              foregroundColor: c, side: BorderSide(color: on ? Colors.amber : fg.withAlpha(110))),
          onPressed: () => pick(l.ocId!, l.ocIdx),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(body.replaceFirst('　▶ ', ''), style: style.copyWith(color: c)),
          ),
        ),
      );
    }
    if (l.sp.isEmpty) {
      return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: termText(body, l.tm, style, st));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.sp,
              style: TextStyle(
                  fontSize: font * 0.8, fontWeight: FontWeight.bold, color: tone(spColor(l.sp), st))),
          termText(body, l.tm, style, st),
        ],
      ),
    );
  }

  Widget splitPage(RItem it) {
    Widget panel(int k) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('【${it.labels[k]}視点】',
                  style: TextStyle(
                      fontSize: font * 0.8,
                      fontWeight: FontWeight.bold,
                      color: spColor(it.labels[k]))),
              for (final l in it.parts[k]) lineWidget(l),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 48, 0, 64),
      child: Column(children: [
        Expanded(child: panel(0)),
        Divider(height: 1, color: fg.withAlpha(80)),
        Expanded(child: panel(1)),
      ]),
    );
  }

  Widget pageWidget(int i) {
    final it = hitems[i];
    if (it.parts.length == 2) return splitPage(it);
    final lines = it.parts[0];
    final v = lines.isEmpty ? null : lines.first.v;
    String? pv;
    if (i > 0) {
      final pl = hitems[i - 1].parts.last;
      pv = pl.isEmpty ? null : pl.last.v;
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 56, 20, 72),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sceneBreak(i) != null) sceneBreak(i)!,
          if (viewSel == null && v != null && v != pv)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('【$v視点】',
                  style: TextStyle(
                      fontSize: font * 0.8, fontWeight: FontWeight.bold, color: spColor(v))),
            ),
          for (final l in lines) lineWidget(l),
        ],
      ),
    );
  }

  static const String kSplit = '#split';

  String? get viewToken => sideBySide ? kSplit : viewSel;

  String viewLabel(String? t) => t == null ? '全部' : (t == kSplit ? '並べる' : t);

  void setViewToken(String? t) {
    sideBySide = t == kSplit;
    viewSel = (t == null || t == kSplit || t.isEmpty) ? null : t;
    if (viewSel == null) {
      widget.prefs.remove('view_${widget.id}');
    } else {
      widget.prefs.setString('view_${widget.id}', viewSel!);
    }
    widget.prefs.setBool('split_${widget.id}', sideBySide);
    relayout();
  }

  void cycleView() {
    final opts = <String?>[null, ...(book.views.toList()..sort()), if (book.views.length == 2) kSplit];
    final k = opts.indexOf(viewToken);
    setViewToken(opts[(k + 1) % opts.length]);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(viewToken == null
            ? '視点: 全部（分かれた本文を順に表示）'
            : '視点: ${viewLabel(viewToken)}')));
  }

  bool lineVisible(Line l) {
    if (viewSel != null && l.v != null && l.v != viewSel) return false;
    if (choose) {
      if (l.h) return false;
      if (l.bId != null && picks[l.bId!] != l.bIdx) return false;
    }
    return true;
  }

  List<Line> visibleLines(int pi) {
    final ls = book.pages[pi].where(lineVisible).toList();
    if (ls.isNotEmpty && otherMode == 1) {
      final k = ls.first.k;
      if (readOther.contains(k) && !readThis.contains(k)) return [];
    }
    return ls;
  }

  void rebuildHv() {
    final items = <RItem>[];
    var i = 0;
    while (i < book.pages.length) {
      final vis = visibleLines(i);
      if (vis.isEmpty) {
        i++;
        continue;
      }
      if (sideBySide && vis.first.v != null) {
        var j = i;
        final order = <String>[];
        final per = <String, List<List<Line>>>{};
        final idx = <String, List<int>>{};
        while (j < book.pages.length) {
          final vl = visibleLines(j);
          if (vl.isEmpty) {
            j++;
            continue;
          }
          final v = vl.first.v;
          if (v == null) break;
          if (!per.containsKey(v)) {
            order.add(v);
            per[v] = [];
            idx[v] = [];
          }
          per[v]!.add(vl);
          idx[v]!.add(j);
          j++;
        }
        if (order.length == 2) {
          final a = order[0];
          final b = order[1];
          final k = math.max(per[a]!.length, per[b]!.length);
          for (var q = 0; q < k; q++) {
            final pa = q < per[a]!.length ? per[a]![q] : <Line>[];
            final pb = q < per[b]!.length ? per[b]![q] : <Line>[];
            final pg = q < idx[a]!.length ? idx[a]![q] : idx[b]![q];
            items.add(RItem(pg, [pa, pb], [a, b]));
          }
          i = j;
          continue;
        }
      }
      items.add(RItem(i, [vis]));
      i++;
    }
    hitems = items;
    hv = [for (final it in items) it.page];
  }

  int hpos(int gp) {
    var r = 0;
    for (var k = 0; k < hv.length; k++) {
      if (hv[k] <= gp) {
        r = k;
      } else {
        break;
      }
    }
    return r;
  }

  int hposFwd(int gp) {
    for (var k = 0; k < hv.length; k++) {
      if (hv[k] >= gp) return k;
    }
    return math.max(0, hv.length - 1);
  }

  void relayout() {
    setState(() {
      rebuildHv();
      final o1 = pc;
      final o2 = vpc;
      pc = PageController(initialPage: hpos(cur));
      vpc = PageController();
      final o3 = sc;
      sc = ScrollController();
      sCenter = hpos(cur);
      topIdx = sCenter;
      _ik.clear();
      _key = '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        o1.dispose();
        o2.dispose();
        o3.dispose();
      });
    });
  }

  void markKeys(Iterable<int> ks) {
    var changed = false;
    for (final k in ks) {
      if (k >= 0 && readThis.add(k)) changed = true;
    }
    if (changed) {
      widget.prefs.setStringList('rk_${widget.id}', [for (final k in readThis) '$k']);
    }
  }

  int kOfPage(int pi) => book.pages[pi].first.k;

  // 0=未読 1=他のルートで既読 2=この本で既読
  int stateOfK(int k) {
    if (readThis.contains(k)) return 2;
    if (readOther.contains(k) && otherMode == 0) return 1;
    return 0;
  }

  Color tone(Color c, int st) {
    if (st == 2 && dimRead) return c.withAlpha(115);
    if (st == 1) return Color.lerp(c, const Color(0xFF26A69A), 0.6)!.withAlpha(215);
    return c;
  }

  int posOf(int gp) => vertical ? screenOf(gp) : hpos(gp);

  void backToChoice() {
    final here = posOf(cur);
    int? target;
    for (final p in book.choicePages) {
      if (posOf(p) < here) target = p;
    }
    if (target == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('これより前に選択肢はありません')));
      return;
    }
    jumpToPage(target);
  }

  void pick(String id, int idx) {
    picks[id] = idx;
    widget.prefs.setInt('pick_${widget.id}_$id', idx);
    relayout();
  }

  String bodyOf(Line l) => (ruby && l.r != null) ? rubyToParen(l.r!) : l.t;

  void paginate(int n, int cols, int half) {
    screens = [];
    screens2 = [];
    sStart = [];
    var buf = <VCol>[];
    void flush() {
      if (buf.isNotEmpty) {
        screens.add(buf);
        screens2.add(null);
        sStart.add(buf.first.page);
        buf = [];
      }
    }

    void add(VCol v) {
      if (buf.length >= cols) flush();
      buf.add(v);
    }

    List<VCol> panelCols(String v, List<LP> items) {
      final out = <VCol>[];
      out.add(VCol('【$v】'.runes.take(n).map(String.fromCharCode).join(), true, v, items.first.p));
      var psp = '';
      for (final it in items) {
        final l = it.l;
        final needSp = l.sp.isNotEmpty && l.sp != psp;
        psp = l.sp;
        if (needSp) {
          out.add(VCol(l.sp.runes.take(n).map(String.fromCharCode).join(), true, l.sp, it.p));
        }
        final isOc = choose && l.ocId != null;
        final body = isOc ? '▶${bodyOf(l).replaceFirst('　▶ ', '')}' : bodyOf(l);
        final mk = termMarks(body, l.tm);
        final cr = body.runes.map(String.fromCharCode).toList();
        for (final r in chunkRanges(body, n)) {
          out.add(VCol(cr.sublist(r[0], r[1]).join(), false, l.sp, it.p,
              ocId: isOc ? l.ocId : null, ocIdx: l.ocIdx, marks: mk?.sublist(r[0], r[1])));
        }
      }
      return out;
    }

    var lastScene = -1;
    var prevSp = '';
    String? prevV;
    var skipUntil = -1;
    for (var pi = 0; pi < book.pages.length; pi++) {
      if (pi < skipUntil) continue;
      final vis = visibleLines(pi);
      if (vis.isEmpty) continue;
      if (book.sceneOf[pi] != lastScene) {
        lastScene = book.sceneOf[pi];
        flush();
        prevSp = '';
        prevV = null;
      }
      if (sideBySide && vis.first.v != null) {
        var j = pi;
        final order = <String>[];
        final per = <String, List<LP>>{};
        while (j < book.pages.length) {
          final vl = visibleLines(j);
          if (vl.isEmpty) {
            j++;
            continue;
          }
          final v = vl.first.v;
          if (v == null) break;
          if (!per.containsKey(v)) {
            order.add(v);
            per[v] = [];
          }
          for (final l in vl) {
            per[v]!.add(LP(l, j));
          }
          j++;
        }
        if (order.length == 2) {
          flush();
          final ca = panelCols(order[0], per[order[0]]!);
          final cb = panelCols(order[1], per[order[1]]!);
          final k = math.max((ca.length + half - 1) ~/ half, (cb.length + half - 1) ~/ half);
          for (var q = 0; q < k; q++) {
            final a = ca.sublist(math.min(q * half, ca.length), math.min((q + 1) * half, ca.length));
            final b = cb.sublist(math.min(q * half, cb.length), math.min((q + 1) * half, cb.length));
            screens.add(a);
            screens2.add(b);
            sStart.add(a.isNotEmpty ? a.first.page : (b.isNotEmpty ? b.first.page : pi));
          }
          skipUntil = j;
          prevSp = '';
          prevV = null;
          continue;
        }
      }
      for (final l in vis) {
        if (viewSel == null && l.v != null && l.v != prevV) {
          if (buf.length > cols - 2) flush();
          add(VCol('【${l.v}】'.runes.take(n).map(String.fromCharCode).join(), true, l.v!, pi));
          prevSp = '';
        }
        prevV = l.v;
        final needSp = l.sp.isNotEmpty && l.sp != prevSp;
        prevSp = l.sp;
        if (needSp && buf.length > cols - 2) flush();
        if (needSp) {
          final name = l.sp.runes.take(n).map(String.fromCharCode).join();
          add(VCol(name, true, l.sp, pi));
        }
        final isOc = choose && l.ocId != null;
        final body = isOc ? '▶${bodyOf(l).replaceFirst('　▶ ', '')}' : bodyOf(l);
        final mk = termMarks(body, l.tm);
        final cr = body.runes.map(String.fromCharCode).toList();
        for (final r in chunkRanges(body, n)) {
          add(VCol(cr.sublist(r[0], r[1]).join(), false, l.sp, pi,
              ocId: isOc ? l.ocId : null, ocIdx: l.ocIdx, marks: mk?.sublist(r[0], r[1])));
        }
      }
    }
    flush();
  }

  int screenEnd(int i) {
    var m = sStart[i];
    if (screens[i].isNotEmpty) m = math.max(m, screens[i].last.page);
    final s2 = screens2[i];
    if (s2 != null && s2.isNotEmpty) m = math.max(m, s2.last.page);
    return m;
  }

  int screenOf(int gp) {
    var i = 0;
    for (var k = 0; k < sStart.length; k++) {
      if (sStart[k] <= gp) {
        i = k;
      } else {
        break;
      }
    }
    while (i > 0 && sStart[i - 1] == sStart[i]) {
      i--;
    }
    return i;
  }

  void jumpToPage(int gp) {
    if (vertical) {
      if (screens.isNotEmpty) vpc.jumpToPage(screenOf(gp));
    } else {
      if (scrollMode) {
        flowJump(gp);
      } else if (hv.isNotEmpty) {
        pc.jumpToPage(hposFwd(gp));
      }
    }
  }

  void flowJump(int gp) {
    if (hitems.isEmpty) return;
    setState(() {
      sCenter = hposFwd(gp);
      topIdx = sCenter;
      cur = hv[sCenter];
      widget.prefs.setInt('pos_${widget.id}', cur);
      _ik.clear();
      final o = sc;
      sc = ScrollController();
      WidgetsBinding.instance.addPostFrameCallback((_) => o.dispose());
    });
  }

  // 連続スクロール: いちばん上に見えている項目を探して、現在位置と既読を更新する
  void flowSync() {
    if (!mounted || !scrollMode || hitems.isEmpty) return;
    final box = _flowBox.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final viewTop = box.localToGlobal(Offset.zero).dy;
    int? best;
    for (final e in _ik.entries) {
      final c = e.value.currentContext;
      if (c == null) continue;
      final ro = c.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final bottom = ro.localToGlobal(Offset.zero).dy + ro.size.height;
      if (bottom > viewTop + 6 && (best == null || e.key < best)) best = e.key;
    }
    if (best == null || best == topIdx || best >= hitems.length) return;
    if (best > topIdx) {
      final from = math.max(topIdx, best - 60);
      final ks = <int>{};
      for (var j = from; j < best; j++) {
        for (final part in hitems[j].parts) {
          for (final ln in part) {
            ks.add(ln.k);
          }
        }
      }
      markKeys(ks);
    }
    final b = best;
    setState(() {
      topIdx = b;
      cur = hv[b];
    });
    widget.prefs.setInt('pos_${widget.id}', cur);
    onMove();
  }

  // 場面が切り替わる項目なら、区切り線＋場面見出しを返す（そうでなければ null）
  Widget? sceneBreak(int i) {
    if (i < 0 || i >= hitems.length) return null;
    final pg = hitems[i].page;
    if (pg < 0 || pg >= book.sceneOf.length) return null;
    final si = book.sceneOf[pg];
    if (i > 0) {
      final pp = hitems[i - 1].page;
      if (pp >= 0 && pp < book.sceneOf.length && book.sceneOf[pp] == si) return null;
    }
    final c = fg.withAlpha(110);
    return Padding(
      padding: EdgeInsets.only(top: i == 0 ? 8 : 44, bottom: 22),
      child: Row(children: [
        Expanded(child: Divider(height: 1, thickness: 1, color: c)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('◆ 場面 ${si + 1}',
              style: TextStyle(fontSize: font * 0.7, fontWeight: FontWeight.bold, color: c)),
        ),
        Expanded(child: Divider(height: 1, thickness: 1, color: c)),
      ]),
    );
  }

  Widget flowItem(int i) {
    final it = hitems[i];
    final lines = it.parts[0];
    final v = lines.isEmpty ? null : lines.first.v;
    String? pv;
    if (i > 0) {
      final pl = hitems[i - 1].parts.last;
      pv = pl.isEmpty ? null : pl.last.v;
    }
    return KeyedSubtree(
      key: _ik.putIfAbsent(i, () => GlobalKey()),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sceneBreak(i) != null) sceneBreak(i)!,
            if (viewSel == null && v != null && v != pv)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('【$v視点】',
                    style: TextStyle(
                        fontSize: font * 0.8, fontWeight: FontWeight.bold, color: spColor(v))),
              ),
            for (final l in lines) lineWidget(l),
          ],
        ),
      ),
    );
  }

  Widget flowView() {
    final n = hitems.length;
    return NotificationListener<ScrollNotification>(
      onNotification: (nt) {
        if (nt is ScrollUpdateNotification || nt is ScrollEndNotification) {
          WidgetsBinding.instance.addPostFrameCallback((_) => flowSync());
        }
        return false;
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 36, 0, 24),
        child: SizedBox.expand(
          key: _flowBox,
          child: CustomScrollView(
            controller: sc,
            center: _ctr,
            slivers: [
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (c, k) => flowItem(sCenter - 1 - k),
                  childCount: sCenter,
                ),
              ),
              SliverList(
                key: _ctr,
                delegate: SliverChildBuilderDelegate(
                  (c, k) => flowItem(sCenter + k),
                  childCount: math.max(0, n - sCenter),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget glyph(String ch, double fs, Color color, double cellH, double colW, {String? term}) {
    final t = Text(ch, style: TextStyle(fontSize: fs, height: 1.0, color: color));
    Widget w;
    if (kRot.contains(ch)) {
      w = Center(child: RotatedBox(quarterTurns: 1, child: t));
    } else if (kShift.contains(ch)) {
      w = Align(alignment: const Alignment(0.6, -0.6), child: t);
    } else {
      w = Center(child: t);
    }
    final cell = SizedBox(width: colW, height: cellH, child: w);
    if (term == null) return cell;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showTerm(term),
      child: cell,
    );
  }

  Widget colWidget(VCol c, double colW) {
    final fs = c.speaker ? font * 0.7 : font;
    final on = c.ocId != null && picks[c.ocId!] == c.ocIdx;
    final base = c.speaker
        ? spColor(c.sp)
        : (c.ocId != null ? (on ? Colors.amber : (light ? Colors.indigo : Colors.lightBlueAccent)) : fg);
    final color = on ? base : tone(base, stateOfK(kOfPage(c.page)));
    final cellH = fs * 1.15;
    final w = SizedBox(
      width: colW,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in c.text.runes.map(String.fromCharCode).toList().asMap().entries)
            glyph(
                e.value,
                fs,
                (c.marks != null && c.marks![e.key] != null)
                    ? termColor(stateOfK(kOfPage(c.page)))
                    : color,
                cellH,
                colW,
                term: c.marks?[e.key]),
        ],
      ),
    );
    if (c.ocId == null) return w;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => pick(c.ocId!, c.ocIdx),
      child: w,
    );
  }

  Widget verticalView() {
    return LayoutBuilder(builder: (context, box) {
      final colW = font * 1.7;
      final n = math.max(5, ((box.maxHeight - 88) / (font * 1.15)).floor());
      final cols = math.max(1, ((box.maxWidth - 32) / colW).floor());
      final half = math.max(1, ((box.maxWidth - 32 - 17) / 2 / colW).floor());
      final key = '$n-$cols-$half-${font.toStringAsFixed(1)}-$ruby-$sideBySide';
      if (key != _key) {
        _key = key;
        paginate(n, cols, half);
        final target = screenOf(cur);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && vpc.hasClients) vpc.jumpToPage(target);
        });
      }
      return PageView.builder(
        controller: vpc,
        reverse: true,
        itemCount: screens.length,
        onPageChanged: (i) {
          if (i >= sStart.length) return;
          final oldS = screenOf(cur);
          if (oldS < screens.length) {
            markKeys({
              for (final col in screens[oldS]) kOfPage(col.page),
              for (final col in (screens2[oldS] ?? const <VCol>[])) kOfPage(col.page),
            });
          }
          setState(() => cur = sStart[i]);
          widget.prefs.setInt('pos_${widget.id}', cur);
          onMove();
        },
        itemBuilder: (c, i) {
          Widget panel(List<VCol> cs) => Align(
                alignment: Alignment.topRight,
                child: Row(
                  textDirection: TextDirection.rtl,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final col in cs) colWidget(col, colW)],
                ),
              );
          final s2 = screens2[i];
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 44, 16, 44),
            child: s2 == null
                ? panel(screens[i])
                : Row(
                    textDirection: TextDirection.rtl,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: panel(screens[i])),
                      Container(
                          width: 1,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          color: fg.withAlpha(80)),
                      Expanded(child: panel(s2)),
                    ],
                  ),
          );
        },
      );
    });
  }

  void flowBy(double sign) {
    if (!sc.hasClients) return;
    final h = sc.position.viewportDimension * 0.85;
    sc.animateTo(sc.offset + sign * h,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  void goNext() {
    if (scrollMode) {
      flowBy(1);
      return;
    }
    if (vertical) {
      if (vpc.hasClients) {
        vpc.nextPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      }
      return;
    }
    if (hpos(cur) < hv.length - 1) {
      pc.nextPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
  }

  void goPrev() {
    if (scrollMode) {
      flowBy(-1);
      return;
    }
    if (vertical) {
      if (vpc.hasClients) {
        vpc.previousPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      }
      return;
    }
    if (hpos(cur) > 0) {
      pc.previousPage(duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
  }

  // タップ位置に用語（色付きの語）があれば、その説明を出す。
  // 用語のタップが親のページ送りに負けてしまう場合の保険。
  bool tapTermAt(Offset g) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, g, View.of(context).viewId);
    for (final e in result.path) {
      final t = e.target;
      if (t is! RenderParagraph) continue;
      final local = t.globalToLocal(g);
      // 用語の文字の範囲（少し広めに取る。1文字の語でも押しやすいように）を直接調べる
      var off = 0;
      VoidCallback? fire;
      t.text.visitChildren((InlineSpan sp) {
        if (sp is TextSpan && sp.text != null) {
          final len = sp.text!.length;
          final rc = sp.recognizer;
          if (fire == null && len > 0 && rc is TapGestureRecognizer && rc.onTap != null) {
            final boxes = t.getBoxesForSelection(
                TextSelection(baseOffset: off, extentOffset: off + len));
            for (final b in boxes) {
              if (b.toRect().inflate(10).contains(local)) {
                fire = rc.onTap;
                break;
              }
            }
          }
          off += len;
        }
        return true;
      });
      if (fire != null) {
        fire!();
        return true;
      }
    }
    return false;
  }

  void onTap(TapUpDetails d) {
    if (tapTermAt(d.globalPosition)) return;
    final w = MediaQuery.of(context).size.width;
    final x = d.localPosition.dx;
    if (bars) {
      setState(() => bars = false);
    } else if (x > w * 0.65) {
      vertical ? goPrev() : goNext();
    } else if (x < w * 0.35) {
      vertical ? goNext() : goPrev();
    } else {
      setState(() => bars = true);
    }
  }

  void showScenes() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: ListView.builder(
          itemCount: book.sceneIds.length,
          itemBuilder: (c, i) {
            final first = book.pages[book.sceneStart[i]].first.t;
            final here = book.sceneOf[cur] == i;
            return ListTile(
              dense: true,
              selected: here,
              title: Text('場面 ${i + 1}  (${book.sceneIds[i]})'),
              subtitle: Text(first.replaceAll('　', ''), maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(ctx);
                jumpToPage(book.sceneStart[i]);
              },
            );
          },
        ),
      ),
    );
  }

  void showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const Text('文字の大きさ'),
                Expanded(
                  child: Slider(
                    min: 12,
                    max: 30,
                    divisions: 18,
                    value: font,
                    label: font.round().toString(),
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => font = v);
                      widget.prefs.setDouble('font', v);
                    },
                  ),
                ),
              ]),
              if (book.views.isNotEmpty)
                Row(children: [
                  const Text('視点'),
                  const SizedBox(width: 16),
                  DropdownButton<String>(
                    value: sideBySide
                        ? kSplit
                        : ((viewSel != null && book.views.contains(viewSel)) ? viewSel : ''),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部')),
                      for (final v in book.views.toList()..sort())
                        DropdownMenuItem(value: v, child: Text(v)),
                      if (book.views.length == 2)
                        const DropdownMenuItem(value: kSplit, child: Text('並べる')),
                    ],
                    onChanged: (v) {
                      setSheet(() {});
                      setViewToken((v == null || v.isEmpty) ? null : v);
                    },
                  ),
                ]),
              if (book.choices.isNotEmpty)
                SwitchListTile(
                  title: const Text('選択肢を選んで読む'),
                  subtitle: const Text('オフ: 全部の分岐を順に表示'),
                  value: choose,
                  onChanged: (v) {
                    setSheet(() {});
                    choose = v;
                    widget.prefs.setBool('choose', v);
                    relayout();
                  },
                ),
              if (widget.siblings.length > 1)
                Row(children: [
                  const Text('他ルートで読んだ所'),
                  const SizedBox(width: 16),
                  DropdownButton<int>(
                    value: otherMode,
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('色を変える')),
                      DropdownMenuItem(value: 1, child: Text('飛ばす')),
                      DropdownMenuItem(value: 2, child: Text('そのまま')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setSheet(() {});
                      otherMode = v;
                      widget.prefs.setInt('otherMode', v);
                      relayout();
                    },
                  ),
                ]),
              SwitchListTile(
                title: const Text('既読を薄く表示'),
                value: dimRead,
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => dimRead = v);
                  widget.prefs.setBool('dimRead', v);
                },
              ),
              if (hasGfx)
                SwitchListTile(
                  title: const Text('背景・立ち絵を薄く表示'),
                  value: gfxOn,
                  onChanged: (v) {
                    setSheet(() {});
                    setState(() => gfxOn = v);
                    widget.prefs.setBool('gfxOn', v);
                  },
                ),
              if (hasBgm)
                SwitchListTile(
                  title: const Text('BGMを鳴らす'),
                  value: bgmOn,
                  onChanged: (v) {
                    setSheet(() {});
                    setState(() => bgmOn = v);
                    widget.prefs.setBool('bgmOn', v);
                    updateBgm();
                  },
                ),
              if (hasVoice)
                SwitchListTile(
                  title: const Text('声を自動で再生'),
                  value: autoVoice,
                  onChanged: (v) {
                    setSheet(() {});
                    setState(() => autoVoice = v);
                    widget.prefs.setBool('autoVoice', v);
                    if (v) {
                      onMove();
                    } else {
                      stopVoice();
                    }
                  },
                ),
              SwitchListTile(
                title: const Text('縦書き'),
                value: vertical,
                onChanged: (v) {
                  setSheet(() {});
                  vertical = v;
                  widget.prefs.setBool('vertical', v);
                  relayout();
                },
              ),
              SwitchListTile(
                title: const Text('横書きは連続スクロール'),
                value: hflipV,
                onChanged: (v) {
                  setSheet(() {});
                  hflipV = v;
                  widget.prefs.setBool('hflipV', v);
                  relayout();
                },
              ),
              SwitchListTile(
                title: const Text('ルビを（）で表示'),
                value: ruby,
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => ruby = v);
                  widget.prefs.setBool('ruby', v);
                },
              ),
              SwitchListTile(
                title: const Text('明るい背景'),
                value: light,
                onChanged: (v) {
                  setSheet(() {});
                  setState(() => light = v);
                  widget.prefs.setBool('light', v);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 声（アカイイトなど。行に vo があるとき）
  List<int> currentVoices({int span = 8}) {
    var from = cur;
    var to = cur + span; // 連続スクロールでは、先頭から数ページぶんの声を順に再生
    if (vertical && screens.isNotEmpty && sStart.isNotEmpty) {
      final si = screenOf(cur);
      from = sStart[si];
      to = si + 1 < sStart.length ? sStart[si + 1] : book.pages.length;
    }
    final out = <int>[];
    for (var i = from; i < to && i < book.pages.length; i++) {
      for (final l in book.pages[i]) {
        if (l.vo >= 0 && lineVisible(l)) out.add(l.vo);
      }
    }
    return out;
  }

  // 今の位置で鳴っているはずのBGMを、手前へたどって探す
  int effectiveBgm() {
    for (var i = math.min(cur, book.pages.length - 1); i >= 0; i--) {
      final ls = book.pages[i];
      for (var j = ls.length - 1; j >= 0; j--) {
        final l = ls[j];
        if (l.bgm != null && lineVisible(l)) return l.bgm!;
      }
    }
    return -1;
  }

  Future<void> updateBgm() async {
    if (!hasBgm || !mounted) return;
    final want = bgmOn ? effectiveBgm() : -1;
    if (want == _bgmNow) return;
    _bgmNow = want;
    try {
      if (want < 0) {
        await _bp.stop();
      } else {
        final base = widget.prefs.getString('server_url') ?? kDefaultUrl;
        await _bp.play(UrlSource('$base/api/bgm/$want'));
      }
    } catch (_) {}
  }

  void updateGfx() {
    if (!hasGfx || !mounted) return;
    Map<String, dynamic>? g;
    outer:
    for (var i = math.min(cur, book.pages.length - 1); i >= 0; i--) {
      final ls = book.pages[i];
      for (var j = ls.length - 1; j >= 0; j--) {
        final l = ls[j];
        if (l.g != null && lineVisible(l)) {
          g = l.g;
          break outer;
        }
      }
    }
    if (!identical(g, _g)) setState(() => _g = g);
  }

  // 背景・立ち絵を、文字の後ろに薄く表示する（画面は 640x480 の座標で組み、画面いっぱいに広げる）
  Widget backdrop() {
    final g = _g;
    if (!gfxOn || g == null) return const SizedBox.shrink();
    final base = widget.prefs.getString('server_url') ?? kDefaultUrl;
    Widget img(int n, {BoxFit? fit}) => Image.network('$base/api/cel/$n.png',
        gaplessPlayback: true, errorBuilder: (c, e, st) => const SizedBox.shrink());
    final layers = <List<int>>[];
    for (final e in (g['b'] as List? ?? const [])) {
      final n = (e[0] as num).toInt();
      final z = (e[1] as num).toInt();
      // 重なり順が低い層（5・10 など）は、全面にかぶせる網目などの効果画像なので出さない
      if (n > 2 && z >= 50) layers.add([n, z]);
    }
    layers.sort((a, b) => a[1].compareTo(b[1]));
    final kids = <Widget>[
      for (final l in layers) Positioned(left: 0, top: 0, child: img(l[0])),
      for (final e in (g['s'] as List? ?? const []))
        Positioned(
            left: (e[2] as num).toDouble() - 320,
            bottom: 0,
            width: 640,
            child: Align(alignment: Alignment.bottomCenter, child: img((e[1] as num).toInt()))),
    ];
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.4,
          child: ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(width: 640, height: 480, child: Stack(children: kids)),
            ),
          ),
        ),
      ),
    );
  }

  void onMove() {
    updateGfx();
    updateBgm();
    autoPlayVoice();
  }

  // 自動再生: 表示が進んだら、前の声を止めて今のページの声を鳴らす
  Future<void> autoPlayVoice() async {
    if (!autoVoice || !mounted) return;
    final q = currentVoices(span: 1);
    // 戻った・大きく飛んだときは、鳴っている声を止めて最初から
    if (cur < _lastVoiceCur || cur - _lastVoiceCur > 12) {
      _vq = [];
      _vSeen.clear();
      voicePlaying = false;
      try {
        await _ap.stop();
      } catch (_) {}
    }
    _lastVoiceCur = cur;
    // 前へ進むときは、いま鳴っている声を止めずに、順番待ちに足す
    final fresh = q.where((v) => !_vSeen.contains(v)).toList();
    if (fresh.isEmpty) return;
    _vSeen.addAll(fresh);
    _vq.addAll(fresh);
    while (_vq.length > 4) {
      _vq.removeAt(0);
    }
    if (!voicePlaying) {
      voicePlaying = true;
      if (mounted) setState(() {});
      await _playNextVoice();
    }
  }

  Future<void> stopVoice() async {
    _vq = [];
    _vSeen.clear();
    voicePlaying = false;
    try {
      await _ap.stop();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> playVoices() async {
    if (voicePlaying) {
      await stopVoice();
      return;
    }
    final q = currentVoices();
    if (q.isEmpty) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(seconds: 2), content: Text('この画面に声はありません')));
      return;
    }
    _vq = q;
    voicePlaying = true;
    setState(() {});
    await _playNextVoice();
  }

  Future<void> _playNextVoice() async {
    if (!mounted) return;
    if (_vq.isEmpty) {
      if (voicePlaying) setState(() => voicePlaying = false);
      return;
    }
    final n = _vq.removeAt(0);
    final base = widget.prefs.getString('server_url') ?? kDefaultUrl;
    try {
      await _ap.play(UrlSource('$base/api/voice/$n'));
    } catch (_) {
      // 1つ失敗しても、次の声へ進む
      await _playNextVoice();
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = hv.length;
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Stack(
          children: [
            backdrop(),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: onTap,
              child: vertical ? verticalView() : scrollMode ? flowView() : PageView.builder(
                controller: pc,
                itemCount: hv.length,
                onPageChanged: (i) {
                  if (i >= hv.length) return;
                  if (hpos(cur) < hitems.length) {
                    markKeys({
                      for (final part in hitems[hpos(cur)].parts)
                        for (final ln in part) ln.k
                    });
                  }
                  setState(() => cur = hv[i]);
                  widget.prefs.setInt('pos_${widget.id}', cur);
                  onMove();
                },
                itemBuilder: (c, i) => pageWidget(i),
              ),
            ),
            if (bars)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: const Color(0xEE222222),
                  child: Row(children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        vertical
                            ? '場面 ${book.sceneOf[cur] + 1}/${book.sceneIds.length}   ${screens.isEmpty ? 0 : screenOf(cur) + 1}/${screens.length} 画面'
                            : '場面 ${book.sceneOf[cur] + 1}/${book.sceneIds.length}   $total ページ中 ${hpos(cur) + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                    if (hasVoice)
                      IconButton(
                          tooltip: '声を再生',
                          icon: Icon(voicePlaying ? Icons.stop_circle_outlined : Icons.volume_up,
                              color: Colors.white),
                          onPressed: playVoices),
                    if (book.views.isNotEmpty)
                      TextButton.icon(
                        onPressed: cycleView,
                        icon: const Icon(Icons.visibility, color: Colors.white, size: 18),
                        label: Text(viewLabel(viewToken),
                            style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ),
                    if (book.choicePages.isNotEmpty)
                      IconButton(
                          tooltip: '前の選択肢へ',
                          icon: const Icon(Icons.call_split, color: Colors.white),
                          onPressed: backToChoice),
                    if (book.terms.isNotEmpty)
                      IconButton(
                          tooltip: '用語辞典',
                          icon: const Icon(Icons.menu_book, color: Colors.white),
                          onPressed: showDictionary),
                    IconButton(
                        icon: const Icon(Icons.list, color: Colors.white), onPressed: showScenes),
                    IconButton(
                        icon: const Icon(Icons.text_fields, color: Colors.white),
                        onPressed: showSettings),
                  ]),
                ),
              ),
            if (bars)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: const Color(0xEE222222),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Slider(
                    min: 0,
                    max: vertical
                        ? math.max(1.0, (screens.length - 1).toDouble())
                        : math.max(1.0, (total - 1).toDouble()),
                    value: vertical
                        ? (screens.isEmpty ? 0.0 : screenOf(cur).toDouble())
                        : hpos(cur).toDouble(),
                    onChanged: (v) => setState(() {
                      if (vertical) {
                        if (screens.isNotEmpty) cur = sStart[math.min(math.max(v.round(), 0), screens.length - 1)];
                      } else if (hv.isNotEmpty) {
                        cur = hv[math.min(math.max(v.round(), 0), hv.length - 1)];
                      }
                    }),
                    onChangeEnd: (v) => jumpToPage(cur),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
// build: 横書き連続スクロール 2026-11-14
