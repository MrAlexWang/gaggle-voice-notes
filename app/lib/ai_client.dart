import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'a2a.dart';
import 'db.dart';
import 'ollama.dart';
import 'theme.dart';

const String kSystemPrompt =
    '你是「雁书」的助手，帮用户理解和整理他们的录音与笔记。'
    '用户输入可能包含多段带【】标题的语料，请：\n'
    '1. 提炼核心观点，按重要程度排序\n'
    '2. 指出不同内容之间的共同点与分歧\n'
    '3. 如果提到待办、决定或时间节点，单独列出\n'
    '要求：用简体中文，条理清晰，直接给结论，不要复述原文，不要编造语料里没有的信息。';

/// AI 服务配置（存 DB，默认走本地 Ollama）
class AiConfig {
  const AiConfig({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  final String provider;
  final String baseUrl;
  final String model;
  final String apiKey;

  bool get isOllama => provider == 'ollama' || baseUrl.contains('11434');
  bool get isA2a => provider == 'a2a';
  bool get ready => isA2a || isOllama || apiKey.isNotEmpty;

  /// 常见服务商预设
  static const presets = <String, Map<String, String>>{
    'ollama': {
      'label': '本地 Ollama',
      'baseUrl': 'http://127.0.0.1:11434/v1',
      'model': 'qwen2.5:3b',
    },
    'deepseek': {
      'label': 'DeepSeek',
      'baseUrl': 'https://api.deepseek.com/v1',
      'model': 'deepseek-chat',
    },
    'qwen': {
      'label': '通义千问',
      'baseUrl': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'model': 'qwen-plus',
    },
    'kimi': {
      'label': 'Kimi',
      'baseUrl': 'https://api.moonshot.cn/v1',
      'model': 'moonshot-v1-8k',
    },
    'openai': {
      'label': 'OpenAI',
      'baseUrl': 'https://api.openai.com/v1',
      'model': 'gpt-4o-mini',
    },
    'a2a': {
      'label': '本机智能体',
      'baseUrl': '',
      'model': 'a2a',
    },
    'custom': {
      'label': '自定义',
      'baseUrl': 'http://127.0.0.1:8000/v1',
      'model': 'local-model',
    },
  };
}

class AiClient {
  static AiConfig load() {
    final db = Db.instance;
    final provider = db.getSetting('ai_provider') ?? 'ollama';
    final preset = AiConfig.presets[provider] ?? AiConfig.presets['ollama']!;
    return AiConfig(
      provider: provider,
      baseUrl: db.getSetting('ai_base_url') ?? preset['baseUrl']!,
      model: db.getSetting('ai_model') ?? preset['model']!,
      apiKey: db.getSetting('ai_api_key') ?? '',
    );
  }

  static void save(AiConfig c) {
    Db.instance.setSetting('ai_provider', c.provider);
    Db.instance.setSetting('ai_base_url', c.baseUrl);
    Db.instance.setSetting('ai_model', c.model);
    Db.instance.setSetting('ai_api_key', c.apiKey);
  }

  static String _trim(String s) => s.replaceAll(RegExp(r'/+$'), '');

  static String friendly(Object e, AiConfig cfg) {
    final s = e.toString();
    if (s.contains('Connection refused') || s.contains('SocketException')) {
      if (cfg.isOllama) {
        return '连不上本地 Ollama（${cfg.baseUrl}）。\n'
            '已尝试自动启动：${Ollama.installed ? '服务仍未响应，请到「设置 → AI 服务」点「一键准备」检查模型' : '本机没有找到 Ollama，请先安装（ollama.com/download）'}';
      }
      return '连不上 ${cfg.baseUrl}，请检查地址与网络。';
    }
    if (s.contains('401') || s.contains('Unauthorized')) {
      return 'API Key 无效或被拒绝（401），请在设置里检查。';
    }
    if (s.contains('404')) {
      return '接口地址不对（404）。请确认 base_url 形如 https://…/v1';
    }
    if (s.contains('TimeoutException')) {
      return '请求超时，模型可能正在加载或网络较慢，稍后再试。';
    }
    return s;
  }

  /// 当前选中的 A2A 智能体（找不到就用扫描到的第一个）
  static A2aAgent? selectedAgent() {
    final agents = A2aClient.instance.agents;
    if (agents.isEmpty) return null;
    final want = Db.instance.getSetting('a2a_selected') ?? '';
    for (final a in agents) {
      if (a.endpoint == want) return a;
    }
    return agents.first;
  }

  /// 测试连通性，返回可读结果
  static Future<String> test(AiConfig cfg) async {
    if (cfg.isA2a) return _testA2a();
    try {
      final url = Uri.parse('${_trim(cfg.baseUrl)}/models');
      final headers = <String, String>{};
      if (cfg.apiKey.isNotEmpty) headers['Authorization'] = 'Bearer ${cfg.apiKey}';
      final r = await http.get(url, headers: headers).timeout(const Duration(seconds: 8));

      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        final models = (j is Map && j['data'] is List)
            ? (j['data'] as List)
                .whereType<Map>()
                .map((e) => e['id'])
                .whereType<String>()
                .toList()
            : <String>[];
        if (models.isEmpty) return '已连接，但没有可用模型';
        final has = models.any((m) => m == cfg.model || m.startsWith(cfg.model));
        if (has) return '已连接 · ${cfg.model}';
        return '已连接，但列表里没有 ${cfg.model}（可用：${models.take(3).join('、')}）';
      }
      if (r.statusCode == 401) return 'API Key 无效（401）';
      return '返回 HTTP ${r.statusCode}';
    } catch (e) {
      return friendly(e, cfg);
    }
  }

  /// A2A 连通性：真的发一句话过去，验证能不能被调用
  static Future<String> _testA2a() async {
    try {
      var agents = A2aClient.instance.agents;
      if (agents.isEmpty) agents = await A2aClient.instance.discover();
      if (agents.isEmpty) {
        return '没扫描到本机智能体，请先启动它再点「重新扫描」';
      }
      final agent = selectedAgent() ?? agents.first;
      final reply = await A2aClient.instance
          .send(agent: agent, text: '连通性测试：请回复「收到」两个字。')
          .timeout(const Duration(seconds: 25));
      final brief = reply.replaceAll(RegExp(r'\s+'), ' ');
      final cut = brief.length > 40 ? '${brief.substring(0, 40)}…' : brief;
      return '已连接 · ${agent.name}（$cut）';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  /// 流式对话
  static Stream<String> chat({required String prompt}) {
    final cfg = load();
    late StreamController<String> ctrl;
    http.Client? client;

    Future<void> run() async {
      try {
        // A2A 智能体：自动扫描本机已安装的 Agent，走 A2A 协议调用
        if (cfg.provider == 'a2a') {
          var agents = A2aClient.instance.agents;
          if (agents.isEmpty) agents = await A2aClient.instance.discover();
          if (agents.isEmpty) {
            ctrl.addError('没扫描到本机 A2A 智能体。\n'
                '请确认智能体已在运行（例如「启动AI助手.bat」），'
                '然后在「设置 → AI 服务」点「重新扫描智能体」。');
            return;
          }
          final want = Db.instance.getSetting('a2a_selected') ?? '';
          final agent = agents.firstWhere(
            (a) => a.endpoint == want,
            orElse: () => agents.first,
          );
          await for (final delta in A2aClient.instance
              .sendStream(agent: agent, text: prompt)) {
            if (!ctrl.isClosed) ctrl.add(delta);
          }
          return;
        }

        // 本地 Ollama：服务没在跑就自动拉起，用户不用手动开命令行
        if (cfg.isOllama && !await Ollama.alive()) {
          final ok = await Ollama.ensureRunning(wait: const Duration(seconds: 20));
          if (!ok) {
            if (!ctrl.isClosed) {
              ctrl.addError(Ollama.installed
                  ? '连不上本地 Ollama（${cfg.baseUrl}）。\n服务启动失败，请到「设置 → AI 服务」点「一键准备」。'
                  : '连不上本地 Ollama（${cfg.baseUrl}）。\n本机没有找到 Ollama，请先安装（ollama.com/download）。');
            }
            return;
          }
        }

        client = http.Client();
        final url = Uri.parse('${_trim(cfg.baseUrl)}/chat/completions');
        final req = http.Request('POST', url)
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({
            'model': cfg.model,
            'messages': [
              {'role': 'system', 'content': kSystemPrompt},
              {'role': 'user', 'content': prompt},
            ],
            'stream': true,
            'temperature': 0.3,
          });
        if (cfg.apiKey.isNotEmpty) {
          req.headers['Authorization'] = 'Bearer ${cfg.apiKey}';
        }

        final resp = await client!.send(req);
        if (resp.statusCode != 200) {
          final body = await resp.stream.bytesToString();
          final brief = body.length > 240 ? body.substring(0, 240) : body;
          ctrl.addError(friendly('HTTP ${resp.statusCode}: $brief', cfg));
          return;
        }

        final buf = StringBuffer();
        await for (final chunk in resp.stream.transform(utf8.decoder)) {
          buf.write(chunk);
          var content = buf.toString();
          while (true) {
            final idx = content.indexOf('\n');
            if (idx < 0) break;
            final line = content.substring(0, idx).trim();
            content = content.substring(idx + 1);
            if (!line.startsWith('data:')) continue;
            final data = line.substring(5).trim();
            if (data.isEmpty) continue;
            if (data == '[DONE]') {
              buf.clear();
              return;
            }
            try {
              final j = jsonDecode(data);
              if (j is! Map) continue;
              final choices = j['choices'];
              if (choices is List && choices.isNotEmpty) {
                final delta = choices.first['delta'];
                if (delta is Map) {
                  final t = delta['content'];
                  if (t is String && t.isNotEmpty) ctrl.add(t);
                }
              }
            } catch (_) {}
          }
          buf
            ..clear()
            ..write(content);
        }
      } catch (e) {
        if (!ctrl.isClosed) ctrl.addError(friendly(e, cfg));
      } finally {
        client?.close();
        if (!ctrl.isClosed) await ctrl.close();
      }
    }

    ctrl = StreamController<String>(
      onListen: () => run(),
      onCancel: () => client?.close(),
    );
    return ctrl.stream;
  }

  /// 本机是否真的存在 Ollama（用于设置页提示）
  static Future<bool> ollamaAlive() => Ollama.alive();

  // ================= 标签 =================

  /// 转写完成后是否自动让 AI 打标签（默认开）
  static bool get autoTagEnabled =>
      (Db.instance.getSetting('ai_auto_tag') ?? '1') == '1';

  static void setAutoTagEnabled(bool v) =>
      Db.instance.setSetting('ai_auto_tag', v ? '1' : '0');

  /// 让 AI 给某条目生成标签；手动标签保留，只替换上一轮 AI 标签
  static Future<List<String>> tagItem(String itemId, {int max = 5}) async {
    final cfg = load();
    if (!cfg.ready) throw '还没有配置 AI 服务';

    final it = Db.instance.byId(itemId);
    if (it == null) return const [];

    final segs = Db.instance.segments(itemId);
    final text = segs.isNotEmpty
        ? segs.map((s) => s['text'] as String? ?? '').join(' ')
        : (it.body ?? '');
    if (text.trim().isEmpty) return const [];

    final tags = await _suggestTags(it.title, text, cfg, max: max);
    if (tags.isEmpty) return const [];
    Db.instance.setAiTags(itemId, tags);
    return tags;
  }

  /// 一次非流式请求，返回标签列表
  static Future<List<String>> _suggestTags(
    String title,
    String text,
    AiConfig cfg, {
    int max = 5,
  }) async {
    if (cfg.isOllama && !await Ollama.alive()) {
      await Ollama.ensureRunning(wait: const Duration(seconds: 12));
    }

    final clipped = text.length > 1600 ? text.substring(0, 1600) : text;
    final prompt = '标题：$title\n正文：$clipped\n\n'
        '请为这条内容打不超过 $max 个短标签。要求：中文、每个 2~6 字、'
        '能体现主题或场景（如「产品评审」「面试」「就医」），'
        '不要标点符号，不要解释，只输出用英文逗号分隔的标签。';

    final content = await _complete(prompt, cfg);
    return parseTags(content, max: max);
  }

  // ================= 自动命名 =================

  /// 转写完成后是否用 AI 给录音起名字（默认开）
  static bool get autoNameEnabled =>
      (Db.instance.getSetting('ai_auto_name') ?? '1') == '1';

  static void setAutoNameEnabled(bool v) =>
      Db.instance.setSetting('ai_auto_name', v ? '1' : '0');

  /// 用 AI 把录音改名为「标题 · 年月日时分秒」
  /// 只处理默认标题（以「录音」开头）的条目，不覆盖用户改过的名字
  static Future<String> autoNameItem(String itemId) async {
    final cfg = load();
    if (!cfg.ready) return '';
    final it = Db.instance.byId(itemId);
    if (it == null || !it.title.startsWith('录音')) return '';

    final segs = Db.instance.segments(itemId);
    final text = segs.isNotEmpty
        ? segs.map((s) => s['text'] as String? ?? '').join(' ')
        : (it.body ?? '');
    if (text.trim().isEmpty) return '';

    final name = await _suggestTitle(text, cfg);
    if (name.isEmpty) return '';
    final title = '$name · ${fmtStamp(it.createdAt)}';
    Db.instance.rename(itemId, title);
    return title;
  }

  static final _leadTrim = RegExp(r'''^[\s"'“”‘’《》〈〉「」『』【】`*·\-\u3000]+''');
  static final _tailTrim = RegExp(r'''[\s"'“”‘’《》〈〉「」『』【】`*。．\.!！?？~]+$''');

  /// 解析模型返回的标题：去引号书名号、取第一行、限长
  @visibleForTesting
  static String parseTitle(String raw) {
    final line = raw
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');
    if (line.isEmpty) return '';
    var s = line.replaceAll(_leadTrim, '').replaceAll(_tailTrim, '');
    s = s.replaceAll(RegExp(r'\s+'), '');
    if (s.length > 16) s = s.substring(0, 16);
    return s;
  }

  static Future<String> _suggestTitle(String text, AiConfig cfg) async {
    if (cfg.isOllama && !await Ollama.alive()) {
      await Ollama.ensureRunning(wait: const Duration(seconds: 12));
    }
    final clipped = text.length > 1200 ? text.substring(0, 1200) : text;
    final prompt = '以下是录音的转写内容：\n$clipped\n\n'
        '请为这段录音起一个中文短标题：不超过 12 个字，概括主题或场景'
        '（如「产品评审会」「就医复诊」「面试复盘」）。'
        '不要标点符号，不要引号，不要解释，只输出标题本身。';
    final content = await _complete(prompt, cfg);
    return parseTitle(content);
  }

  // ================= 对话助手：推荐提问 / 会话标题 =================

  /// 依据引用条目内容给会话起名字（用户还没提问时用）
  static Future<String> suggestTitleFromItems(List<String> itemIds) async {
    final cfg = load();
    if (!cfg.ready) return '';
    final buf = StringBuffer();
    for (final id in itemIds.take(3)) {
      final it = Db.instance.byId(id);
      if (it == null) continue;
      buf.writeln('【${it.title}】');
      final segs = Db.instance.segments(id);
      final text = segs.isNotEmpty
          ? segs.map((s) => s['text'] as String? ?? '').join(' ')
          : (it.body ?? '');
      if (text.isNotEmpty) {
        buf.writeln(text.length > 500 ? '${text.substring(0, 500)}…' : text);
      }
    }
    if (buf.isEmpty) return '';
    final prompt = '以下是用户选中要做分析的内容：\n${buf.toString().trim()}\n\n'
        '请为这次分析起一个中文短标题：不超过 12 个字，概括这些内容的主题'
        '（如「录音功能需求对齐」「本地模型取舍」）。'
        '不要标点符号，不要引号，不要解释，只输出标题本身。';
    final content = await _complete(prompt, cfg);
    return parseTitle(content);
  }

  /// 依据一问一答给会话起名字（12 字以内）
  static Future<String> suggestConvTitle({
    required String question,
    required List<String> refTitles,
  }) async {
    final cfg = load();
    if (!cfg.ready) return '';
    final ctx = refTitles.isEmpty ? '' : '\n涉及的录音：${refTitles.take(3).join('、')}';
    final prompt = '用户问：$question$ctx\n\n'
        '请给这次对话起一个中文短标题：不超过 12 个字，概括主题。'
        '不要标点符号，不要引号，不要解释，只输出标题本身。';
    final content = await _complete(prompt, cfg);
    return parseTitle(content);
  }

  /// 推荐接下来想问的问题（默认 3 条）
  static Future<List<String>> suggestQuestions({
    required List<String> refTitles,
    List<String> recentTurns = const [],
    int count = 3,
  }) async {
    final cfg = load();
    if (!cfg.ready) return const [];

    final ctx = refTitles.isEmpty ? '（无引用内容）' : refTitles.join('、');
    final turns = recentTurns.isEmpty
        ? ''
        : '\n最近的对话：\n${recentTurns.map((e) => e.length > 120 ? '${e.substring(0, 120)}…' : e).join('\n')}';

    final prompt = '正在分析的内容：$ctx$turns\n\n'
        '请给出 $count 个用户接下来最可能想问的问题，帮他继续挖掘内容。\n'
        '要求：中文、每个不超过 18 字、必须是用户可以直接点的提问'
        '（如「一句话总结」「转述给别人听」「有哪些值得质疑的地方」），'
        '不要编号、不要引号、不要解释，每行一个。';

    final content = await _complete(prompt, cfg);
    return parseQuestions(content, count: count);
  }

  /// 解析模型返回的推荐问题
  @visibleForTesting
  static List<String> parseQuestions(String raw, {int count = 3}) {
    final s = raw
        .replaceAll(RegExp(r'```[a-zA-Z]*'), '')
        .replaceAll('```', '')
        .trim();
    final out = <String>[];
    for (final part in s.split(RegExp(r'[\r\n]+|[,，;；]+'))) {
      var t = part.trim();
      t = t.replaceAll(RegExp(r'^\d+\s*[.、)．:：]\s*'), '');
      t = t.replaceAll(RegExp(r'^[-*·•\s]+'), '');
      t = t
          .replaceAll(RegExp(r'''^["'“”‘’《》「」『』【】`]+'''), '')
          .replaceAll(RegExp(r'''["'“”‘’《》「」『』【】`]+$'''), '')
          .trim();
      if (t.isEmpty || t.length > 30) continue;
      if (RegExp(r'^\d+$').hasMatch(t)) continue;
      if (!out.contains(t)) out.add(t);
      if (out.length >= count) break;
    }
    return out;
  }

  /// 非流式一次性补全（标签、命名共用）
  static Future<String> _complete(String prompt, AiConfig cfg) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (cfg.apiKey.isNotEmpty) headers['Authorization'] = 'Bearer ${cfg.apiKey}';

    final r = await http
        .post(
          Uri.parse('${_trim(cfg.baseUrl)}/chat/completions'),
          headers: headers,
          body: jsonEncode({
            'model': cfg.model,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
            'stream': false,
            'temperature': 0.2,
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final choices = (j is Map) ? j['choices'] : null;
    if (choices is! List || choices.isEmpty) return '';
    final msg = choices.first['message'];
    return (msg is Map ? msg['content'] : null) as String? ?? '';
  }

  /// 解析模型返回的标签文本（兼容 JSON 数组 / 逗号 / 顿号 / 换行 / #号）
  @visibleForTesting
  static List<String> parseTags(String raw, {int max = 5}) {
    var s = raw.trim();
    if (s.isEmpty) return const [];

    // 去掉 ```json 围栏
    s = s.replaceAll(RegExp(r'```[a-zA-Z]*'), '').replaceAll('```', '').trim();

    final out = <String>[];
    void take(Object? v) {
      if (v == null) return;
      final t = v
          .toString()
          .replaceAll(RegExp(r'^[#\s\-*·]+'), '')
          .replaceAll(RegExp(r'''[。，,.;；:：!！"“”'`]'''), '')
          .trim();
      if (t.isEmpty || t.length > 12) return;
      if (!out.contains(t)) out.add(t);
    }

    // 先试 JSON 数组
    final l = s.indexOf('[');
    final r = s.lastIndexOf(']');
    if (l >= 0 && r > l) {
      try {
        final arr = jsonDecode(s.substring(l, r + 1));
        if (arr is List) {
          for (final e in arr) {
            take(e);
          }
          return out.take(max).toList();
        }
      } catch (_) {}
    }

    for (final part in s.split(RegExp(r'[,，、\n;；|]+'))) {
      take(part);
      if (out.length >= max) break;
    }
    return out.take(max).toList();
  }

  /// 数据占用空间（字节）
  static int dataSizeBytes() {
    var total = 0;
    try {
      final dir = Directory(Db.instance.rootPath);
      if (!dir.existsSync()) return 0;
      for (final f in dir.listSync(recursive: true)) {
        if (f is File) {
          try {
            total += f.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }
}
