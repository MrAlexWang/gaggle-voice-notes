import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'db.dart';

/// 一个可选的离线转写模型档位
class AsrModel {
  const AsrModel({
    required this.id,
    required this.name,
    required this.desc,
    required this.sizeMB,
    required this.repo,
    required this.modelFile,
    required this.isSenseVoice,
  });

  final String id;
  final String name;
  final String desc;
  final int sizeMB;

  /// HuggingFace 仓库
  final String repo;

  /// 仓库里的模型文件名
  final String modelFile;

  /// true = SenseVoice 系列；false = Paraformer（中文专用）
  final bool isSenseVoice;
}

/// 可选档位（与手机端转写设置里一一对应）
const List<AsrModel> kAsrModels = <AsrModel>[
  AsrModel(
    id: 'sensevoice-int8',
    name: 'SenseVoice-Small int8',
    desc: '默认 · 中文 / 英文 / 日文 / 韩文 / 粤语，速度最快',
    sizeMB: 228,
    repo: 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    modelFile: 'model.int8.onnx',
    isSenseVoice: true,
  ),
  AsrModel(
    id: 'paraformer-zh-int8',
    name: 'Paraformer-zh int8',
    desc: '纯中文优化，标点更自然，适合会议 / 访谈',
    sizeMB: 217,
    repo: 'csukuangfj/sherpa-onnx-paraformer-zh-2024-03-09',
    modelFile: 'model.int8.onnx',
    isSenseVoice: false,
  ),
  AsrModel(
    id: 'sensevoice-fp32',
    name: 'SenseVoice-Small fp32',
    desc: '高精度版本，体积大、速度慢一些，适合性能好的手机',
    sizeMB: 894,
    repo: 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    modelFile: 'model.onnx',
    isSenseVoice: true,
  ),
];

/// 手机端本地转写（sherpa-onnx 离线推理，不联网）
///
/// 每个档位单独放一个目录：`models/asr/<id>/`，内含模型文件 + `tokens.txt`。
/// 可以一键从镜像下载，也可以从本地已有的模型文件导入（离线机器用）。
/// 推理跑在独立 isolate 里，模型只加载一次，不阻塞 UI。
class SenseVoice {
  SenseVoice._();

  static final SenseVoice instance = SenseVoice._();

  static const int targetRate = 16000;
  static const String tokensFileName = 'tokens.txt';
  static const String _settingKey = 'asr_model';

  /// 下载镜像（国内优先）
  static const List<String> _mirrors = [
    'https://hf-mirror.com',
    'https://huggingface.co',
  ];

  /// 下载/准备进度 0~1；-1 表示空闲
  final ValueNotifier<double> prepareProgress = ValueNotifier<double>(-1);

  /// 下载/准备过程中的说明文字
  final ValueNotifier<String> prepareHint = ValueNotifier<String>('');

  _AsrWorker? _worker;
  bool _downloading = false;

  bool get downloading => _downloading;

  bool _migrated = false;

  /// 老版本把模型放在 models/sensevoice/，这里懒迁移到新的分档目录
  void _ensureMigrated() {
    if (_migrated) return;
    _migrated = true;
    try {
      final oldDir =
          Directory(p.join(Db.instance.rootPath, 'models', 'sensevoice'));
      if (!oldDir.existsSync()) return;
      final target = kAsrModels.first; // SenseVoice-Small int8
      if (File(modelPathOf(target)).existsSync()) return;
      Directory(dirOf(target)).createSync(recursive: true);
      final oldModel = File(p.join(oldDir.path, target.modelFile));
      final oldTokens = File(p.join(oldDir.path, tokensFileName));
      if (oldModel.existsSync()) oldModel.renameSync(modelPathOf(target));
      if (oldTokens.existsSync()) oldTokens.renameSync(tokensPathOf(target));
    } catch (_) {}
  }

  /// 当前选中的档位
  AsrModel get current {
    _ensureMigrated();
    final id = Db.instance.getSetting(_settingKey);
    for (final m in kAsrModels) {
      if (m.id == id) return m;
    }
    return kAsrModels.first;
  }

  void select(AsrModel m) {
    Db.instance.setSetting(_settingKey, m.id);
    _resetWorker();
  }

  String dirOf(AsrModel m) =>
      p.join(Db.instance.rootPath, 'models', 'asr', m.id);
  String modelPathOf(AsrModel m) => p.join(dirOf(m), m.modelFile);
  String tokensPathOf(AsrModel m) => p.join(dirOf(m), tokensFileName);

  bool isDownloaded(AsrModel m) =>
      File(modelPathOf(m)).existsSync() &&
      File(tokensPathOf(m)).existsSync();

  String get dir => dirOf(current);
  String get modelPath => modelPathOf(current);
  String get tokensPath => tokensPathOf(current);

  /// 当前档位是否就绪
  bool get ready => isDownloaded(current);

  /// 当前档位占用的体积（MB）
  int get sizeMB {
    var total = 0;
    for (final f in [modelPath, tokensPath]) {
      final file = File(f);
      if (file.existsSync()) total += file.lengthSync();
    }
    return (total / 1024 / 1024).round();
  }

  // ============================================================
  // 模型获取
  // ============================================================

  /// 从镜像下载指定档位（先 tokens.txt，再模型文件）
  Future<void> download([AsrModel? target]) async {
    if (_downloading) return;
    final m = target ?? current;
    _downloading = true;
    prepareProgress.value = 0;
    prepareHint.value = '准备下载 ${m.name}…';
    try {
      Directory(dirOf(m)).createSync(recursive: true);
      await _fetch(m, tokensFileName, 0.0, 0.02);
      await _fetch(m, m.modelFile, 0.02, 1.0);
      prepareHint.value = '${m.name} 已就绪';
      prepareProgress.value = 1;
    } finally {
      _downloading = false;
      prepareProgress.value = -1;
    }
  }

  Future<void> _fetch(AsrModel m, String name, double from, double to) async {
    Object? lastErr;
    for (final mirror in _mirrors) {
      final url = '$mirror/${m.repo}/resolve/main/$name';
      final tmp = File(p.join(dirOf(m), '$name.part'));
      try {
        prepareHint.value = '正在下载 $name…';
        final client = http.Client();
        try {
          final req = http.Request('GET', Uri.parse(url));
          final resp =
              await client.send(req).timeout(const Duration(seconds: 30));
          if (resp.statusCode != 200) {
            throw 'HTTP ${resp.statusCode}';
          }
          final total = resp.contentLength ?? 0;
          final sink = tmp.openWrite();
          var got = 0;
          await for (final chunk in resp.stream) {
            sink.add(chunk);
            got += chunk.length;
            if (total > 0) {
              prepareProgress.value =
                  from + (to - from) * (got / total).clamp(0.0, 1.0);
            }
          }
          await sink.close();
          if (total > 0 && got < total) throw '下载不完整（$got/$total）';
          final target = File(p.join(dirOf(m), name));
          if (target.existsSync()) target.deleteSync();
          tmp.renameSync(target.path);
          return;
        } finally {
          client.close();
        }
      } catch (e) {
        lastErr = e;
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
      }
    }
    throw '下载失败：$lastErr';
  }

  /// 从本地已有文件导入（离线机器 / 已下载过模型），导入到指定档位目录
  Future<void> installFiles({
    required String modelSrc,
    required String tokensSrc,
    AsrModel? target,
  }) async {
    final m = File(modelSrc);
    final t = File(tokensSrc);
    if (!m.existsSync()) throw '找不到模型文件';
    if (!t.existsSync()) throw '找不到 tokens.txt';
    final model = target ?? current;
    Directory(dirOf(model)).createSync(recursive: true);
    await _resetWorker();
    final dst = File(modelPathOf(model));
    if (dst.existsSync()) dst.deleteSync();
    await m.copy(modelPathOf(model));
    await t.copy(tokensPathOf(model));
    prepareHint.value = '${model.name} 已就绪';
  }

  /// 删除指定档位已下载的模型，释放空间
  Future<void> remove([AsrModel? target]) async {
    final model = target ?? current;
    await _resetWorker();
    try {
      final d = Directory(dirOf(model));
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    prepareHint.value = '';
  }

  // ============================================================
  // 转写
  // ============================================================

  /// 转写一个条目并写库；成功返回 null，失败返回错误文案。
  /// 每识别完一段就落库一次，界面能边转边显示，不用等全部算完。
  Future<String?> transcribeItem(
    String itemId, {
    void Function()? onPartial,
  }) async {
    final it = Db.instance.byId(itemId);
    final path = it?.audioPath;
    if (it == null || path == null) return '找不到录音文件';
    if (!ready) return '还没安装 SenseVoice-Small 模型';
    Db.instance.setStatus(itemId, 'running');
    try {
      final segs = await transcribe(path, onPartial: (partial) {
        Db.instance.saveSegments(itemId, partial);
        onPartial?.call();
      });
      if (segs.isEmpty) {
        Db.instance.setStatus(itemId, 'failed');
        return '没有识别到语音内容';
      }
      Db.instance.saveSegments(itemId, segs);
      return null;
    } catch (e) {
      Db.instance.setStatus(itemId, 'failed');
      return '$e';
    }
  }

  /// 转写一个 wav 文件，返回与电脑端一致的段落结构
  Future<List<Map<String, Object?>>> transcribe(
    String wavPath, {
    void Function(List<Map<String, Object?>>)? onPartial,
  }) async {
    if (!ready) throw '还没安装 ${current.name} 模型';
    final worker = _worker ??= await _AsrWorker.spawn(
      modelPath,
      tokensPath,
      current.isSenseVoice,
    );
    final res = await worker.transcribe(
      wavPath,
      onPartial: onPartial == null
          ? null
          : (partial) => onPartial(_normalize(partial)),
    ).timeout(const Duration(minutes: 20));
    if (res is! List) throw '本地转写返回异常';
    return _normalize(res);
  }

  static List<Map<String, Object?>> _normalize(List? raw) {
    if (raw == null) return const [];
    return raw
        .whereType<Map>()
        .map((e) => <String, Object?>{
              'start': (e['start'] as num?)?.toInt() ?? 0,
              'end': (e['end'] as num?)?.toInt() ?? 0,
              'text': (e['text'] as String?) ?? '',
              'speaker': e['speaker'],
            })
        .toList();
  }

  Future<void> _resetWorker() async {
    final w = _worker;
    _worker = null;
    await w?.close();
  }

  Future<void> dispose() => _resetWorker();
}

// ============================================================
// 独立 isolate：加载模型并串行处理转写请求
// ============================================================
class _AsrWorker {
  _AsrWorker._(this._send, this._rx);

  final SendPort _send;
  final ReceivePort _rx;
  bool _closed = false;

  static Future<_AsrWorker> spawn(
    String model,
    String tokens,
    bool isSenseVoice,
  ) async {
    final rx = ReceivePort();
    await Isolate.spawn(
      _asrMain,
      <Object?>[rx.sendPort, model, tokens, isSenseVoice],
    );
    final first = await rx.first.timeout(const Duration(minutes: 3));
    if (first is! Map) {
      rx.close();
      throw '本地引擎启动失败';
    }
    final err = first['error'];
    if (err != null) {
      rx.close();
      throw '$err';
    }
    final w = _AsrWorker._(first['port'] as SendPort, rx);
    return w;
  }

  Future<Object?> transcribe(
    String wavPath, {
    void Function(List)? onPartial,
  }) {
    if (_closed) throw '本地引擎已关闭';
    final reply = ReceivePort();
    final c = Completer<Object?>();
    reply.listen((m) {
      if (m is Map && m['partial'] != null) {
        onPartial?.call(m['partial'] as List);
        return;
      }
      reply.close();
      if (!c.isCompleted) c.complete(m);
    });
    _send.send(<Object?>[reply.sendPort, wavPath]);
    return c.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _send.send(const <Object?>['.quit']);
    _rx.close();
  }
}

void _asrMain(List<Object?> args) async {
  final mainSend = args[0] as SendPort;
  final model = args[1] as String;
  final tokens = args[2] as String;
  final isSenseVoice = (args.length > 3 ? args[3] : true) as bool;

  final rx = ReceivePort();
  sherpa.OfflineRecognizer? rec;
  Object? err;
  try {
    sherpa.initBindings();
    rec = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: isSenseVoice
              ? sherpa.OfflineSenseVoiceModelConfig(
                  model: model,
                  language: 'zh',
                  useInverseTextNormalization: true,
                )
              : const sherpa.OfflineSenseVoiceModelConfig(),
          paraformer: isSenseVoice
              ? const sherpa.OfflineParaformerModelConfig()
              : sherpa.OfflineParaformerModelConfig(model: model),
          tokens: tokens,
          // 用满 CPU（手机上一般是 8 核），转写速度差别很明显
          numThreads: math.max(2, math.min(6, Platform.numberOfProcessors)),
          debug: false,
        ),
      ),
    );
  } catch (e) {
    err = '$e';
  }
  mainSend.send(<String, Object?>{'port': rx.sendPort, 'error': err});
  if (rec == null) {
    rx.close();
    return;
  }

  await for (final msg in rx) {
    if (msg is! List || msg.length < 2) continue;
    if (msg[0] == '.quit') break;
    final reply = msg[0] as SendPort;
    final path = msg[1] as String;
    try {
      final segs = _transcribeWave(
        rec,
        path,
        onPartial: (partial) => reply.send(<String, Object?>{'partial': partial}),
      );
      reply.send(<String, Object?>{'ok': segs});
    } catch (e) {
      reply.send(<String, Object?>{'error': '$e'});
    }
  }
  rec.free();
  rx.close();
}

/// 同步转写：读 wav → 重采样到 16k → 按静音切成 4~15 秒片段识别 → 按标点分句
///
/// 关键：只把「有声音」的片段送进模型（跳过静音），比整段定长切块快很多。
List<Map<String, Object?>> _transcribeWave(
  sherpa.OfflineRecognizer rec,
  String wavPath, {
  void Function(List<Map<String, Object?>> partial)? onPartial,
}) {
  final wave = sherpa.readWave(wavPath);
  if (wave.samples.isEmpty || wave.sampleRate <= 0) {
    throw '读取音频失败（本机转写只支持 wav）';
  }
  final samples = _resample(wave.samples, wave.sampleRate, SenseVoice.targetRate);

  final out = <Map<String, Object?>>[];
  for (final span in _speechSpans(samples, SenseVoice.targetRate)) {
    final part = Float32List.sublistView(samples, span[0], span[1]);
    final stream = rec.createStream();
    try {
      stream.acceptWaveform(
        samples: part,
        sampleRate: SenseVoice.targetRate,
      );
      rec.decode(stream);
      final text = rec.getResult(stream).text.trim();
      if (text.isEmpty) continue;
      final startMs = span[0] * 1000 ~/ SenseVoice.targetRate;
      final endMs = span[1] * 1000 ~/ SenseVoice.targetRate;
      out.addAll(_splitSentences(text, startMs, endMs));
      // 每段识别完就回传一次，界面可以边转边显示
      onPartial?.call(out);
    } finally {
      stream.free();
    }
  }
  return out;
}

/// 基于帧能量的静音切分，返回 [start, end) 采样点区间（16k）
///
/// 规则参考录音笔记类 App 的常见做法：
/// - 30ms 一帧算 RMS，阈值取 90 分位能量的 30%（并有下限）
/// - 间隔小于 0.35s 的小停顿合并，避免把一句话切碎
/// - 过短的 0.33s 以下片段丢掉，超过 15s 的片段等分
/// - 两侧各留 0.15s，避免切掉字头字尾
List<List<int>> _speechSpans(Float32List s, int rate) {
  const frame = 480; // 30ms @ 16k
  final frames = s.length ~/ frame;
  if (frames == 0) return [
    [0, s.length]
  ];

  final rms = Float64List(frames);
  for (var i = 0; i < frames; i++) {
    var sum = 0.0;
    final base = i * frame;
    for (var j = 0; j < frame; j++) {
      final v = s[base + j];
      sum += v * v;
    }
    rms[i] = math.sqrt(sum / frame);
  }

  final sorted = List<double>.from(rms)..sort();
  final p90 = sorted[(frames * 0.9).floor().clamp(0, frames - 1)];
  final threshold = math.max(0.008, p90 * 0.3);
  final maxGapFrames = (0.35 * rate / frame).round();

  final spans = <List<int>>[];
  int? start;
  var lastSpeech = -1;
  for (var i = 0; i < frames; i++) {
    if (rms[i] < threshold) continue;
    if (start == null) {
      start = i;
    } else if (i - lastSpeech > maxGapFrames) {
      spans.add([start * frame, (lastSpeech + 1) * frame]);
      start = i;
    }
    lastSpeech = i;
  }
  if (start != null) spans.add([start * frame, (lastSpeech + 1) * frame]);

  final maxLen = 15 * rate;
  final minLen = rate ~/ 3;
  final pad = (0.15 * rate).round();
  final out = <List<int>>[];
  for (final sp in spans) {
    var a = math.max(0, sp[0] - pad);
    var b = math.min(s.length, sp[1] + pad);
    if (b - a < minLen) continue;
    while (b - a > maxLen) {
      out.add([a, a + maxLen]);
      a += maxLen;
    }
    if (b - a > 0) out.add([a, b]);
  }
  if (out.isEmpty) {
    out.add([0, math.min(s.length, maxLen)]);
  }
  return out;
}

/// 线性重采样；下采样前先做一次滑动平均，压一下混叠
Float32List _resample(Float32List input, int from, int to) {
  if (from == to || input.isEmpty) return input;
  var src = input;
  final ratio = from / to;
  if (ratio > 1.5) {
    final win = ratio.round().clamp(2, 8);
    final smoothed = Float32List(input.length);
    var acc = 0.0;
    for (var i = 0; i < input.length; i++) {
      acc += input[i];
      if (i >= win) acc -= input[i - win];
      smoothed[i] = acc / math.min(i + 1, win);
    }
    src = smoothed;
  }
  final n = (src.length * to / from).round();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final pos = i * ratio;
    final i0 = pos.floor();
    final i1 = math.min(i0 + 1, src.length - 1);
    final frac = pos - i0;
    out[i] = src[i0] * (1 - frac) + src[i1] * frac;
  }
  return out;
}

/// 按中文标点把一段文字切成句子，并按字数比例分配时间轴
List<Map<String, Object?>> _splitSentences(String text, int startMs, int endMs) {
  final parts = <String>[];
  final buf = StringBuffer();
  for (final r in text.runes) {
    final ch = String.fromCharCode(r);
    buf.write(ch);
    if ('。！？!?；;'.contains(ch)) {
      final s = buf.toString().trim();
      if (s.isNotEmpty) parts.add(s);
      buf.clear();
    }
  }
  final rest = buf.toString().trim();
  if (rest.isNotEmpty) parts.add(rest);

  // 过长的句子再按 80 字切
  final lines = <String>[];
  for (final s in parts) {
    if (s.length <= 80) {
      lines.add(s);
      continue;
    }
    for (var i = 0; i < s.length; i += 80) {
      lines.add(s.substring(i, math.min(i + 80, s.length)));
    }
  }
  if (lines.isEmpty) return const [];

  final totalChars = lines.fold<int>(0, (a, b) => a + b.length);
  final out = <Map<String, Object?>>[];
  var acc = 0;
  for (final line in lines) {
    final s = startMs + (endMs - startMs) * acc ~/ totalChars;
    acc += line.length;
    final e = startMs + (endMs - startMs) * acc ~/ totalChars;
    out.add({'start': s, 'end': e, 'text': line, 'speaker': null});
  }
  return out;
}
