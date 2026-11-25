import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kDefaultUrl = 'http://100.102.7.80:5055';
const String kPrefKey = 'server_url';

void main() => runApp(const MonitorApp());

class MonitorApp extends StatelessWidget {
  const MonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'サーバー監視',
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
  String baseUrl = kDefaultUrl;
  Map<String, dynamic>? data;
  String? error;
  DateTime? updated;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(kPrefKey) ?? kDefaultUrl;
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    super.dispose();
  }

  // 画面を見ている間だけ5秒おきに取得（バックグラウンドでは止める）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
    } else {
      timer?.cancel();
      timer = null;
    }
  }

  void _start() {
    timer?.cancel();
    _fetch();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => _fetch());
  }

  Future<void> _fetch() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/stats'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        data = json;
        error = null;
        updated = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => error = '接続できません');
    }
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
          decoration: const InputDecoration(hintText: 'http://100.x.x.x:5055'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    final url = result.endsWith('/') ? result.substring(0, result.length - 1) : result;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefKey, url);
    if (!mounted) return;
    setState(() {
      baseUrl = url;
      data = null;
      error = null;
    });
    _start();
  }

  // ---- 表示用の小道具 ----
  static String gb(num b) => '${(b / 1073741824).toStringAsFixed(1)} GB';

  static String uptime(int s) {
    final d = s ~/ 86400;
    final h = (s % 86400) ~/ 3600;
    final m = (s % 3600) ~/ 60;
    return '$d日 $h時間 $m分';
  }

  static Color barColor(double p) {
    if (p >= 90) return const Color(0xFFF44336);
    if (p >= 75) return const Color(0xFFFF9800);
    return const Color(0xFF4CAF50);
  }

  static const Map<String, String> labels = {
    'disk': 'ディスク',
    'mem': 'メモリ',
    'temp': '温度',
    'cpu': 'CPU',
  };

  Widget card(String title, String value, {double? percent}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 24)),
          if (percent != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (percent / 100).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: const Color(0xFF333333),
                valueColor: AlwaysStoppedAnimation<Color>(barColor(percent)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _body() {
    final d = data;
    if (d == null) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 80),
          child: Center(child: Text(error ?? '読み込み中...')),
        ),
      ];
    }
    final alerts = (d['alerts'] as List?)?.cast<String>() ?? <String>[];
    final load = (d['load'] as List).map((e) => (e as num).toString()).join(' / ');
    final temp = d['temp_c'] as num?;
    return [
      if (error != null)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          color: const Color(0xFF5D4037),
          child: Text('$error（最後に取得したデータを表示中）'),
        ),
      if (alerts.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFB71C1C),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('⚠ 警告: ${alerts.map((k) => labels[k] ?? k).join('、')}'),
        ),
      card('CPU', '${d['cpu_percent']} %', percent: (d['cpu_percent'] as num).toDouble()),
      card('メモリ', '${gb(d['mem_used'])} / ${gb(d['mem_total'])}',
          percent: (d['mem_percent'] as num).toDouble()),
      card('ディスク', '${gb(d['disk_used'])} / ${gb(d['disk_total'])}',
          percent: (d['disk_percent'] as num).toDouble()),
      card('負荷 (1/5/15分)', '$load  (${d['cpu_cores']}コア)'),
      if (temp != null) card('温度', '$temp ℃', percent: temp.toDouble()),
      card('稼働時間', uptime((d['uptime_sec'] as num).toInt())),
      if (updated != null)
        Center(
          child: Text(
            '更新 ${updated!.hour.toString().padLeft(2, '0')}:'
            '${updated!.minute.toString().padLeft(2, '0')}:'
            '${updated!.second.toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('サーバー監視'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _editUrl),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _fetch,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            children: _body(),
          ),
        ),
      ),
    );
  }
}
