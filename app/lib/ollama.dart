import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 后台准备进度（设置页实时显示，不阻塞界面）
class OllamaTask {
  const OllamaTask({this.running = false, this.percent, this.phase = ''});

  final bool running;
  final int? percent;
  final String phase;

  static const idle = OllamaTask();
}

/// 本地 Ollama 管理：自动拉起服务、自动拉取模型、预热进内存
///
/// 用户诉求：不要求他们手动开命令行。首次配置时点一次「一键准备」，
/// 之后每次对话前只要服务没在跑就自动拉起；模型缺失则自动 pull。
class Ollama {
  static const String host = 'http://127.0.0.1:11434';

  static Process? _serve;

  /// 后台任务进度：静默下载时设置页据此显示百分比
  static final ValueNotifier<OllamaTask> task = ValueNotifier(OllamaTask.idle);

  static bool _busy = false;

  /// 服务是否已经能响应
  static Future<bool> alive() async {
    try {
      final r =
          await http.get(Uri.parse('$host/api/tags')).timeout(const Duration(seconds: 2));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 已安装的模型（如 qwen2.5:3b）
  static Future<List<String>> models() async {
    try {
      final r =
          await http.get(Uri.parse('$host/api/tags')).timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final list = (j is Map && j['models'] is List) ? j['models'] as List : const [];
      return list
          .whereType<Map>()
          .map((e) => e['name'])
          .whereType<String>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 查找 ollama.exe：常见安装目录 → PATH
  static String? exePath() {
    final env = Platform.environment;
    final cands = <String>[];
    final local = env['LOCALAPPDATA'];
    final pf = env['ProgramFiles'];
    final pf86 = env['ProgramFiles(x86)'];
    if (local != null) {
      cands.add(p.join(local, 'Programs', 'Ollama', 'ollama.exe'));
    }
    if (pf != null) cands.add(p.join(pf, 'Ollama', 'ollama.exe'));
    if (pf86 != null) cands.add(p.join(pf86, 'Ollama', 'ollama.exe'));
    cands.add(r'C:\Program Files\Ollama\ollama.exe');
    for (final c in cands) {
      if (File(c).existsSync()) return c;
    }
    // PATH 里找（where 在 Windows 上一定存在）
    try {
      final r = Process.runSync('where.exe', ['ollama']);
      if (r.exitCode == 0) {
        final first = (r.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((e) => e.trim())
            .firstWhere((e) => e.toLowerCase().endsWith('.exe'), orElse: () => '');
        if (first.isNotEmpty && File(first).existsSync()) return first;
      }
    } catch (_) {}
    return null;
  }

  static bool get installed => exePath() != null;

  /// 打开官方下载页（本机没装时的一步引导）
  static Future<void> openDownloadPage() async {
    const url = 'https://ollama.com/download';
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {}
  }

  /// 确保服务在跑：没跑就后台拉起 `ollama serve`
  static Future<bool> ensureRunning(
      {Duration wait = const Duration(seconds: 25)}) async {
    if (await alive()) return true;
    final exe = exePath();
    if (exe == null) return false;
    try {
      _serve = await Process.start(exe, ['serve']);
      // 不消费管道会堵塞子进程
      _serve!.stdout.drain<void>();
      _serve!.stderr.drain<void>();
    } catch (_) {
      return false;
    }
    final deadline = DateTime.now().add(wait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (await alive()) return true;
    }
    return false;
  }

  /// 拉取模型（首次需下载，体积较大）；进度写进 [task]
  static final _pctRe = RegExp(r'(\d{1,3})\s*%');

  static Future<void> _pull(String model) async {
    final exe = exePath();
    if (exe == null) throw '没有找到 Ollama 命令';
    final proc = await Process.start(exe, ['pull', model]);

    // ollama pull 的进度用 \r 原地刷新、没有换行，所以按原始块解析而不是按行
    void handle(String chunk) {
      final ms = _pctRe.allMatches(chunk).toList();
      final cur = task.value;
      var pct = cur.percent;
      if (ms.isNotEmpty) {
        final v = int.tryParse(ms.last.group(1)!);
        if (v != null) pct = v.clamp(0, 100);
      }
      task.value = OllamaTask(running: true, percent: pct, phase: '下载 $model…');
    }

    proc.stdout.transform(utf8.decoder).listen(handle);
    proc.stderr.transform(utf8.decoder).listen(handle);
    final code = await proc.exitCode;
    if (code != 0) throw '下载模型 $model 失败';
  }

  /// 预热：把模型加载进内存，避免第一条消息等太久
  static Future<void> warmup(String model) async {
    try {
      await http
          .post(
            Uri.parse('$host/api/generate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'prompt': '',
              'stream': false,
              'keep_alive': '30m',
            }),
          )
          .timeout(const Duration(seconds: 90));
    } catch (_) {}
  }

  /// 一站式准备：启动服务 → 检查/拉取模型 → 预热
  ///
  /// 全程在后台静默进行：不弹任何窗口、不阻塞界面，
  /// 进度通过 [task] 暴露给设置页。返回空字符串表示成功，否则是错误提示。
  static Future<String> prepareInBackground(String model) async {
    if (_busy) return '';
    final m = model.trim();
    if (m.isEmpty) return '没有填写模型名';

    _busy = true;
    try {
      task.value = const OllamaTask(running: true, phase: '启动 Ollama 服务…');
      if (!await ensureRunning()) {
        if (exePath() == null) {
          return '本机没有找到 Ollama，请先安装（ollama.com/download）';
        }
        return 'Ollama 启动失败，请手动打开 Ollama 后重试';
      }

      task.value = OllamaTask(running: true, phase: '检查模型 $m…');
      var list = await models();
      if (!hasModel(list, m)) {
        task.value = OllamaTask(running: true, percent: 0, phase: '下载 $m…');
        await _pull(m);
        list = await models();
        if (!hasModel(list, m)) return '模型 $m 仍未就绪';
      }

      task.value = OllamaTask(running: true, percent: 100, phase: '加载模型到内存…');
      await warmup(m);
      task.value = OllamaTask(running: false, percent: 100, phase: '已就绪 · $m');
      return '';
    } catch (e) {
      task.value = OllamaTask(running: false, phase: '$e');
      return '$e';
    } finally {
      _busy = false;
    }
  }

  /// 正在后台准备（下载/加载）
  static bool get busy => _busy;

  static bool hasModel(List<String> list, String model) {
    final m = model.trim();
    if (m.isEmpty) return false;
    for (final e in list) {
      if (e == m || e.split(':').first == m) return true;
    }
    return false;
  }
}
