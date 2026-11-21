import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一个被发现的 A2A Agent
class A2aAgent {
  A2aAgent({
    required this.name,
    required this.description,
    required this.version,
    required this.endpoint,
    required this.skills,
    required this.protocolVersion,
  });

  final String name;
  final String description;
  final String version;
  final String endpoint;
  final List<String> skills;
  final String protocolVersion;

  /// 是否 v1.0 风格（PascalCase 方法名 + parts 用 type 字段）
  bool get isV1 {
    final v = protocolVersion.replaceAll('v', '');
    final major = int.tryParse(v.split('.').first) ?? 0;
    return major >= 1;
  }

  String get badge => '$name · $protocolVersion';
}

/// A2A 客户端：自动发现本机 Agent + 发送消息
class A2aClient {
  A2aClient._();

  static final A2aClient instance = A2aClient._();

  final List<A2aAgent> agents = [];

  static const _defaultPorts = <int>[
    9999, 8080, 8081, 8000, 8001, 5000, 3000, 7860, 8888, 9000, 10000,
  ];

  /// 探测单个端口：先试 v1.0 的 agent-card.json，再试 0.3 的 agent.json
  Future<A2aAgent?> probe(int port) async {
    final base = 'http://127.0.0.1:$port';
    for (final entry in const [
      ['/.well-known/agent-card.json', '1.0'],
      ['/.well-known/agent.json', '0.3'],
    ]) {
      final path = entry[0];
      final ver = entry[1];
      try {
        // 1500ms：本机虽快，但 app 刚启动或正在转写时首次握手可能超过 600ms
        final r = await http
            .get(Uri.parse('$base$path'))
            .timeout(const Duration(milliseconds: 1500));
        if (r.statusCode != 200) continue;
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is! Map) continue;

        // endpoint：v1.0 在 supportedInterfaces[].url，0.3 在顶层 url
        var endpoint = (j['url'] as String?) ?? '';
        final ifaces = j['supportedInterfaces'];
        if (ifaces is List && ifaces.isNotEmpty) {
          final first = ifaces.first;
          if (first is Map && first['url'] is String) {
            endpoint = first['url'] as String;
          }
        }
        if (endpoint.isEmpty) endpoint = base;

        // 协议版本：v1.0 在 supportedInterfaces[].protocolVersion，0.3 在顶层 protocolVersion
        var proto = (j['protocolVersion'] as String?) ?? ver;
        if (ifaces is List && ifaces.isNotEmpty) {
          final first = ifaces.first;
          if (first is Map && first['protocolVersion'] is String) {
            proto = first['protocolVersion'] as String;
          }
        }

        final skills = <String>[];
        final rawSkills = j['skills'];
        if (rawSkills is List) {
          for (final s in rawSkills) {
            if (s is Map) {
              final n = s['name'] ?? s['id'];
              if (n is String) skills.add(n);
            }
          }
        }

        return A2aAgent(
          name: (j['name'] as String?) ?? '未命名 Agent',
          description: (j['description'] as String?) ?? '',
          version: (j['version'] as String?) ?? '',
          endpoint: endpoint,
          skills: skills,
          protocolVersion: proto,
        );
      } catch (_) {
        // 端口没开或不是 Agent，继续
      }
    }
    return null;
  }

  /// 探测一个完整地址（支持用户手动填写的远端 Agent）
  Future<A2aAgent?> probeUrl(String url) async {
    var base = url.trim();
    if (base.isEmpty) return null;
    if (!base.startsWith('http')) base = 'http://$base';
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    for (final entry in const [
      ['/.well-known/agent-card.json', '1.0'],
      ['/.well-known/agent.json', '0.3'],
    ]) {
      try {
        final r = await http
            .get(Uri.parse('$base${entry[0]}'))
            .timeout(const Duration(milliseconds: 1200));
        if (r.statusCode != 200) continue;
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is! Map) continue;

        var endpoint = (j['url'] as String?) ?? base;
        final ifaces = j['supportedInterfaces'];
        if (ifaces is List && ifaces.isNotEmpty) {
          final first = ifaces.first;
          if (first is Map && first['url'] is String) {
            endpoint = first['url'] as String;
          }
        }
        var proto = (j['protocolVersion'] as String?) ?? entry[1];
        if (ifaces is List && ifaces.isNotEmpty) {
          final first = ifaces.first;
          if (first is Map && first['protocolVersion'] is String) {
            proto = first['protocolVersion'] as String;
          }
        }
        final skills = <String>[];
        final rawSkills = j['skills'];
        if (rawSkills is List) {
          for (final s in rawSkills) {
            if (s is Map && s['name'] is String) skills.add(s['name'] as String);
          }
        }
        return A2aAgent(
          name: (j['name'] as String?) ?? '未命名 Agent',
          description: (j['description'] as String?) ?? '',
          version: (j['version'] as String?) ?? '',
          endpoint: endpoint,
          skills: skills,
          protocolVersion: proto,
        );
      } catch (_) {}
    }
    return null;
  }

  /// 扫描本机端口 + 用户手动添加的地址
  Future<List<A2aAgent>> discover({
    List<int>? ports,
    List<String> extraUrls = const [],
  }) async {
    final list = ports ?? _defaultPorts;
    final found = <A2aAgent>[];
    try {
      final results = await Future.wait(list.map(probe));
      found.addAll(results.whereType<A2aAgent>());
    } catch (_) {
      // 单个探测异常不影响整体
    }

    for (final url in extraUrls) {
      final a = await probeUrl(url);
      if (a != null && !found.any((e) => e.endpoint == a.endpoint)) {
        found.add(a);
      }
    }

    // 扫描失败但之前发现过：保留缓存，避免界面突然变成"未连接"
    if (found.isEmpty && agents.isNotEmpty) return agents;

    agents
      ..clear()
      ..addAll(found);
    return agents;
  }

  /// 发送一条消息，返回 Agent 回复文本
  ///
  /// 兼容 v1.0（SendMessage / parts[].text）与 0.3（message/send / parts[].{type,text}）
  Future<String> send({
    required A2aAgent agent,
    required String text,
    String? contextId,
  }) async {
    final messageId = _uuid();
    final Map<String, dynamic> payload;

    if (agent.isV1) {
      payload = {
        'jsonrpc': '2.0',
        'id': messageId,
        'method': 'SendMessage',
        'params': {
          'message': {
            'role': 'ROLE_USER',
            'messageId': messageId,
            if (contextId != null) 'contextId': contextId,
            'parts': [
              {'text': text},
            ],
          },
        },
      };
    } else {
      payload = {
        'jsonrpc': '2.0',
        'id': messageId,
        'method': 'message/send',
        'params': {
          'message': {
            'role': 'user',
            'messageId': messageId,
            if (contextId != null) 'contextId': contextId,
            'parts': [
              {'type': 'text', 'text': text},
            ],
          },
        },
      };
    }

    final r = await http
        .post(
          Uri.parse(agent.endpoint),
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(minutes: 3));

    if (r.statusCode != 200) {
      throw 'Agent 返回 HTTP ${r.statusCode}';
    }

    final data = jsonDecode(utf8.decode(r.bodyBytes));
    if (data is Map && data['error'] != null) {
      final err = data['error'];
      throw 'Agent 错误：${err is Map ? (err['message'] ?? err.toString()) : err}';
    }

    final texts = <String>[];
    _collectTexts(data, texts);
    if (texts.isEmpty) {
      throw 'Agent 没有返回可读文本';
    }
    return texts.join('\n').trim();
  }

  /// 流式发送：逐块产出增量文本；调用方取消订阅即可中止（内部会关闭连接）
  ///
  /// 兼容两种常见形态：
  /// 1. SSE（`text/event-stream`，每行 `data: {...}`）—— 主流 A2A 实现
  /// 2. 一次性 JSON 响应 —— 退化为单块产出
  Stream<String> sendStream({
    required A2aAgent agent,
    required String text,
    String? contextId,
  }) {
    final messageId = _uuid();
    final method = agent.isV1 ? 'SendStreamingMessage' : 'message/stream';

    final Map<String, dynamic> payload;
    if (agent.isV1) {
      payload = {
        'jsonrpc': '2.0',
        'id': messageId,
        'method': method,
        'params': {
          'message': {
            'role': 'ROLE_USER',
            'messageId': messageId,
            if (contextId != null) 'contextId': contextId,
            'parts': [
              {'text': text},
            ],
          },
        },
      };
    } else {
      payload = {
        'jsonrpc': '2.0',
        'id': messageId,
        'method': method,
        'params': {
          'message': {
            'role': 'user',
            'messageId': messageId,
            if (contextId != null) 'contextId': contextId,
            'parts': [
              {'type': 'text', 'text': text},
            ],
          },
        },
      };
    }

    late StreamController<String> ctrl;
    http.Client? client;

    Future<void> run() async {
      try {
        client = http.Client();
        final req = http.Request('POST', Uri.parse(agent.endpoint))
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream, application/json',
          })
          ..body = jsonEncode(payload);

        final resp = await client!.send(req);
        if (resp.statusCode != 200) {
          ctrl.addError('Agent 返回 HTTP ${resp.statusCode}');
          return;
        }

        final isSse = (resp.headers['content-type'] ?? '').contains('event-stream');
        final buf = StringBuffer();
        var snapshot = ''; // 已产出的累计文本

        void handleEvent(String raw) {
          final t = extractAllText(raw);
          if (t.isEmpty) return;
          if (t.startsWith(snapshot)) {
            // 全量快照：只产出新增部分
            final delta = t.substring(snapshot.length);
            snapshot = t;
            if (delta.isNotEmpty) ctrl.add(delta);
          } else {
            // 增量片段：直接追加
            snapshot += t;
            ctrl.add(t);
          }
        }

        await for (final chunk in resp.stream.transform(utf8.decoder)) {
          buf.write(chunk);
          if (isSse) {
            // 按行切分，只处理 data: 开头的行
            var content = buf.toString();
            while (true) {
              final idx = content.indexOf('\n');
              if (idx < 0) break;
              final line = content.substring(0, idx).trim();
              content = content.substring(idx + 1);
              if (line.startsWith('data:')) {
                final data = line.substring(5).trim();
                if (data.isNotEmpty && data != '[DONE]') handleEvent(data);
              }
            }
            buf
              ..clear()
              ..write(content);
          }
        }

        if (!isSse) {
          // 非流式：整体解析一次
          final all = buf.toString().trim();
          if (all.isNotEmpty) handleEvent(all);
        } else if (buf.toString().trim().isNotEmpty) {
          final rest = buf.toString().trim();
          if (rest.startsWith('data:')) {
            final data = rest.substring(5).trim();
            if (data.isNotEmpty && data != '[DONE]') handleEvent(data);
          }
        }

        if (snapshot.isEmpty) {
          ctrl.addError('Agent 没有返回可读文本');
        }
      } catch (e) {
        if (!ctrl.isClosed) ctrl.addError('$e');
      } finally {
        client?.close();
        if (!ctrl.isClosed) await ctrl.close();
      }
    }

    ctrl = StreamController<String>(
      onListen: () => run(),
      onCancel: () {
        // 用户点「停止」：断开连接，Agent 侧会收到取消
        client?.close();
      },
    );
    return ctrl.stream;
  }

  /// 从一段 JSON 文本里取出所有 text 字段拼接
  String extractAllText(String raw) {
    try {
      final data = jsonDecode(raw);
      final texts = <String>[];
      _collectTexts(data, texts);
      return texts.join();
    } catch (_) {
      return '';
    }
  }

  /// 递归收集响应里所有 text 字段（兼容两种结构，避免硬编码路径）
  void _collectTexts(Object? node, List<String> out) {
    if (node is Map) {
      final t = node['text'];
      if (t is String && t.trim().isNotEmpty) out.add(t);
      for (final v in node.values) {
        if (v is Map || v is List) _collectTexts(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        if (v is Map || v is List) _collectTexts(v, out);
      }
    }
  }

  String _uuid() {
    final r = DateTime.now().microsecondsSinceEpoch;
    final rnd = List.generate(8, (i) => ((r >> (i * 3)) % 36).toRadixString(36)).join();
    return 'msg-$r-$rnd';
  }
}

/// 把若干条内容拼成语料（发给 Agent 的正文）
String buildCorpus(List<Map<String, String>> items) {
  final b = StringBuffer();
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    b.writeln('【内容 ${i + 1}】${it['title'] ?? ''}（${it['time'] ?? ''}）');
    b.writeln(it['text'] ?? '');
    b.writeln('');
  }
  return b.toString();
}
