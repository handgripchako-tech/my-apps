import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const repo = 'handgripchako-tech/my-apps';
const channel = MethodChannel('chako/store');

// ---- PC-98 風の配色（music-app と同じ） ----
const String kMono = 'DotGothic16';
const Color kBg = Color(0xFF000000);
const Color kLine = Color(0xFFC8C8C8);
const Color kYellow = Color(0xFFFFE600);
const Color kCyan = Color(0xFF00E5E5);
const Color kGreen = Color(0xFF39FF39);
const Color kRed = Color(0xFFFF4040);
const Color kBtn = Color(0xFFB4B4B4);
const Color kTxt = Color(0xFFF2F2F2);
const Color kMut = Color(0xFF9A9A9A);

void main() => runApp(const StoreApp());

class StoreApp extends StatelessWidget {
  const StoreApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ストア',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: false,
        fontFamily: kMono,
        scaffoldBackgroundColor: kBg,
        canvasColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kCyan, secondary: kYellow, surface: kBg),
        splashFactory: NoSplash.splashFactory,
        dialogTheme: const DialogThemeData(
          backgroundColor: kBg,
          shape: RoundedRectangleBorder(side: BorderSide(color: kLine, width: 2)),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF262626),
          contentTextStyle: TextStyle(fontFamily: kMono, color: kTxt),
          shape: RoundedRectangleBorder(),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: kBg,
          shape: RoundedRectangleBorder(side: BorderSide(color: kLine, width: 2)),
        ),
      ),
      home: const StorePage(),
    );
  }
}

/// PC-98 風の立体ボタン（白い上左・暗い下右の縁）
class PcBtn extends StatelessWidget {
  const PcBtn(this.label, {super.key, this.onTap, this.bg = kBtn, this.fg = Colors.black, this.width});
  final String label;
  final VoidCallback? onTap;
  final Color bg;
  final Color fg;
  final double? width;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: onTap == null ? const Color(0xFF555555) : bg,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.white70, width: 2),
              left: BorderSide(color: Colors.white70, width: 2),
              bottom: BorderSide(color: Color(0xFF555555), width: 2),
              right: BorderSide(color: Color(0xFF555555), width: 2),
            ),
          ),
          child: Text(label,
              maxLines: 1,
              style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.bold, fontFamily: kMono)),
        ),
      ),
    );
  }
}

/// ブロックで進み具合を見せるバー
class BlockBar extends StatelessWidget {
  const BlockBar(this.value, {super.key, this.color = kGreen});
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) {
    const n = 12;
    final on = (value.clamp(0.0, 1.0) * n).round();
    return Row(
      children: List.generate(
        n,
        (i) => Expanded(
          child: Container(
            height: 10,
            margin: const EdgeInsets.only(right: 2),
            color: i < on ? color : const Color(0xFF2A2A2A),
          ),
        ),
      ),
    );
  }
}

class AppDef {
  final String tag;
  final String name;
  final String package;
  final String desc;
  AppDef(this.tag, this.name, this.package, this.desc);
  factory AppDef.fromJson(Map<String, dynamic> j) => AppDef(
        '${j['tag']}',
        '${j['name'] ?? j['tag']}',
        '${j['package'] ?? ''}',
        '${j['desc'] ?? ''}',
      );
}

class Entry {
  final AppDef def;
  final int assetId;
  final String assetName;
  final int size;
  final DateTime time;
  Map? installed; // versionName / versionCode / updated(ms)
  String? recordedAsset; // ストアが入れた時の assetId
  String notes = ''; // リリースの更新内容
  Entry(this.def, this.assetId, this.assetName, this.size, this.time);

  bool get isInstalled => installed != null;

  String? get build {
    final m = RegExp(r'-v(\d+)\.apk$').firstMatch(assetName);
    return m?.group(1);
  }

  bool get hasUpdate {
    if (!isInstalled) return false;
    if (recordedAsset != null) return recordedAsset != '$assetId';
    final up = installed!['updated'];
    if (up is int) {
      return time.isAfter(DateTime.fromMillisecondsSinceEpoch(up)
          .add(const Duration(minutes: 2)));
    }
    return false;
  }
}

class StorePage extends StatefulWidget {
  const StorePage({super.key});
  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> with WidgetsBindingObserver {
  String token = '';
  bool loading = false;
  String? error;
  List<Entry> entries = [];
  final Map<String, double> progress = {}; // tag -> 0..1
  SharedPreferences? prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && progress.isEmpty) load();
  }

  Future<void> _init() async {
    prefs = await SharedPreferences.getInstance();
    token = prefs!.getString('gh_token') ?? '';
    _cleanApks();
    await load();
  }

  void _cleanApks() {
    try {
      for (final f in Directory.systemTemp.listSync()) {
        if (f is File && f.path.endsWith('.apk')) f.deleteSync();
      }
    } catch (_) {}
  }

  // 公開リポジトリなのでトークンは任意（入れると取得回数の上限が増えるだけ）
  Map<String, String> get _headers => {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'chako-store',
      };

  // 古いトークン（非公開リポジトリ用）が残っていて 401 になったら、
  // トークンを消してトークン無しで読み直す（公開リポジトリなので読める）
  Future<http.Response> _api(Uri u, [Map<String, String> extra = const {}]) async {
    var r = await http.get(u, headers: {..._headers, ...extra});
    if (r.statusCode == 401 && token.isNotEmpty) {
      token = '';
      await prefs?.remove('gh_token');
      r = await http.get(u, headers: {..._headers, ...extra});
    }
    return r;
  }

  Future<List<AppDef>> _fetchDefs() async {
    try {
      final r = await _api(
        Uri.parse('https://api.github.com/repos/$repo/contents/store-app/apps.json'),
        {'Accept': 'application/vnd.github.raw+json'},
      );
      if (r.statusCode == 200) {
        final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
        await prefs?.setString('apps_json', utf8.decode(r.bodyBytes));
        return list.map((e) => AppDef.fromJson(Map<String, dynamic>.from(e))).toList();
      }
    } catch (_) {}
    final cached = prefs?.getString('apps_json');
    if (cached != null) {
      final list = jsonDecode(cached) as List;
      return list.map((e) => AppDef.fromJson(Map<String, dynamic>.from(e))).toList();
    }
    return [];
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final defs = await _fetchDefs();
      final r = await _api(
        Uri.parse('https://api.github.com/repos/$repo/releases?per_page=100'),
      );
      if (r.statusCode == 401 || r.statusCode == 403 || r.statusCode == 404) {
        throw token.isEmpty
            ? '取得回数の上限です。しばらく待つか TOKEN を入れてください (${r.statusCode})'
            : 'トークンが違うか、権限がありません (${r.statusCode})';
      }
      if (r.statusCode != 200) throw 'GitHub エラー (${r.statusCode})';
      final releases = jsonDecode(utf8.decode(r.bodyBytes)) as List;
      final list = <Entry>[];
      for (final rel in releases) {
        final tag = '${rel['tag_name']}';
        if (!tag.endsWith('-latest') || rel['draft'] == true) continue;
        final assets = (rel['assets'] as List).where((a) => '${a['name']}'.endsWith('.apk')).toList();
        if (assets.isEmpty) continue;
        final a = assets.first;
        final def = defs.firstWhere(
          (d) => d.tag == tag,
          orElse: () => AppDef(tag, tag.replaceAll('-latest', ''), '', ''),
        );
        final t = DateTime.tryParse('${a['updated_at'] ?? a['created_at']}') ?? DateTime.now();
        final en = Entry(def, a['id'] as int, '${a['name']}', (a['size'] ?? 0) as int, t);
        en.notes = ('${rel['body'] ?? ''}').trim();
        list.add(en);
      }
      for (final e in list) {
        e.installed = null;
        if (e.def.package.isNotEmpty) {
          try {
            e.installed = await channel.invokeMethod('info', {'package': e.def.package});
          } catch (_) {}
        }
        _settlePending(e);
        e.recordedAsset = prefs?.getString('rec_${e.def.tag}');
      }
      // 並び: 更新あり → インストール済み → 未インストール、同順位は定義順
      int order(Entry e) => e.hasUpdate ? 0 : (e.isInstalled ? 1 : 2);
      int idx(Entry e) {
        final i = defs.indexWhere((d) => d.tag == e.def.tag);
        return i < 0 ? 999 : i;
      }

      list.sort((a, b) {
        final c = order(a).compareTo(order(b));
        return c != 0 ? c : idx(a).compareTo(idx(b));
      });
      setState(() => entries = list);
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // インストール要求のあと、実際に入れ替わったら「入れた版」として記録する
  void _settlePending(Entry e) {
    final p = prefs?.getString('pending_${e.def.tag}');
    if (p == null) return;
    final parts = p.split('|');
    if (parts.length != 2) {
      prefs?.remove('pending_${e.def.tag}');
      return;
    }
    final ts = int.tryParse(parts[1]) ?? 0;
    final up = e.installed?['updated'];
    if (up is int && up >= ts) {
      prefs?.setString('rec_${e.def.tag}', parts[0]);
      prefs?.remove('pending_${e.def.tag}');
    } else if (DateTime.now().millisecondsSinceEpoch - ts > 3600 * 1000) {
      prefs?.remove('pending_${e.def.tag}');
    }
  }

  Future<File> _download(Entry e) async {
    final client = HttpClient();
    try {
      var req = await client.getUrl(
          Uri.parse('https://api.github.com/repos/$repo/releases/assets/${e.assetId}'));
      req.followRedirects = false;
      if (token.isNotEmpty) req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/octet-stream');
      req.headers.set('User-Agent', 'chako-store');
      var res = await req.close();
      if (res.statusCode == 401 && token.isNotEmpty) {
        await res.drain();
        token = '';
        await prefs?.remove('gh_token');
        req = await client.getUrl(
            Uri.parse('https://api.github.com/repos/$repo/releases/assets/${e.assetId}'));
        req.followRedirects = false;
        req.headers.set('Accept', 'application/octet-stream');
        req.headers.set('User-Agent', 'chako-store');
        res = await req.close();
      }
      if (res.statusCode >= 300 && res.statusCode < 400) {
        final loc = res.headers.value('location');
        await res.drain();
        if (loc == null) throw 'ダウンロード先が不明です';
        // 認証ヘッダは外部ストレージへ渡さない
        req = await client.getUrl(Uri.parse(loc));
        req.headers.set('User-Agent', 'chako-store');
        res = await req.close();
      }
      if (res.statusCode != 200) {
        await res.drain();
        throw 'ダウンロード失敗 (${res.statusCode})';
      }
      final total = e.size > 0 ? e.size : res.contentLength;
      final file = File('${Directory.systemTemp.path}/${e.assetName}');
      final sink = file.openWrite();
      var got = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && mounted) setState(() => progress[e.def.tag] = got / total);
      }
      await sink.close();
      if (e.size > 0 && file.lengthSync() != e.size) {
        throw 'ファイルが途中で切れました。もう一度試してください';
      }
      return file;
    } finally {
      client.close();
    }
  }

  Future<void> install(Entry e) async {
    if (progress.containsKey(e.def.tag)) return;
    setState(() => progress[e.def.tag] = 0);
    try {
      final f = await _download(e);
      await prefs?.setString(
          'pending_${e.def.tag}', '${e.assetId}|${DateTime.now().millisecondsSinceEpoch}');
      final r = await channel.invokeMethod('install', {'path': f.path});
      if (r == 'need_permission' && mounted) {
        _toast('「この提供元のアプリを許可」をオンにして、もう一度押してください');
      }
    } catch (err) {
      _toast('$err');
    } finally {
      if (mounted) setState(() => progress.remove(e.def.tag));
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> openApp(Entry e) async {
    try {
      final ok = await channel.invokeMethod('launch', {'package': e.def.package});
      if (ok != true) _toast('起動できませんでした');
    } catch (_) {
      _toast('起動できませんでした');
    }
  }

  TextStyle get _t => const TextStyle(fontFamily: kMono, color: kTxt, fontSize: 14);

  Future<void> editToken() async {
    final c = TextEditingController(text: token);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('GITHUB トークン', style: TextStyle(color: kYellow, fontFamily: kMono, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            '公開リポジトリなので、トークンは無くても使えます（任意）。\n'
            '入れると GitHub の取得回数の上限が増えます。空欄で保存すると外せます。',
            style: TextStyle(fontSize: 12, color: kMut, fontFamily: kMono),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: c,
            obscureText: true,
            style: _t,
            decoration: const InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: kLine)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: kLine)),
              hintText: 'github_pat_...',
              hintStyle: TextStyle(color: kMut),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル', style: TextStyle(color: kMut, fontFamily: kMono))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('保存', style: TextStyle(color: kCyan, fontFamily: kMono, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (v == null) return;
    token = v;
    await prefs?.setString('gh_token', v);
    await load();
  }

  void showNotes(Entry e) {
    final body = e.notes.isEmpty ? '（更新内容の記録なし）' : e.notes;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBg,
        shape: const RoundedRectangleBorder(side: BorderSide(color: kLine, width: 2)),
        title: Text('${e.def.name} 更新内容',
            style: const TextStyle(color: kCyan, fontFamily: kMono, fontWeight: FontWeight.bold, fontSize: 16)),
        content: SingleChildScrollView(
          child: Text(body, style: const TextStyle(color: kTxt, fontFamily: kMono, fontSize: 13)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる', style: TextStyle(color: kYellow, fontFamily: kMono)),
          ),
        ],
      ),
    );
  }

  // カードに出す短い更新内容（ビルド行を除いた先頭2行）
  String _notesPreview(Entry e) {
    final lines = e.notes.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty && !x.startsWith('ビルド #')).toList();
    return lines.take(2).join('\n');
  }

  void openMenu(Entry e) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(e.def.name, style: const TextStyle(color: kCyan, fontFamily: kMono, fontWeight: FontWeight.bold)),
            subtitle: Text(e.assetName, style: const TextStyle(color: kMut, fontFamily: kMono, fontSize: 12)),
          ),
          if (e.isInstalled)
            ListTile(
              title: const Text('▶ アンインストール', style: TextStyle(color: kRed, fontFamily: kMono)),
              onTap: () {
                Navigator.pop(ctx);
                channel.invokeMethod('uninstall', {'package': e.def.package});
              },
            ),
          ListTile(
            title: const Text('▶ この版を入れ直す', style: TextStyle(color: kTxt, fontFamily: kMono)),
            onTap: () {
              Navigator.pop(ctx);
              install(e);
            },
          ),
        ]),
      ),
    );
  }

  Color _color(String s) {
    final h = s.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xFFFFFF);
    return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.6, 0.38).toColor();
  }

  String _size(int b) => b <= 0 ? '' : '${(b / 1048576).toStringAsFixed(1)}MB';

  String _date(DateTime t) {
    final l = t.toLocal();
    return '${l.month}/${l.day} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  Widget card(Entry e) {
    final p = progress[e.def.tag];
    final canTrack = e.def.package.isNotEmpty;
    final sub = [
      if (e.build != null) 'v${e.build}',
      _size(e.size),
      _date(e.time),
    ].where((x) => x.isNotEmpty).join(' ');
    Widget action;
    if (p != null) {
      action = SizedBox(
          width: 96,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BlockBar(p),
            const SizedBox(height: 4),
            Text('${(p * 100).round()}%', style: const TextStyle(fontSize: 12, color: kGreen, fontFamily: kMono)),
          ]));
    } else if (e.hasUpdate) {
      action = PcBtn('更新', onTap: () => install(e), bg: const Color(0xFFB00000), fg: Colors.white, width: 96);
    } else if (e.isInstalled) {
      action = PcBtn('開く', onTap: () => openApp(e), width: 96);
    } else {
      action = PcBtn(canTrack ? 'インストール' : 'ダウンロード',
          onTap: () => install(e), bg: const Color(0xFF00A8A8), fg: Colors.white, width: 96);
    }
    final String status;
    final Color statusColor;
    if (e.hasUpdate) {
      status = '▲ 更新あり ${e.isInstalled ? 'v${e.installed!['versionName']} → ' : ''}$sub';
      statusColor = kRed;
    } else if (e.isInstalled) {
      status = '■ 導入済 $sub';
      statusColor = kGreen;
    } else {
      status = '□ $sub';
      statusColor = kMut;
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      decoration: BoxDecoration(border: Border.all(color: kLine, width: 1.5)),
      child: InkWell(
        onTap: () => showNotes(e),
        onLongPress: () => openMenu(e),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _color(e.def.tag),
                border: const Border(
                  top: BorderSide(color: Colors.white70, width: 2),
                  left: BorderSide(color: Colors.white70, width: 2),
                  bottom: BorderSide(color: Color(0xFF333333), width: 2),
                  right: BorderSide(color: Color(0xFF333333), width: 2),
                ),
              ),
              child: Text(e.def.name.characters.first,
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, fontFamily: kMono)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.def.name,
                    style: const TextStyle(fontSize: 16, color: kCyan, fontWeight: FontWeight.bold, fontFamily: kMono)),
                if (e.def.desc.isNotEmpty)
                  Text(e.def.desc,
                      style: const TextStyle(fontSize: 12, color: kTxt, fontFamily: kMono),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                Text(status, style: TextStyle(fontSize: 11, color: statusColor, fontFamily: kMono)),
                if (e.hasUpdate && _notesPreview(e).isNotEmpty)
                  Text(_notesPreview(e),
                      style: const TextStyle(fontSize: 11, color: kYellow, fontFamily: kMono),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 8),
            action,
          ]),
        ),
      ),
    );
  }

  Widget header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
        child: Row(children: [
          Text('■ $t', style: const TextStyle(fontSize: 14, color: kYellow, fontWeight: FontWeight.bold, fontFamily: kMono)),
          const SizedBox(width: 8),
          const Expanded(child: Divider(color: kLine, height: 1)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final upd = entries.where((e) => e.hasUpdate).toList();
    final inst = entries.where((e) => e.isInstalled && !e.hasUpdate).toList();
    final rest = entries.where((e) => !e.isInstalled).toList();
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: const Text('◆ ストア ◆',
            style: TextStyle(color: kYellow, fontFamily: kMono, fontWeight: FontWeight.bold, fontSize: 18)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(2),
          child: Divider(color: kLine, height: 2, thickness: 2),
        ),
        actions: [
          Center(child: PcBtn('再読込', onTap: loading ? null : load)),
          const SizedBox(width: 6),
          Center(child: PcBtn('TOKEN', onTap: editToken)),
          const SizedBox(width: 10),
        ],
      ),
      body: RefreshIndicator(
              color: kBg,
              backgroundColor: kCyan,
              onRefresh: load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                children: [
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 8, 10, 0),
                      child: Text('読み込み中...', style: TextStyle(color: kGreen, fontFamily: kMono, fontSize: 12)),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(error!, style: const TextStyle(color: kRed, fontFamily: kMono)),
                    ),
                  if (upd.isNotEmpty) header('更新あり (${upd.length})'),
                  ...upd.map(card),
                  if (inst.isNotEmpty) header('インストール済み'),
                  ...inst.map(card),
                  if (rest.isNotEmpty) header('未インストール'),
                  ...rest.map(card),
                  if (!loading && error == null && entries.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('アプリが見つかりません', style: TextStyle(color: kMut, fontFamily: kMono))),
                ],
              ),
            ),
    );
  }
}
