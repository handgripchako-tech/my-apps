import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kDefaultRepo = 'handgripchako-tech/test-server-backup';
const String kDefaultBranch = 'memos';
const String kJsonPath = 'memos/memos.json';
const String kMdPath = 'memos/memos.md';

void main() => runApp(const MemoApp());

String two(int n) => n.toString().padLeft(2, '0');

String fmt(DateTime d) {
  final l = d.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class Memo {
  String id;
  String text;
  DateTime created;
  DateTime updated;

  Memo({
    required this.id,
    required this.text,
    required this.created,
    required this.updated,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'created': created.toUtc().toIso8601String(),
        'updated': updated.toUtc().toIso8601String(),
      };

  factory Memo.fromJson(Map<String, dynamic> j) => Memo(
        id: j['id'] as String,
        text: j['text'] as String,
        created: DateTime.parse(j['created'] as String),
        updated: DateTime.parse(j['updated'] as String),
      );
}

class MemoStore extends ChangeNotifier {
  List<Memo> memos = [];
  String token = '';
  String repo = kDefaultRepo;
  String branch = kDefaultBranch;
  bool dirty = false;
  bool syncing = false;
  bool again = false;
  String status = '';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    token = p.getString('gh_token') ?? '';
    repo = p.getString('gh_repo') ?? kDefaultRepo;
    branch = p.getString('gh_branch') ?? kDefaultBranch;
    dirty = p.getBool('dirty') ?? false;
    final raw = p.getString('memos');
    if (raw != null) {
      memos = (jsonDecode(raw) as List)
          .map((e) => Memo.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    _sort();
    status = token.isEmpty ? '設定でトークンを入れると共有できます' : (dirty ? '未送信あり' : '');
    notifyListeners();
    if (dirty && token.isNotEmpty) sync();
  }

  void _sort() => memos.sort((a, b) => b.created.compareTo(a.created));

  Future<void> _saveLocal() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('memos', jsonEncode(memos.map((m) => m.toJson()).toList()));
    await p.setBool('dirty', dirty);
  }

  Future<void> saveSettings(String t, String r, String b) async {
    token = t.trim();
    repo = r.trim().isEmpty ? kDefaultRepo : r.trim();
    branch = b.trim().isEmpty ? kDefaultBranch : b.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString('gh_token', token);
    await p.setString('gh_repo', repo);
    await p.setString('gh_branch', branch);
    notifyListeners();
  }

  Future<void> add(String text) async {
    final now = DateTime.now();
    memos.add(Memo(
      id: now.millisecondsSinceEpoch.toString(),
      text: text,
      created: now,
      updated: now,
    ));
    await _changed();
  }

  Future<void> edit(Memo m, String text) async {
    m.text = text;
    m.updated = DateTime.now();
    await _changed();
  }

  Future<void> remove(Memo m) async {
    memos.removeWhere((x) => x.id == m.id);
    await _changed();
  }

  Future<void> _changed() async {
    _sort();
    dirty = true;
    await _saveLocal();
    notifyListeners();
    sync();
  }

  Map<String, String> _headers() => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json; charset=utf-8',
      };

  String _errText(http.Response r) {
    try {
      final m = (jsonDecode(r.body) as Map)['message'];
      return '${r.statusCode} $m';
    } catch (_) {
      return '${r.statusCode}';
    }
  }

  Future<String?> _getSha(http.Client c, String path) async {
    final r = await c.get(
      Uri.parse('https://api.github.com/repos/$repo/contents/$path?ref=$branch'),
      headers: _headers(),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw Exception(_errText(r));
    return (jsonDecode(r.body) as Map)['sha'] as String?;
  }

  Future<void> _put(http.Client c, String path, String content) async {
    final sha = await _getSha(c, path);
    final body = jsonEncode({
      'message': 'メモ更新 ${fmt(DateTime.now())}',
      'content': base64Encode(utf8.encode(content)),
      'branch': branch,
      if (sha != null) 'sha': sha,
    });
    final r = await c.put(
      Uri.parse('https://api.github.com/repos/$repo/contents/$path'),
      headers: _headers(),
      body: body,
    );
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_errText(r));
    }
  }

  String _toJsonText() => const JsonEncoder.withIndent('  ')
      .convert(memos.map((m) => m.toJson()).toList());

  String _toMarkdown() {
    final b = StringBuffer();
    b.writeln('# メモ一覧（新しい順）');
    b.writeln();
    b.writeln('更新: ${fmt(DateTime.now())} / ${memos.length}件');
    for (final m in memos) {
      b.writeln();
      b.writeln('## ${fmt(m.created)}');
      b.writeln();
      b.writeln(m.text);
    }
    return b.toString();
  }

  Future<void> sync() async {
    if (token.isEmpty) {
      status = '設定でトークンを入れると共有できます';
      notifyListeners();
      return;
    }
    if (syncing) {
      again = true;
      return;
    }
    syncing = true;
    status = '送信中…';
    notifyListeners();
    final c = http.Client();
    try {
      do {
        again = false;
        await _put(c, kJsonPath, _toJsonText());
        await _put(c, kMdPath, _toMarkdown());
      } while (again);
      dirty = false;
      status = '送信済み ${fmt(DateTime.now())}';
    } catch (e) {
      dirty = true;
      status = '送信失敗: ${e.toString().replaceFirst('Exception: ', '')}';
    } finally {
      c.close();
      syncing = false;
      await _saveLocal();
      notifyListeners();
    }
  }

  /// GitHub 上の memos.json で、手元のメモを置き換える
  Future<String> restore() async {
    if (token.isEmpty) return 'トークンが未設定です';
    final c = http.Client();
    try {
      final r = await c.get(
        Uri.parse(
            'https://api.github.com/repos/$repo/contents/$kJsonPath?ref=$branch'),
        headers: _headers(),
      );
      if (r.statusCode == 404) return 'GitHub にまだメモがありません';
      if (r.statusCode != 200) return '失敗: ${_errText(r)}';
      final enc = (jsonDecode(r.body) as Map)['content'] as String;
      final txt = utf8.decode(base64Decode(enc.replaceAll('\n', '')));
      memos = (jsonDecode(txt) as List)
          .map((e) => Memo.fromJson(e as Map<String, dynamic>))
          .toList();
      _sort();
      dirty = false;
      await _saveLocal();
      notifyListeners();
      return '${memos.length}件を復元しました';
    } catch (e) {
      return '失敗: $e';
    } finally {
      c.close();
    }
  }
}

class MemoApp extends StatelessWidget {
  const MemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'メモ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF111111),
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final store = MemoStore();
  final input = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    input.dispose();
    store.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && store.dirty) store.sync();
  }

  Future<void> _submit() async {
    final t = input.text.trim();
    if (t.isEmpty) return;
    input.clear();
    await store.add(t);
  }

  Future<void> _editDialog(Memo m) async {
    final ctl = TextEditingController(text: m.text);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(fmt(m.created), style: const TextStyle(fontSize: 14)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 8,
          minLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('削除', style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = ctl.text.trim();
    if (action == 'save' && text.isNotEmpty && text != m.text) {
      await store.edit(m, text);
    } else if (action == 'delete') {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('このメモを削除しますか？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('やめる')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('削除')),
          ],
        ),
      );
      if (ok == true) await store.remove(m);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('メモ'),
            actions: [
              IconButton(
                tooltip: '今すぐ送信',
                icon: Icon(
                  store.syncing
                      ? Icons.cloud_sync
                      : (store.dirty ? Icons.cloud_off : Icons.cloud_done),
                ),
                onPressed: store.sync,
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => SettingsPage(store: store)),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              if (store.status.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  color: const Color(0xFF1C1C1C),
                  child: Text(
                    store.status,
                    style: TextStyle(
                      fontSize: 12,
                      color: store.status.startsWith('送信失敗')
                          ? Colors.redAccent
                          : Colors.white54,
                    ),
                  ),
                ),
              Expanded(
                child: store.memos.isEmpty
                    ? const Center(
                        child: Text('思いついたことを下に書いて送信',
                            style: TextStyle(color: Colors.white38)))
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: store.memos.length,
                        itemBuilder: (_, i) {
                          final m = store.memos[i];
                          return Card(
                            color: const Color(0xFF1E1E1E),
                            child: ListTile(
                              title: Text(m.text),
                              subtitle: Text(fmt(m.created),
                                  style: const TextStyle(fontSize: 11)),
                              onTap: () => _editDialog(m),
                            ),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: input,
                          minLines: 1,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            hintText: '思いついたこと',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        icon: const Icon(Icons.send),
                        onPressed: _submit,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SettingsPage extends StatefulWidget {
  final MemoStore store;
  const SettingsPage({super.key, required this.store});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController token;
  late final TextEditingController repo;
  late final TextEditingController branch;
  String msg = '';

  @override
  void initState() {
    super.initState();
    token = TextEditingController(text: widget.store.token);
    repo = TextEditingController(text: widget.store.repo);
    branch = TextEditingController(text: widget.store.branch);
  }

  @override
  void dispose() {
    token.dispose();
    repo.dispose();
    branch.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.store.saveSettings(token.text, repo.text, branch.text);
    setState(() => msg = '保存しました');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'GitHub トークン',
              helperText: 'このリポジトリの Contents 書き込み権限だけ付けたもの',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: repo,
            decoration: const InputDecoration(
              labelText: 'リポジトリ（owner/repo）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: branch,
            decoration: const InputDecoration(
              labelText: 'ブランチ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('保存')),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await _save();
              await widget.store.sync();
              setState(() => msg = widget.store.status);
            },
            child: const Text('保存して今すぐ送信'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('GitHub のメモで置き換えますか？'),
                  content: const Text('手元のメモは上書きされます。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('やめる')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('復元')),
                  ],
                ),
              );
              if (ok != true) return;
              await _save();
              final r = await widget.store.restore();
              setState(() => msg = r);
            },
            child: const Text('GitHub から復元'),
          ),
          const SizedBox(height: 16),
          Text(msg, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}
