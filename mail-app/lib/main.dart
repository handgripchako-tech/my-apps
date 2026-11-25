import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ---------- PC-98 風の色 ----------
const kBg = Color(0xFF000000);
const kWhite = Color(0xFFFFFFFF);
const kCyan = Color(0xFF00FFFF);
const kYellow = Color(0xFFFFFF00);
const kGreen = Color(0xFF00FF00);
const kRed = Color(0xFFFF4040);
const kBlue = Color(0xFF2828FF);
const kGray = Color(0xFF909090);

const kDefaultUrl = 'http://100.102.7.80:8090';

// ---------- 設定 ----------
class Cfg {
  static String url = kDefaultUrl;
  static String token = '';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    url = p.getString('url') ?? kDefaultUrl;
    token = p.getString('token') ?? '';
  }

  static Future<void> save(String u, String t) async {
    var x = u.trim();
    if (x.isNotEmpty && !x.startsWith('http')) x = 'http://$x';
    while (x.endsWith('/')) {
      x = x.substring(0, x.length - 1);
    }
    url = x;
    token = t.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString('url', url);
    await p.setString('token', token);
  }
}

// ---------- API ----------
Map<String, String> _hdr() => {'X-Token': Cfg.token};

Uri _u(String path, [Map<String, String>? q]) {
  final u = Uri.parse('${Cfg.url}$path');
  return q == null ? u : u.replace(queryParameters: q);
}

Map<String, dynamic> _decode(http.Response r) {
  Map<String, dynamic> j;
  try {
    j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  } catch (_) {
    throw Exception('HTTP ${r.statusCode}');
  }
  if (r.statusCode >= 400) {
    throw Exception(j['error'] ?? 'HTTP ${r.statusCode}');
  }
  return j;
}

Future<Map<String, dynamic>> apiGet(String path, [Map<String, String>? q]) async {
  final r = await http
      .get(_u(path, q), headers: _hdr())
      .timeout(const Duration(seconds: 40));
  return _decode(r);
}

Future<Map<String, dynamic>> apiPost(String path, Map<String, dynamic> body) async {
  final r = await http
      .post(_u(path),
          headers: {..._hdr(), 'Content-Type': 'application/json'},
          body: jsonEncode(body))
      .timeout(const Duration(seconds: 120));
  return _decode(r);
}

Future<Map<String, dynamic>> apiDelete(String path, Map<String, dynamic> body) async {
  final r = await http
      .delete(_u(path),
          headers: {..._hdr(), 'Content-Type': 'application/json'},
          body: jsonEncode(body))
      .timeout(const Duration(seconds: 40));
  return _decode(r);
}

String errText(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  if (s.contains('SocketException') || s.contains('TimeoutException')) {
    return 'サーバーにつながりません（Tailscaleは入っていますか？）';
  }
  if (s == 'unauthorized') return '合言葉(トークン)が違います';
  return s;
}

// ---------- 小さな道具 ----------
String _p2(int n) => n.toString().padLeft(2, '0');

DateTime? parseMailDate(String s) {
  final m = RegExp(
          r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4})?')
      .firstMatch(s);
  if (m == null) return null;
  const mons = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
  ];
  final mo = mons.indexOf(m.group(2)!.toLowerCase()) + 1;
  if (mo == 0) return null;
  var dt = DateTime.utc(
    int.parse(m.group(3)!),
    mo,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6) ?? '0'),
  );
  final z = m.group(7);
  if (z != null) {
    final sign = z[0] == '-' ? -1 : 1;
    final hh = int.parse(z.substring(1, 3));
    final mm = int.parse(z.substring(3, 5));
    dt = dt.subtract(Duration(minutes: sign * (hh * 60 + mm)));
  }
  return dt.toLocal();
}

String fmtDate(String s) {
  final d = parseMailDate(s);
  if (d == null) return '--/-- --:--';
  return '${_p2(d.month)}/${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';
}

String fmtDateLong(String s) {
  final d = parseMailDate(s);
  if (d == null) return s;
  return '${d.year}/${_p2(d.month)}/${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';
}

String fmtSize(int n) {
  if (n >= 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)}KB';
  return '${n}B';
}

// ---------- HTML → PC-98 風テキスト ----------
class MailBody {
  final String text;
  final List<String> links;
  const MailBody(this.text, this.links);
}

const _kEntities = {
  'nbsp': ' ', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'amp': '&',
  'yen': '¥', 'copy': '©', 'reg': '®', 'trade': '™', 'hellip': '…',
  'ndash': '–', 'mdash': '—', 'laquo': '«', 'raquo': '»', 'middot': '・',
  'bull': '・', 'times': '×', 'rsquo': '’', 'lsquo': '‘', 'rdquo': '”',
  'ldquo': '“',
};

String decodeEntities(String s) {
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);'), (m) {
    final g = m.group(1)!;
    int? n;
    if (g.startsWith('#x') || g.startsWith('#X')) {
      n = int.tryParse(g.substring(2), radix: 16);
    } else if (g.startsWith('#')) {
      n = int.tryParse(g.substring(1));
    } else {
      return _kEntities[g.toLowerCase()] ?? m.group(0)!;
    }
    if (n == null || n <= 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) {
      return m.group(0)!;
    }
    return String.fromCharCode(n);
  });
}

final _urlRe = RegExp(r'https?://[^\s<>"　]+');

List<String> urlsIn(String t) {
  final out = <String>[];
  for (final m in _urlRe.allMatches(t)) {
    var u = m.group(0)!;
    u = u.replaceAll(RegExp(r'[.,;:!?)\]」』）、。]+$'), '');
    if (u.length > 8 && !out.contains(u)) out.add(u);
    if (out.length >= 20) break;
  }
  return out;
}

/// HTML をテキストに直す。リンクは「文字[1]」のように番号を付け、末尾の一覧に回す
MailBody htmlToText(String h) {
  var s = h;
  s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  s = s.replaceAll(
      RegExp(r'<(head|style|script|title)[^>]*>.*?</\1\s*>',
          caseSensitive: false, dotAll: true),
      '');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  // 画像は alt があるときだけ [alt] で残す
  s = s.replaceAllMapped(RegExp(r'<img\b[^>]*>', caseSensitive: false), (m) {
    final t = m.group(0)!;
    final a = RegExp(r'''alt\s*=\s*(?:"([^"]*)"|'([^']*)')''', caseSensitive: false)
        .firstMatch(t);
    final alt = decodeEntities((a?.group(1) ?? a?.group(2) ?? '')).trim();
    return alt.isEmpty ? '' : '[$alt]';
  });
  // リンク
  final links = <String>[];
  s = s.replaceAllMapped(
      RegExp(
          r'''<a\s[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))[^>]*>(.*?)</a\s*>''',
          caseSensitive: false,
          dotAll: true), (m) {
    final href = decodeEntities(m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
    final inner = decodeEntities(m.group(4)!.replaceAll(RegExp(r'<[^>]+>'), '')).trim();
    if (!href.toLowerCase().startsWith('http')) return inner;
    var idx = links.indexOf(href);
    if (idx < 0) {
      if (links.length >= 40) return inner;
      links.add(href);
      idx = links.length - 1;
    }
    if (inner.isEmpty || inner.toLowerCase().startsWith('http')) return '[${idx + 1}]';
    return '$inner[${idx + 1}]';
  });
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<hr[^>]*>', caseSensitive: false), '\n────────────────\n');
  s = s.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n・');
  s = s.replaceAll(
      RegExp(r'</?(p|div|tr|table|ul|ol|h[1-6]|blockquote|section|article|header|footer|center)\b[^>]*>',
          caseSensitive: false),
      '\n');
  s = s.replaceAll(RegExp(r'</t[dh]\s*>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = decodeEntities(s);
  s = s.replaceAll(RegExp('[​-‏⁠﻿͏]'), '');
  final lines = s
      .split('\n')
      .map((l) => l.replaceAll(RegExp('[  　]{2,}'), ' ').trim());
  var text = lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return MailBody(text, links);
}

MailBody bodyParts(Map<String, dynamic> m) {
  final t = (m['text'] as String?) ?? '';
  final h = (m['html'] as String?) ?? '';
  final tt = t.trim();
  if (tt.length >= 30 || (tt.isNotEmpty && h.trim().isEmpty)) {
    return MailBody(t, urlsIn(t));
  }
  if (h.trim().isNotEmpty) {
    final r = htmlToText(h);
    if (r.text.isNotEmpty) return r;
  }
  return MailBody(t, urlsIn(t));
}

String bodyOf(Map<String, dynamic> m) => bodyParts(m).text;

String shortUrl(String u) => u.length > 70 ? '${u.substring(0, 70)}…' : u;

void toast(BuildContext c, String msg) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(
    backgroundColor: kBg,
    shape: const RoundedRectangleBorder(
        side: BorderSide(color: kYellow, width: 2), borderRadius: BorderRadius.zero),
    content: Text(msg, style: const TextStyle(color: kYellow)),
    duration: const Duration(seconds: 3),
  ));
}

// ---------- PC-98 風の部品 ----------
class PcChoice<T> {
  final String label;
  final T value;
  final Color color;
  PcChoice(this.label, this.value, [this.color = kWhite]);
}

/// 二重線の枠（PC-98の罫線風）
class PcFrame extends StatelessWidget {
  final Widget child;
  const PcFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: kWhite, width: 2)),
      padding: const EdgeInsets.all(2),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: kWhite, width: 2)),
        child: child,
      ),
    );
  }
}

/// 押している間だけ白黒反転する（反転表示）
class PcPress extends StatefulWidget {
  final Widget Function(bool down) builder;
  final VoidCallback? onTap;
  const PcPress({super.key, required this.builder, this.onTap});
  @override
  State<PcPress> createState() => _PcPressState();
}

class _PcPressState extends State<PcPress> {
  bool down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => down = true),
      onTapUp: (_) {
        if (mounted) setState(() => down = false);
      },
      onTapCancel: () {
        if (mounted) setState(() => down = false);
      },
      onTap: widget.onTap,
      child: widget.builder(down),
    );
  }
}

Future<T?> pcAsk<T>(BuildContext c, String title, String msg, List<PcChoice<T>> choices) {
  return showDialog<T>(
    context: c,
    builder: (ctx) => Dialog(
      backgroundColor: kBg,
      insetPadding: const EdgeInsets.all(16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: PcFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: kWhite,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(title, style: const TextStyle(color: kBg, fontSize: 15)),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Text(msg, style: const TextStyle(color: kWhite, fontSize: 14)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: choices
                    .map((x) => SizedBox(
                          width: 124,
                          child: PcButton(x.label,
                              color: x.color, onTap: () => Navigator.pop(ctx, x.value)),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

InputDecoration pcDeco(String label) => InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: kCyan),
      isDense: true,
      enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: kWhite, width: 1.5)),
      focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: kYellow, width: 2)),
    );

/// ボタン。fn を渡すと「F1」のようなキー表示が付く（下のファンクションキー行用）
class PcButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color color;
  final int? fn;
  const PcButton(this.label, {super.key, this.onTap, this.color = kWhite, this.fn});

  PcButton withFn(int n) => PcButton(label, key: key, onTap: onTap, color: color, fn: n);

  @override
  Widget build(BuildContext context) {
    final c = onTap == null ? kGray : color;
    return PcPress(
      onTap: onTap,
      builder: (down) => Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: down ? c : kBg, border: Border.all(color: c, width: 2)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (fn != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                color: down ? kBg : c,
                child: Text('F$fn',
                    style: TextStyle(color: down ? c : kBg, fontSize: 10)),
              ),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(color: down ? kBg : c, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class PcScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<PcButton> keys;
  const PcScaffold({super.key, required this.title, required this.body, this.keys = const []});

  @override
  Widget build(BuildContext context) {
    final row = <Widget>[];
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) row.add(const SizedBox(width: 4));
      row.add(Expanded(child: keys[i].withFn(i + 1)));
    }
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: PcFrame(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  color: kWhite,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kBg, fontSize: 15)),
                ),
                Expanded(child: body),
                if (keys.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: kWhite, width: 2))),
                    child: Row(children: row),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- アプリ本体 ----------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Cfg.load();
  runApp(const MailApp());
}

class MailApp extends StatelessWidget {
  const MailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'メール',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'DotGothic16',
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kCyan, surface: kBg),
        textSelectionTheme: const TextSelectionThemeData(cursorColor: kYellow),
      ),
      home: Cfg.token.isEmpty ? const SettingsPage(first: true) : const InboxPage(),
    );
  }
}

// ---------- 設定 ----------
class SettingsPage extends StatefulWidget {
  final bool first;
  const SettingsPage({super.key, this.first = false});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url = TextEditingController(text: Cfg.url);
  late final TextEditingController _tok = TextEditingController(text: Cfg.token);
  String _msg = '';
  bool _busy = false;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _msg = 'テスト中...';
    });
    await Cfg.save(_url.text, _tok.text);
    try {
      final j = await apiGet('/api/inbox', {'limit': '1'});
      if (!mounted) return;
      setState(() => _msg = '接続OK（受信箱 ${j['total']} 件）');
      if (widget.first) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const InboxPage()));
      }
    } catch (e) {
      if (mounted) setState(() => _msg = '接続失敗: ${errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PcScaffold(
      title: '設定',
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
              controller: _url,
              style: const TextStyle(color: kWhite),
              keyboardType: TextInputType.url,
              decoration: pcDeco('サーバーのアドレス')),
          const SizedBox(height: 12),
          TextField(
              controller: _tok,
              obscureText: true,
              style: const TextStyle(color: kWhite),
              decoration: pcDeco('合言葉 (MAIL_TOKEN)')),
          const SizedBox(height: 12),
          Text(_msg,
              style: TextStyle(color: _msg.startsWith('接続OK') ? kGreen : kYellow)),
        ],
      ),
      keys: [
        PcButton('保存してテスト', onTap: _busy ? null : _save, color: kGreen),
        if (!widget.first) PcButton('戻る', onTap: () => Navigator.pop(context)),
      ],
    );
  }
}

// ---------- 受信箱 ----------
class InboxPage extends StatefulWidget {
  const InboxPage({super.key});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final List<Map<String, dynamic>> items = [];
  int total = 0;
  int unseen = 0;
  bool loading = false;
  String? error;
  final ScrollController sc = ScrollController();

  @override
  void initState() {
    super.initState();
    sc.addListener(() {
      if (sc.hasClients &&
          sc.position.pixels > sc.position.maxScrollExtent - 300 &&
          !loading &&
          items.length < total) {
        _load(more: true);
      }
    });
    _load();
  }

  @override
  void dispose() {
    sc.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final j = await apiGet('/api/inbox',
          {'offset': '${more ? items.length : 0}', 'limit': '30'});
      final list = (j['items'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        if (!more) items.clear();
        final have = items.map((e) => e['uid']).toSet();
        items.addAll(list.where((e) => !have.contains(e['uid'])));
        total = j['total'] as int;
        unseen = (j['unseen'] as int?) ?? 0;
      });
    } catch (e) {
      if (mounted) setState(() => error = errText(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    if (mounted) _load();
  }

  Future<void> _deleteAll() async {
    try {
      final j = await apiGet('/api/count');
      final n = j['count'] as int;
      if (!mounted) return;
      final a = await pcAsk<bool>(
          context,
          '全件削除',
          '受信箱の $n 件を完全に削除します。\nゴミ箱も空になり、元に戻せません。',
          [PcChoice('やめる', false), PcChoice('削除する', true, kRed)]);
      if (a != true || !mounted) return;
      final b = await pcAsk<bool>(context, '最終確認', '本当に $n 件すべてを削除しますか？',
          [PcChoice('やめる', false), PcChoice('完全に削除', true, kRed)]);
      if (b != true) return;
      final r = await apiPost('/api/delete_all', {'confirm': n});
      if (!mounted) return;
      toast(context, '${r['deleted']} 件を削除しました');
      _load();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (error != null && items.isEmpty) {
      body = Center(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(error!, style: const TextStyle(color: kRed))));
    } else {
      body = RefreshIndicator(
        color: kBg,
        backgroundColor: kYellow,
        onRefresh: () => _load(),
        child: ListView.builder(
          controller: sc,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: items.length + (loading ? 1 : 0),
          itemBuilder: (c, i) {
            if (i >= items.length) {
              return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('読み込み中...', style: TextStyle(color: kYellow)));
            }
            final m = items[i];
            final blocked = m['blocked'] == true;
            final unread = m['seen'] != true;
            final who = ((m['from_name'] as String?) ?? '').isNotEmpty
                ? m['from_name'] as String
                : m['from'] as String;
            return PcPress(
              onTap: () {
                setState(() {
                  if (unread && unseen > 0) unseen--;
                  m['seen'] = true;
                });
                _open(MessagePage(uid: m['uid'] as int));
              },
              builder: (down) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                    color: down ? kWhite : null,
                    border: const Border(bottom: BorderSide(color: kGray, width: 0.5))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${unread ? '■' : '　'}${fmtDate(m['date'] as String)}  ${blocked ? '×' : ''}$who',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: down
                                ? kBg
                                : (blocked ? kRed : (unread ? kYellow : kCyan)),
                            fontSize: 13)),
                    Text(
                        '　> ${(m['subject'] as String).isEmpty ? '(件名なし)' : m['subject'] as String}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: down ? kBg : (unread ? kWhite : kGray), fontSize: 14)),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }
    return PcScaffold(
      title: '受信箱  未読$unseen  ${items.length}/$total 件',
      body: body,
      keys: [
        PcButton('更新', onTap: () => _load(), color: kGreen),
        PcButton('作成', onTap: () => _open(const ComposePage())),
        PcButton('ブロック', onTap: () => _open(const BlockPage()), color: kYellow),
        PcButton('全削除', onTap: _deleteAll, color: kRed),
        PcButton('設定', onTap: () => _open(const SettingsPage())),
      ],
    );
  }
}

// ---------- メール表示 ----------
class MessagePage extends StatefulWidget {
  final int uid;
  const MessagePage({super.key, required this.uid});
  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  Map<String, dynamic>? msg;
  String? error;
  WebViewController? wc;
  bool showHtml = false; // 既定はPC98風テキスト。HTMLは「HTML」キーで切り替え
  bool images = false; // 外部画像は最初は読み込まない（追跡防止）

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _hasHtml => ((msg?['html'] as String?) ?? '').trim().isNotEmpty;

  Future<void> _load() async {
    try {
      final j = await apiGet('/api/message/${widget.uid}');
      if (!mounted) return;
      setState(() => msg = j);
    } catch (e) {
      if (mounted) setState(() => error = errText(e));
    }
  }

  void _initWeb() {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(kBg)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) {
          final u = r.url;
          if (u.startsWith('about:') || u.startsWith('data:')) {
            return NavigationDecision.navigate;
          }
          launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
      ));
    wc = c;
    _reloadWeb();
  }

  String _wrapHtml(String html) {
    final img = images ? "data: https: http:" : "data:";
    return '<!DOCTYPE html><html><head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<meta http-equiv="Content-Security-Policy" '
        'content="default-src \'none\'; img-src $img; style-src \'unsafe-inline\'">'
        '<style>html,body{background:#000 !important;color:#fff !important;}'
        'body{margin:8px;word-break:break-word;font-family:monospace;}'
        '*{background-color:transparent !important;color:#fff !important;'
        'border-color:#fff !important;}'
        'a,a *{color:#0ff !important;}'
        'img{max-width:100% !important;height:auto !important;}'
        'table{max-width:100% !important;}</style>'
        '</head><body>$html</body></html>';
  }

  void _reloadWeb() {
    final h = (msg?['html'] as String?) ?? '';
    wc?.loadHtmlString(_wrapHtml(h));
  }

  Future<void> _block() async {
    final from = msg!['from'] as String;
    final domain = from.contains('@') ? '@${from.split('@').last}' : from;
    final s = await pcAsk<String>(
        context,
        'ブロック',
        '$from をブロックします。\n以降このメールは自動で完全に削除されます。\n範囲を選んでください。',
        [
          PcChoice('やめる', ''),
          PcChoice('このアドレスだけ', from, kYellow),
          PcChoice('$domain 全体', domain, kRed),
        ]);
    if (s == null || s.isEmpty) return;
    try {
      final r = await apiPost('/api/block', {'sender': s, 'purge': true});
      if (!mounted) return;
      toast(context, '${r['sender']} をブロックしました（${r['purged']}件削除）');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _openLink(String u) async {
    try {
      final ok = await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
      if (!ok && mounted) toast(context, '開けませんでした');
    } catch (_) {
      if (mounted) toast(context, '開けませんでした');
    }
  }

  Future<void> _download(int index) async {
    final uri = _u('/api/message/${widget.uid}/attachment/$index', {'token': Cfg.token});
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) toast(context, '開けませんでした');
  }

  void _reply() {
    final m = msg!;
    final subj = (m['subject'] as String);
    final quoted = bodyOf(m).split('\n').take(60).map((l) => '> $l').join('\n');
    final who = ((m['from_name'] as String?) ?? '').isNotEmpty ? m['from_name'] : m['from'];
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ComposePage(
                  replyUid: widget.uid,
                  to: m['from'] as String,
                  subject: RegExp(r'^re:', caseSensitive: false).hasMatch(subj) ? subj : 'Re: $subj',
                  body: '\n\n$who さんのメール:\n$quoted',
                )));
  }

  List<Widget> _header(Map<String, dynamic> m) {
    final atts = (m['attachments'] as List).cast<Map<String, dynamic>>();
    return [
      Text('差出人: ${((m['from_name'] as String?) ?? '')} <${m['from']}>',
          style: const TextStyle(color: kCyan)),
      Text('宛先:   ${m['to']}', style: const TextStyle(color: kCyan)),
      Text('日時:   ${fmtDateLong(m['date'] as String)}',
          style: const TextStyle(color: kCyan)),
      const SizedBox(height: 6),
      Text(m['subject'] as String, style: const TextStyle(color: kYellow, fontSize: 16)),
      const Divider(color: kWhite, thickness: 1),
      for (final a in atts)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: PcButton('[添付] ${a['filename']} (${fmtSize(a['size'] as int)})',
              color: kGreen, onTap: () => _download(a['index'] as int)),
        ),
      if (atts.isNotEmpty) const Divider(color: kGray, thickness: 0.5),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final m = msg;
    final webMode = m != null && _hasHtml && showHtml && wc != null;
    Widget body;
    if (error != null) {
      body = Center(child: Text(error!, style: const TextStyle(color: kRed)));
    } else if (m == null) {
      body = const Center(child: Text('読み込み中...', style: TextStyle(color: kYellow)));
    } else if (webMode) {
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _header(m)),
          ),
          if (!images && (m['html'] as String).contains('<img'))
            const Padding(
              padding: EdgeInsets.only(left: 10, bottom: 4),
              child: Text('※外部画像は非表示です（F4で表示）',
                  style: TextStyle(color: kGray, fontSize: 12)),
            ),
          Expanded(child: WebViewWidget(controller: wc!)),
        ],
      );
    } else {
      final parts = bodyParts(m);
      body = ListView(
        padding: const EdgeInsets.all(10),
        children: [
          ..._header(m),
          SelectableText(parts.text, style: const TextStyle(color: kWhite, fontSize: 14)),
          if (parts.links.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(color: kGray, thickness: 0.5),
            const Text('リンク（タップで開く）', style: TextStyle(color: kGray, fontSize: 12)),
            for (var i = 0; i < parts.links.length; i++)
              PcPress(
                onTap: () => _openLink(parts.links[i]),
                builder: (down) => Container(
                  width: double.infinity,
                  color: down ? kCyan : null,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Text('[${i + 1}] ${shortUrl(parts.links[i])}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: down ? kBg : kCyan, fontSize: 12)),
                ),
              ),
          ],
        ],
      );
    }
    return PcScaffold(
      title: 'メール',
      body: body,
      keys: [
        PcButton('返信', onTap: m == null ? null : _reply, color: kGreen),
        PcButton('ブロック', onTap: m == null ? null : _block, color: kRed),
        PcButton(showHtml ? 'テキスト' : 'HTML',
            onTap: (m != null && _hasHtml)
                ? () {
                    if (wc == null) _initWeb();
                    setState(() => showHtml = !showHtml);
                  }
                : null,
            color: kYellow),
        PcButton(images ? '画像OFF' : '画像ON',
            onTap: webMode
                ? () {
                    setState(() => images = !images);
                    _reloadWeb();
                  }
                : null,
            color: kYellow),
        PcButton('戻る', onTap: () => Navigator.pop(context)),
      ],
    );
  }
}

// ---------- 作成・返信 ----------
class ComposePage extends StatefulWidget {
  final int? replyUid;
  final String to;
  final String subject;
  final String body;
  const ComposePage(
      {super.key, this.replyUid, this.to = '', this.subject = '', this.body = ''});
  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  late final TextEditingController _to = TextEditingController(text: widget.to);
  final TextEditingController _cc = TextEditingController();
  late final TextEditingController _sub = TextEditingController(text: widget.subject);
  late final TextEditingController _body = TextEditingController(text: widget.body);
  final List<PlatformFile> files = [];
  bool sending = false;

  int get _totalSize => files.fold(0, (a, f) => a + f.size);

  Future<void> _pick() async {
    try {
      final r = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (r == null) return;
      setState(() {
        for (final f in r.files) {
          if (f.path != null) files.add(f);
        }
      });
      if (_totalSize > 24 * 1024 * 1024 && mounted) {
        toast(context, '添付の合計が24MBを超えています');
      }
    } catch (e) {
      if (mounted) toast(context, 'ファイル選択に失敗: $e');
    }
  }

  Future<void> _send() async {
    if (_to.text.trim().isEmpty && widget.replyUid == null) {
      toast(context, '宛先を入れてください');
      return;
    }
    if (_totalSize > 24 * 1024 * 1024) {
      toast(context, '添付の合計が24MBを超えています');
      return;
    }
    final ok = await pcAsk<bool>(
        context,
        '送信確認',
        '宛先: ${_to.text}\n${_cc.text.isEmpty ? '' : 'Cc: ${_cc.text}\n'}件名: ${_sub.text}\n添付: ${files.length}件 (${fmtSize(_totalSize)})\n\nこの内容で送信しますか？',
        [PcChoice('やめる', false), PcChoice('送信', true, kGreen)]);
    if (ok != true) return;
    setState(() => sending = true);
    try {
      final req = http.MultipartRequest('POST', _u('/api/send'));
      req.headers.addAll(_hdr());
      req.fields['to'] = _to.text.trim();
      req.fields['cc'] = _cc.text.trim();
      req.fields['subject'] = _sub.text;
      req.fields['body'] = _body.text;
      if (widget.replyUid != null) req.fields['reply_uid'] = '${widget.replyUid}';
      for (final f in files) {
        req.files.add(await http.MultipartFile.fromPath('files', f.path!, filename: f.name));
      }
      final resp = await http.Response.fromStream(
          await req.send().timeout(const Duration(minutes: 5)));
      _decode(resp);
      if (!mounted) return;
      toast(context, '送信しました');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, '送信失敗: ${errText(e)}');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PcScaffold(
      title: widget.replyUid == null ? '新規作成' : '返信',
      body: ListView(
        padding: const EdgeInsets.all(10),
        children: [
          TextField(
              controller: _to,
              style: const TextStyle(color: kWhite),
              keyboardType: TextInputType.emailAddress,
              decoration: pcDeco('宛先 (複数はカンマ区切り)')),
          const SizedBox(height: 8),
          TextField(
              controller: _cc,
              style: const TextStyle(color: kWhite),
              keyboardType: TextInputType.emailAddress,
              decoration: pcDeco('Cc')),
          const SizedBox(height: 8),
          TextField(
              controller: _sub,
              style: const TextStyle(color: kWhite),
              decoration: pcDeco('件名')),
          const SizedBox(height: 8),
          TextField(
              controller: _body,
              style: const TextStyle(color: kWhite),
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              decoration: pcDeco('本文')),
          const SizedBox(height: 8),
          for (var i = 0; i < files.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: PcButton('[×] ${files[i].name} (${fmtSize(files[i].size)})',
                  color: kYellow, onTap: () => setState(() => files.removeAt(i))),
            ),
        ],
      ),
      keys: [
        PcButton('送信', onTap: sending ? null : _send, color: kGreen),
        PcButton('添付', onTap: sending ? null : _pick, color: kYellow),
        PcButton('戻る', onTap: sending ? null : () => Navigator.pop(context)),
      ],
    );
  }
}

// ---------- ブロック一覧 ----------
class BlockPage extends StatefulWidget {
  const BlockPage({super.key});
  @override
  State<BlockPage> createState() => _BlockPageState();
}

class _BlockPageState extends State<BlockPage> {
  List<String> items = [];
  String? error;
  bool loading = true;
  final TextEditingController _add = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final j = await apiGet('/api/blocklist');
      if (mounted) {
        setState(() {
          items = (j['items'] as List).cast<String>();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = errText(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _addOne() async {
    final s = _add.text.trim();
    if (s.isEmpty) return;
    try {
      final r = await apiPost('/api/block', {'sender': s, 'purge': true});
      _add.clear();
      if (mounted) toast(context, '${r['sender']} をブロック（${r['purged']}件削除）');
      _load();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _remove(String s) async {
    final ok = await pcAsk<bool>(context, 'ブロック解除', '$s のブロックを解除しますか？',
        [PcChoice('やめる', false), PcChoice('解除', true, kYellow)]);
    if (ok != true) return;
    try {
      await apiDelete('/api/block', {'sender': s});
      _load();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _sweep() async {
    try {
      final r = await apiPost('/api/sweep', {});
      final d = (r['deleted'] as Map).values.fold<int>(0, (a, b) => a + (b as int));
      if (mounted) toast(context, '掃除しました（$d件削除）');
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PcScaffold(
      title: 'ブロック一覧  ${items.length} 件',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                    child: TextField(
                        controller: _add,
                        style: const TextStyle(color: kWhite),
                        keyboardType: TextInputType.emailAddress,
                        decoration: pcDeco('アドレス or ドメイン'))),
                const SizedBox(width: 6),
                SizedBox(width: 64, child: PcButton('追加', onTap: _addOne, color: kYellow)),
              ],
            ),
          ),
          Expanded(
            child: error != null
                ? Center(child: Text(error!, style: const TextStyle(color: kRed)))
                : loading
                    ? const Center(child: Text('読み込み中...', style: TextStyle(color: kYellow)))
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (c, i) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: const BoxDecoration(
                              border: Border(bottom: BorderSide(color: kGray, width: 0.5))),
                          child: Row(
                            children: [
                              Expanded(
                                  child: Text(items[i],
                                      style: const TextStyle(color: kRed, fontSize: 14))),
                              SizedBox(
                                  width: 64,
                                  child: PcButton('解除', onTap: () => _remove(items[i]))),
                            ],
                          ),
                        ),
                      ),
          ),
        ],
      ),
      keys: [
        PcButton('今すぐ掃除', onTap: _sweep, color: kGreen),
        PcButton('戻る', onTap: () => Navigator.pop(context)),
      ],
    );
  }
}
