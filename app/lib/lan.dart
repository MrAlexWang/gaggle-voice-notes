import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'a2a.dart';
import 'ai_client.dart';
import 'audio_convert.dart';
import 'audio_hash.dart';
import 'db.dart';
import 'transcriber.dart';

const int kHttpPort = 47825;
const int kUdpPort = 47821;
const String kSvc = 'gaggle';

// ============================================================
// 电脑端：局域网服务（供手机调用转写与 Agent）
// ============================================================
class LanServer {
  LanServer._();

  static final LanServer instance = LanServer._();

  HttpServer? _http;
  RawDatagramSocket? _udp;
  bool get isRunning => _http != null;

  /// 手机端改动数据（上传录音等）后回调，让电脑界面立刻刷新
  void Function()? onItemsChanged;

  Future<void> start() async {
    if (_http != null) return;
    try {
      await _refreshIp();
      final http = await HttpServer.bind(InternetAddress.anyIPv4, kHttpPort);
      _http = http;
      http.listen(_handle, onError: (_) {});

      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kUdpPort);
      _udp = udp;
      udp.broadcastEnabled = true;
      udp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = udp.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true);
        if (!msg.contains(kSvc) || !msg.contains('discover')) return;
        final ip = _localIp();
        final resp = jsonEncode({
          'svc': kSvc,
          'role': 'pc',
          'ip': ip,
          'port': kHttpPort,
          'name': Platform.localHostname,
        });
        try {
          udp.send(utf8.encode(resp), dg.address, dg.port);
        } catch (_) {}
      });
    } catch (_) {
      // 端口被占用等情况：静默失败，不影响主链路
    }
  }

  void stop() {
    _http?.close(force: true);
    _http = null;
    _udp?.close();
    _udp = null;
  }

  String _cachedIp = '127.0.0.1';

  /// 本机在局域网中的 IPv4（启动时刷新一次）
  Future<void> _refreshIp() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && a.address.startsWith('192.168')) {
            _cachedIp = a.address;
            return;
          }
        }
      }
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.address.startsWith('169.254')) {
            _cachedIp = a.address;
            return;
          }
        }
      }
    } catch (_) {}
  }

  String _localIp() => _cachedIp;

  String get localAddress => _cachedIp;

  Future<void> _handle(HttpRequest req) async {
    // 手机与本机同源局域网，放开 CORS 与鉴权（内网工具，PRD 允许）
    req.response.headers.add('Access-Control-Allow-Origin', '*');
    req.response.headers.add('Access-Control-Allow-Headers', '*');
    req.response.headers.add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');

    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    try {
      switch (req.uri.path) {
        case '/ping':
          await _json(req, {
            'svc': kSvc,
            'role': 'pc',
            'name': Platform.localHostname,
            'ip': _localIp(),
            'port': kHttpPort,
            // 手机端据此提示「电脑端智能体没配 Key / 没启动」
            'agent': await _agentStatus(),
            // 手机端对话实际走电脑端的 AI 服务，这里把它的状态一并带回去
            'ai': _aiStatus(),
            // 电脑端能否解码 m4a：手机据此决定录音存 AAC 还是 WAV
            'ffmpeg': AudioConvert.canTranscode,
          });
          return;
        case '/agents':
          var list = A2aClient.instance.agents;
          if (list.isEmpty) {
            final manual = Db.instance.getSetting('a2a_manual') ?? '';
            list = await A2aClient.instance.discover(
              extraUrls: manual.isEmpty ? const [] : [manual],
            );
          }
          await _json(req, {
            'agents': list
                .map((a) => {
                      'name': a.name,
                      'version': a.version,
                      'protocolVersion': a.protocolVersion,
                      'endpoint': a.endpoint,
                      'skills': a.skills,
                    })
                .toList(),
          });
          return;
        case '/probe':
          // 诊断用：逐端口探测，返回是否命中
          final results = <Map<String, Object?>>[];
          for (final port in const [9999, 8080, 8000, 5000, 3000]) {
            final a = await A2aClient.instance.probe(port);
            results.add({
              'port': port,
              'found': a != null,
              'name': a?.name,
              'error': null,
            });
          }
          await _json(req, {'results': results});
          return;
        case '/transcribe':
          await _transcribe(req);
          return;
        case '/note':
          await _saveNote(req);
          return;
        case '/chat':
          await _relayChat(req);
          return;
        case '/a2a':
          await _relayA2a(req);
          return;
        default:
          req.response.statusCode = 404;
          await req.response.close();
      }
    } catch (e) {
      try {
        req.response.statusCode = 500;
        req.response.write(jsonEncode({'error': '$e'}));
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _json(HttpRequest req, Object data) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    await req.response.close();
  }

  /// 接收手机上传的速记（纯文字），在电脑端建一条笔记
  Future<void> _saveNote(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    var title = '';
    var text = '';
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        title = (j['title'] as String?) ?? '';
        text = (j['body'] as String?) ?? '';
      }
    } catch (_) {}

    if (text.trim().isEmpty) {
      await _json(req, {'ok': false, 'error': '内容为空'});
      return;
    }
    final t = title.trim().isNotEmpty
        ? title.trim()
        : (text.length > 18 ? '${text.substring(0, 18)}…' : text);
    final itemId = Db.instance.insertItem(
      type: 'text',
      title: t,
      body: text,
      charCount: text.length,
      sourceDevice: 'phone',
    );
    onItemsChanged?.call();
    await _json(req, {'ok': true, 'itemId': itemId});
  }

  /// 电脑端 AI 服务状态（手机端据此提示「去配置 AI 服务」）
  Map<String, Object?> _aiStatus() {
    final cfg = AiClient.load();
    return {
      'ready': cfg.ready,
      'provider': cfg.provider,
      'model': cfg.model,
      'baseUrl': cfg.baseUrl,
    };
  }

  /// 手机端对话：直接用电脑端同一套 AI 服务（模型/系统提示词与电脑端一致），
  /// 这样同一个问题在两端的回答是一致的。
  Future<void> _relayChat(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    var text = '';
    try {
      final data = jsonDecode(body);
      if (data is Map) text = (data['text'] as String?) ?? '';
    } catch (_) {}

    final cfg = AiClient.load();
    req.response.statusCode = 200;
    req.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    final sink = req.response;

    if (!cfg.ready) {
      sink.write(
          'data: ${jsonEncode({'error': '电脑端 AI 服务还没配置：请在电脑上打开「设置 → AI 服务」'})}\n\n');
      await sink.close();
      return;
    }

    try {
      await for (final delta in AiClient.chat(prompt: text)) {
        final event = {
          'result': {
            'artifact': {
              'parts': [
                {'type': 'text', 'text': delta}
              ]
            }
          }
        };
        sink.write('data: ${jsonEncode(event)}\n\n');
        await sink.flush();
      }
      sink.write('data: [DONE]\n\n');
    } catch (e) {
      sink.write('data: ${jsonEncode({'error': '$e'})}\n\n');
    }
    await sink.close();
  }

  /// 智能体健康状态（1.5 秒超时，避免 /ping 被拖慢）
  Map<String, Object?>? _agentCache;
  int _agentCacheAt = 0;
  bool _agentProbing = false;

  Future<Map<String, Object?>> _agentStatus() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_agentCache != null && now - _agentCacheAt < 5000) return _agentCache!;
    if (_agentProbing) return _agentCache ?? {'ok': false, 'hasKey': false};

    var endpoint = 'http://127.0.0.1:9999';
    final agents = A2aClient.instance.agents;
    if (agents.isNotEmpty) endpoint = agents.first.endpoint;
    final manual = Db.instance.getSetting('a2a_manual');
    if (agents.isEmpty && manual != null && manual.isNotEmpty) endpoint = manual;

    _agentProbing = true;
    Map<String, Object?> result = {
      'ok': false,
      'hasKey': false,
      'endpoint': endpoint,
      'error': '智能体没启动',
    };
    try {
      var base = endpoint.trim();
      if (!base.startsWith('http')) base = 'http://$base';
      final uri = Uri.parse(base).replace(path: '/health', query: '');
      final r = await http.get(uri).timeout(const Duration(milliseconds: 1500));
      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map) {
          result = {
            'ok': j['ok'] == true,
            'hasKey': j['has_key'] == true,
            'model': j['model'],
            'baseUrl': j['base_url'],
            'endpoint': endpoint,
          };
        }
      }
    } catch (_) {
      // 保持默认（未启动）
    } finally {
      _agentProbing = false;
      _agentCache = result;
      _agentCacheAt = DateTime.now().millisecondsSinceEpoch;
    }
    return result;
  }

  /// 接收手机上传的音频：先在电脑端存成一条录音，再用本机模型转写
  Future<void> _transcribe(HttpRequest req) async {
    final audioDir = Directory(p.join(Db.instance.rootPath, 'audio'));
    if (!audioDir.existsSync()) audioDir.createSync(recursive: true);
    final name = req.headers.value('x-filename') ?? 'upload.wav';
    final ext = p.extension(name).isEmpty ? '.wav' : p.extension(name);
    final now = DateTime.now();
    final target = File(
      p.join(audioDir.path, 'up_${now.millisecondsSinceEpoch}$ext'),
    );

    final sink = target.openWrite();
    try {
      await for (final chunk in req) {
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }

    // 电脑端也留一条记录，手机传上来的录音能在电脑里看到、回放、再转写
    final durMs = int.tryParse(req.headers.value('x-duration-ms') ?? '') ??
        _wavDurationMs(target.path);
    // 内容判重：同一条录音再传一次会命中已有记录，界面上标「重复」
    final hash = audioFileHash(target.path);
    final dupOf = Db.instance.findByAudioHash(hash)?.id;
    final itemId = Db.instance.insertItem(
      type: 'audio',
      title: '手机录音 · ${_stamp(now)}',
      sourceDevice: 'phone',
      durationMs: durMs,
      audioPath: target.path,
      transcriptStatus: 'running',
      audioHash: hash.isEmpty ? null : hash,
      dupOf: dupOf,
    );
    onItemsChanged?.call();

    try {
      final segs = await Transcriber.instance.transcribeFile(target.path);
      if (segs.isEmpty) {
        Db.instance.setStatus(itemId, 'failed');
        await _json(req, {'ok': false, 'itemId': itemId, 'error': '没有识别到语音内容'});
      } else {
        Db.instance.saveSegments(itemId, segs);
        await _json(req, {'ok': true, 'itemId': itemId, 'segments': segs});
      }
    } catch (e) {
      Db.instance.setStatus(itemId, 'failed');
      await _json(req, {'ok': false, 'itemId': itemId, 'error': '$e'});
    } finally {
      onItemsChanged?.call();
    }
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  /// 解析 wav 的 fmt/data 块算时长（毫秒）；不是 wav 返回 null
  static int? _wavDurationMs(String path) {
    try {
      final f = File(path);
      final fileLen = f.lengthSync();
      if (fileLen < 44) return null;
      final raf = f.openSync();
      try {
        final head = raf.readSync(512);
        if (head.length < 12) return null;
        if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF') return null;
        int le32(int at) =>
            head[at] | (head[at + 1] << 8) | (head[at + 2] << 16) | (head[at + 3] << 24);

        var byteRate = 0;
        var dataSize = 0;
        var dataStart = 0;
        var pos = 12;
        while (pos + 8 <= head.length) {
          final id = String.fromCharCodes(head.sublist(pos, pos + 4));
          final size = le32(pos + 4);
          if (id == 'fmt ' && pos + 20 <= head.length) {
            byteRate = le32(pos + 16);
          } else if (id == 'data') {
            dataStart = pos + 8;
            dataSize = size;
            break;
          }
          if (size <= 0) break;
          pos += 8 + size + (size.isOdd ? 1 : 0);
        }
        if (byteRate <= 0) return null;
        // 录音插件可能先把 data 长度写成 0/占位值，用文件长度兜底
        if (dataSize <= 0 || dataStart + dataSize > fileLen) {
          dataSize = fileLen - dataStart;
        }
        if (dataSize <= 0) return null;
        final ms = dataSize * 1000 ~/ byteRate;
        if (ms <= 0 || ms > 12 * 3600 * 1000) return null;
        return ms;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  /// 把手机的对话请求转发给本机 Agent，并把 SSE 透传回去
  Future<void> _relayA2a(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final text = (data['text'] as String?) ?? '';
    final contextId = data['contextId'] as String?;

    // 智能体没响应时立刻回错误，别让手机端一直转圈
    final agentStatus = await _agentStatus();
    if (agentStatus['ok'] != true && agentStatus['error'] != null) {
      await _json(req, {
        'error': '电脑端智能体没响应（${agentStatus['endpoint']}）：'
            '请双击「启动AI助手.bat」启动后再试',
      });
      return;
    }

    var agents = A2aClient.instance.agents;
    if (agents.isEmpty) agents = await A2aClient.instance.discover();
    if (agents.isEmpty) {
      await _json(req, {'error': '本机没有可用的 A2A Agent'});
      return;
    }
    final agent = agents.first;

    req.response.statusCode = 200;
    req.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    final sink = req.response;

    try {
      final stream = A2aClient.instance
          .sendStream(agent: agent, text: text, contextId: contextId)
          .timeout(const Duration(seconds: 90));
      await for (final delta in stream) {
        final event = {
          'result': {
            'artifact': {
              'parts': [
                {'type': 'text', 'text': delta}
              ]
            }
          }
        };
        sink.write('data: ${jsonEncode(event)}\n\n');
        await sink.flush();
      }
      sink.write('data: [DONE]\n\n');
    } catch (e) {
      sink.write('data: ${jsonEncode({'error': '$e'})}\n\n');
    }
    await sink.close();
  }
}

// ============================================================
// 手机端：发现电脑并调用它的能力
// ============================================================
class LanClient {
  LanClient._();

  static final LanClient instance = LanClient._();

  String? _addr; // "192.168.1.5:47825"
  String? _serverName; // 电脑名（来自 /ping），用于「经由 xxx 的 Agent」提示

  /// 电脑端智能体状态（来自 /ping 的 agent 字段）
  Map<String, Object?>? agentStatus;

  /// 电脑端 AI 服务状态（来自 /ping 的 ai 字段）
  Map<String, Object?>? aiStatus;

  String? get targetAddress => _addr;

  String? get serverName => _serverName;

  /// 是否可用；返回 null 表示正常，否则返回要提示给用户的文案
  String? get agentIssue {
    // 手机端对话走电脑端的 AI 服务：先看它是否配置好
    final ai = aiStatus;
    if (ai != null) {
      if (ai['ready'] == true) return null;
      return '电脑端 AI 服务还没配置：请在电脑上打开「设置 → AI 服务」';
    }
    // 旧版本电脑端只上报 agent 状态
    final s = agentStatus;
    if (s == null) return null;
    if (s['ok'] == true) return null;
    if (s['hasKey'] == false && s['error'] == null) {
      return '电脑端智能体还没配置 API Key（改 agent_config.json 或指向本地 Ollama）';
    }
    return '电脑端智能体没启动：请在电脑上运行「启动AI助手.bat」';
  }

  static String _base(String addr) =>
      addr.startsWith('http') ? addr : 'http://$addr';

  /// UDP 广播找电脑，成功后记住地址
  Future<String?> discover({Duration timeout = const Duration(seconds: 3)}) async {
    final saved = Db.instance.getSetting('lan_pc');
    if (saved != null && await ping(saved)) {
      _addr = saved;
      return saved;
    }

    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final completer = Completer<String?>();
      final msg = utf8.encode(jsonEncode({'svc': kSvc, 'discover': true}));

      final sub = sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock!.receive();
        if (dg == null) return;
        final raw = utf8.decode(dg.data, allowMalformed: true);
        if (!raw.contains(kSvc)) return;
        try {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          final ip = j['ip'] as String?;
          final port = j['port'] as int?;
          if (ip != null && port != null && !completer.isCompleted) {
            completer.complete('$ip:$port');
          }
        } catch (_) {}
      });

      // 连续广播几次，避免丢包
      for (var i = 0; i < 3; i++) {
        try {
          sock.send(msg, InternetAddress('255.255.255.255'), kUdpPort);
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 400));
      }

      final found = await completer.future.timeout(timeout, onTimeout: () => null);
      await sub.cancel();
      if (found != null) {
        Db.instance.setSetting('lan_pc', found);
        _addr = found;
      }
      return found;
    } catch (_) {
      return null;
    } finally {
      sock?.close();
    }
  }

  Future<bool> ping(String addr) async {
    try {
      final r = await http
          .get(Uri.parse('${_base(addr)}/ping'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return false;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final ok = j is Map && j['svc'] == kSvc;
      if (ok) {
        _addr = addr;
        final n = j['name'];
        if (n is String && n.isNotEmpty) _serverName = n;
        final a = j['agent'];
        agentStatus = a is Map
            ? a.map((k, v) => MapEntry<String, Object?>('$k', v))
            : null;
        final ai = j['ai'];
        aiStatus = ai is Map
            ? ai.map((k, v) => MapEntry<String, Object?>('$k', v))
            : null;
        // 记住电脑能否解码 m4a：手机据此决定录音存 AAC 还是 WAV
        final ff = j['ffmpeg'];
        if (ff is bool) {
          Db.instance.setSetting('pc_ffmpeg', ff ? '1' : '0');
        }
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 主动刷新连接与智能体状态（发送前调用，避免用到过期的缓存）
  Future<bool> refreshStatus() async {
    final addr = _addr ?? Db.instance.getSetting('lan_pc');
    if (addr != null && addr.isNotEmpty && await ping(addr)) return true;
    return await discover() != null;
  }

  Future<void> _ensure() async {
    if (_addr != null && await ping(_addr!)) return;
    final saved = Db.instance.getSetting('lan_pc');
    if (saved != null && await ping(saved)) {
      _addr = saved;
      return;
    }
    await discover();
  }

  /// 取电脑端可用的 Agent 列表
  Future<List<A2aAgent>> fetchAgents() async {
    try {
      await _ensure();
      if (_addr == null) return [];
      final r = await http
          .get(Uri.parse('${_base(_addr!)}/agents'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return [];
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final list = (j is Map && j['agents'] is List) ? j['agents'] as List : const [];
      return list.whereType<Map>().map((m) {
        return A2aAgent(
          name: (m['name'] as String?) ?? 'Agent',
          description: '',
          version: (m['version'] as String?) ?? '',
          endpoint: (m['endpoint'] as String?) ?? '',
          skills: ((m['skills'] as List?) ?? const []).cast<String>(),
          protocolVersion: (m['protocolVersion'] as String?) ?? '0.3',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// 通过电脑中转与 Agent 对话（流式）
  Stream<String> chatStream({
    required String text,
    String? contextId,
  }) {
    late StreamController<String> ctrl;
    http.Client? client;

    Future<void> run() async {
      try {
        await _ensure();
        if (_addr == null) {
          ctrl.addError('未连接到电脑，请到设置里搜索或填写电脑地址');
          return;
        }
        client = http.Client();
        // 走电脑端同一套 AI 服务，保证与电脑端回答一致
        final req = http.Request('POST', Uri.parse('${_base(_addr!)}/chat'))
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          })
          ..body = jsonEncode({'text': text, 'contextId': contextId});

        final resp = await client!.send(req);
        if (resp.statusCode != 200) {
          ctrl.addError('电脑端返回 HTTP ${resp.statusCode}');
          return;
        }

        final buf = StringBuffer();
        var acc = '';
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
              if (j is Map && j['error'] != null) {
                ctrl.addError('${j['error']}');
                return;
              }
              final t = A2aClient.instance.extractAllText(data);
              if (t.isEmpty) continue;
              if (t.startsWith(acc)) {
                final delta = t.substring(acc.length);
                acc = t;
                if (delta.isNotEmpty) ctrl.add(delta);
              } else {
                acc += t;
                ctrl.add(t);
              }
            } catch (_) {}
          }
          buf
            ..clear()
            ..write(content);
        }
        if (acc.isEmpty) ctrl.addError('电脑端没有返回内容');
      } catch (e) {
        if (!ctrl.isClosed) ctrl.addError('$e');
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

  /// 把一条速记（纯文字）上传到电脑；成功返回 true
  Future<bool> uploadNote({
    required String title,
    required String body,
    int? createdAt,
  }) async {
    try {
      await _ensure();
      if (_addr == null) return false;
      final r = await http
          .post(
            Uri.parse('${_base(_addr!)}/note'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'title': title,
              'body': body,
              'createdAt': createdAt ?? DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return false;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j is Map && j['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 把本地录好的音频上传给电脑转写，返回分段；失败返回 null
  Future<List<Map<String, Object?>>?> uploadTranscribe(
    String filePath, {
    int? durationMs,
  }) async {
    try {
      await _ensure();
      if (_addr == null) return null;
      final f = File(filePath);
      if (!f.existsSync()) return null;

      final uri = Uri.parse('${_base(_addr!)}/transcribe');
      final req = http.MultipartRequest('POST', uri);
      // 用原始字节 + header 传文件名，避免 multipart 兼容问题
      final bytes = await f.readAsBytes();
      final raw = http.Request('POST', uri)
        ..headers['X-Filename'] = p.basename(filePath)
        ..headers['Content-Type'] = 'application/octet-stream'
        ..bodyBytes = bytes;
      if (durationMs != null && durationMs > 0) {
        raw.headers['X-Duration-Ms'] = '$durationMs';
      }

      final client = http.Client();
      try {
        final resp = await client
            .send(raw)
            .timeout(const Duration(minutes: 10));
        final body = await resp.stream.bytesToString();
        if (resp.statusCode != 200) return null;
        final j = jsonDecode(body);
        if (j is Map && j['ok'] == true && j['segments'] is List) {
          return (j['segments'] as List)
              .whereType<Map>()
              .map((e) => <String, Object?>{
                    'start': (e['start'] as num?)?.toInt() ?? 0,
                    'end': (e['end'] as num?)?.toInt() ?? 0,
                    'text': (e['text'] as String?) ?? '',
                    'speaker': e['speaker'],
                  })
              .toList();
        }
      } finally {
        client.close();
        req.finalize().drain<void>();
      }
    } catch (_) {}
    return null;
  }
}
