import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'ai_client.dart';
import 'audio_convert.dart';
import 'db.dart';
import 'models.dart';

/// 转写进度（供 UI 显示）
class TranscribeProgress {
  TranscribeProgress({
    required this.itemId,
    required this.title,
    this.percent = 0,
    this.phase = '排队中',
    this.queueLeft = 0,
  });

  final String itemId;
  final String title;
  final int percent;
  final String phase;
  final int queueLeft;

  TranscribeProgress copyWith({int? percent, String? phase, int? queueLeft}) =>
      TranscribeProgress(
        itemId: itemId,
        title: title,
        percent: percent ?? this.percent,
        phase: phase ?? this.phase,
        queueLeft: queueLeft ?? this.queueLeft,
      );
}

/// 本地转写服务：串行队列 + whisper-cli 子进程
///
/// 技术取舍：用子进程调 whisper-cli，而不是 Dart FFI 绑定 whisper.dll。
/// 原因：whisper.cpp 的 C 结构体字段随版本变化，FFI 内存布局极易错位导致崩溃；
/// 子进程只需解析 JSON，稳定性高一个量级。代价是多一次进程启动开销（约 1 秒）。
class Transcriber {
  Transcriber._();

  static final Transcriber instance = Transcriber._();

  final ValueNotifier<TranscribeProgress?> progress = ValueNotifier(null);

  final List<String> _queue = [];
  bool _busy = false;

  bool get hasEngine => enginePath() != null;
  bool get hasModel => Db.instance.findModel() != null;
  bool get ready => hasEngine && hasModel;

  /// 查找 whisper-cli.exe：安装目录 → 用户数据目录 → 开发机兜底路径
  String? enginePath() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(exeDir, 'engine', 'whisper-cli.exe'),
      p.join(Db.instance.rootPath, 'engine', 'whisper-cli.exe'),
      r'E:\vibe coding\computer ASR\spikes\s2-whisper\bin\Release\whisper-cli.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 查找 ffmpeg（非 wav 文件需要先转码）。统一走 AudioConvert，避免两处路径不一致
  String? ffmpegPath() => AudioConvert.ffmpegPath();

  void enqueue(String itemId) {
    if (_queue.contains(itemId)) return;
    _queue.add(itemId);
    _pump();
  }

  /// 换模型或想重来时使用：清空旧结果后重新排队
  void retranscribe(String itemId) {
    Db.instance.clearSegments(itemId);
    _queue.remove(itemId);
    enqueue(itemId);
  }

  void enqueueAll(List<String> ids) {
    for (final id in ids) {
      if (!_queue.contains(id)) _queue.add(id);
    }
    _pump();
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    while (_queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      try {
        await _run(id);
      } catch (e) {
        Db.instance.setStatus(id, 'failed');
      }
    }
    _busy = false;
    progress.value = null;
  }

  Future<void> _run(String itemId) async {
    final item = Db.instance.byId(itemId);
    if (item == null || item.audioPath == null) return;

    final engine = enginePath();
    final model = ModelManager.selectedPath();
    final title = item.title;

    if (engine == null || model == null) {
      Db.instance.setStatus(itemId, 'failed');
      progress.value = TranscribeProgress(
        itemId: itemId,
        title: title,
        phase: engine == null ? '缺少转写引擎' : '缺少模型文件',
      );
      return;
    }

    Db.instance.setStatus(itemId, 'running');
    progress.value = TranscribeProgress(
      itemId: itemId,
      title: title,
      phase: '准备音频',
      queueLeft: _queue.length,
    );

    // 1. 统一转成 16k 单声道 wav
    var wavPath = item.audioPath!;
    if (!wavPath.toLowerCase().endsWith('.wav')) {
      final ff = ffmpegPath();
      if (ff == null) {
        Db.instance.setStatus(itemId, 'failed');
        progress.value = TranscribeProgress(
          itemId: itemId,
          title: title,
          phase: '缺少 ffmpeg，无法处理非 wav 文件',
        );
        return;
      }
      final out = p.join(Db.instance.rootPath, 'tmp', '$itemId.16k.wav');
      Directory(p.dirname(out)).createSync(recursive: true);
      final r = await Process.run(
        ff,
        ['-y', '-i', wavPath, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', out],
      );
      if (r.exitCode != 0 || !File(out).existsSync()) {
        Db.instance.setStatus(itemId, 'failed');
        progress.value = TranscribeProgress(
          itemId: itemId,
          title: title,
          phase: '音频解码失败',
        );
        return;
      }
      wavPath = out;
    }

    // 2. 调 whisper-cli
    final tmpBase = p.join(Db.instance.rootPath, 'tmp', itemId);
    Directory(p.dirname(tmpBase)).createSync(recursive: true);
    final jsonFile = '$tmpBase.json';
    if (File(jsonFile).existsSync()) File(jsonFile).deleteSync();

    final args = <String>[
      '-m', model,
      '-f', wavPath,
      '-l', 'zh',
      '--prompt', '以下是普通话的句子，请用简体中文输出。',
      '-t', '8',
      '-oj',
      '-of', tmpBase,
    ];

    progress.value = TranscribeProgress(
      itemId: itemId,
      title: title,
      percent: 0,
      phase: '转写中',
      queueLeft: _queue.length,
    );

    final proc = await Process.start(
      engine,
      args,
      workingDirectory: p.dirname(engine),
      runInShell: false,
    );

    // 解析 stderr 里的进度（whisper.cpp 输出 progress = N%）
    final re = RegExp(r'progress\s*=\s*(\d+)%');
    proc.stderr.transform(utf8.decoder).listen((chunk) {
      final m = re.firstMatch(chunk);
      final cur = progress.value;
      if (m != null && cur != null && cur.itemId == itemId) {
        progress.value = cur.copyWith(percent: int.tryParse(m.group(1) ?? '') ?? 0);
      }
    });
    // 消费 stdout 避免管道堵塞
    proc.stdout.drain<void>();

    await proc.exitCode;

    // 3. 解析结果
    if (!File(jsonFile).existsSync()) {
      Db.instance.setStatus(itemId, 'failed');
      progress.value = TranscribeProgress(
        itemId: itemId,
        title: title,
        phase: '没有生成转写结果',
      );
      return;
    }

    final raw = await File(jsonFile).readAsString();
    var segs = parseWhisperJson(raw);
    if (segs.isEmpty) {
      Db.instance.setStatus(itemId, 'failed');
      progress.value = TranscribeProgress(
        itemId: itemId,
        title: title,
        phase: '未识别到语音内容',
      );
      return;
    }

    // 声纹分离：把每个转写分段归到具体说话人
    if (diarizerPath() != null && diarizeModelsDir() != null) {
      progress.value = TranscribeProgress(
        itemId: itemId,
        title: title,
        percent: 100,
        phase: '区分说话人',
        queueLeft: _queue.length,
      );
      segs = await _applyDiarization(itemId, wavPath, segs);
    }

    Db.instance.saveSegments(itemId, segs);

    // 清理临时文件
    try {
      File(jsonFile).deleteSync();
    } catch (_) {}
    if (wavPath != item.audioPath) {
      try {
        File(wavPath).deleteSync();
      } catch (_) {}
    }

    final speakerCount = segs
        .map((s) => s['speaker'])
        .whereType<String>()
        .toSet()
        .length;
    progress.value = TranscribeProgress(
      itemId: itemId,
      title: title,
      percent: 100,
      phase: speakerCount > 1
          ? '完成（${segs.length} 段 · $speakerCount 人）'
          : '完成（${segs.length} 段）',
      queueLeft: _queue.length,
    );

    // AI 自动命名 + 自动打标签：服务可用时顺手做，失败不影响转写结果
    if (AiClient.load().ready) {
      if (AiClient.autoNameEnabled) {
        unawaited(AiClient.autoNameItem(itemId).catchError((_) => ''));
      }
      if (AiClient.autoTagEnabled) {
        unawaited(AiClient.tagItem(itemId).catchError((_) => <String>[]));
      }
    }
  }

  /// 直接转写一个音频文件（不经过队列，供局域网调用）
  Future<List<Map<String, Object?>>> transcribeFile(String audioPath) async {
    final engine = enginePath();
    final model = ModelManager.selectedPath();
    if (engine == null) throw '缺少转写引擎';
    if (model == null) throw '缺少模型文件';

    var wavPath = audioPath;
    var cleanup = <String>[];

    if (!wavPath.toLowerCase().endsWith('.wav')) {
      final ff = ffmpegPath();
      if (ff == null) throw '缺少 ffmpeg，无法处理该格式';
      final out = p.join(Db.instance.rootPath, 'tmp',
          'conv_${DateTime.now().microsecondsSinceEpoch}.wav');
      Directory(p.dirname(out)).createSync(recursive: true);
      final r = await Process.run(
        ff,
        ['-y', '-i', wavPath, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', out],
      );
      if (r.exitCode != 0 || !File(out).existsSync()) throw '音频解码失败';
      wavPath = out;
      cleanup.add(out);
    }

    final tmpBase = p.join(Db.instance.rootPath, 'tmp',
        'lan_${DateTime.now().microsecondsSinceEpoch}');
    final jsonFile = File('$tmpBase.json');
    try {
      final r = await Process.run(
        engine,
        [
          '-m', model,
          '-f', wavPath,
          '-l', 'zh',
          '--prompt', '以下是普通话的句子，请用简体中文输出。',
          '-t', '8',
          '-oj',
          '-of', tmpBase,
        ],
        workingDirectory: p.dirname(engine),
      );
      if (r.exitCode != 0 || !jsonFile.existsSync()) throw '转写失败';

      final segs = parseWhisperJson(await jsonFile.readAsString());
      if (segs.isEmpty) throw '未识别到语音内容';

      // 有模型就顺带做说话人区分
      if (diarizerPath() != null && diarizeModelsDir() != null) {
        return await _applyDiarization('lan', wavPath, segs);
      }
      return segs;
    } finally {
      try {
        if (jsonFile.existsSync()) jsonFile.deleteSync();
      } catch (_) {}
      for (final f in cleanup) {
        try {
          if (File(f).existsSync()) File(f).deleteSync();
        } catch (_) {}
      }
    }
  }

  /// 声纹分离可执行文件
  String? diarizerPath() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final cands = <String>[
      p.join(exeDir, 'engine', 'diarizer', 'diarizer.exe'),
      p.join(Db.instance.rootPath, 'engine', 'diarizer', 'diarizer.exe'),
      r'E:\vibe coding\computer ASR\tools\dist\diarizer\diarizer.exe',
    ];
    for (final c in cands) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 声纹模型目录
  String? diarizeModelsDir() {
    final cands = <String>[
      p.join(Db.instance.rootPath, 'models', 'diarization'),
      r'E:\dev\models\diarization',
    ];
    const emb = '3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx';
    for (final c in cands) {
      if (File(p.join(c, emb)).existsSync()) return c;
    }
    return null;
  }

  /// 按时间重叠率把说话人标签贴到每个转写分段上
  Future<List<Map<String, Object?>>> _applyDiarization(
    String itemId,
    String wavPath,
    List<Map<String, Object?>> segs,
  ) async {
    final exe = diarizerPath();
    final models = diarizeModelsDir();
    if (exe == null || models == null) return segs;

    final out = p.join(Db.instance.rootPath, 'tmp', '$itemId.diar.json');
    Directory(p.dirname(out)).createSync(recursive: true);

    try {
      final r = await Process.run(
        exe,
        ['--wav', wavPath, '--models', models, '--out', out, '--threshold', '0.5'],
      ).timeout(const Duration(minutes: 15));
      if (r.exitCode != 0 || !File(out).existsSync()) return segs;

      final data = jsonDecode(File(out).readAsStringSync());
      final list = (data is Map && data['segments'] is List)
          ? data['segments'] as List
          : const [];
      if (list.isEmpty) return segs;

      // 转成毫秒区间
      final spans = <List<int>>[];
      for (final e in list) {
        if (e is! Map) continue;
        final s = ((e['start'] as num?)?.toDouble() ?? 0) * 1000;
        final t = ((e['end'] as num?)?.toDouble() ?? 0) * 1000;
        spans.add([s.round(), t.round(), (e['speaker'] as num?)?.toInt() ?? 0]);
      }

      for (final seg in segs) {
        final s = (seg['start'] as int?) ?? 0;
        final t = (seg['end'] as int?) ?? s;
        var bestSpk = -1;
        var bestOverlap = 0;
        for (final sp in spans) {
          final left = s > sp[0] ? s : sp[0];
          final right = t < sp[1] ? t : sp[1];
          final ov = right - left;
          if (ov > bestOverlap) {
            bestOverlap = ov;
            bestSpk = sp[2];
          }
        }
        if (bestSpk >= 0 && bestOverlap > 0) {
          seg['speaker'] = '说话人 ${bestSpk + 1}';
        }
      }
    } catch (_) {
      // 声纹失败不影响转写结果
    } finally {
      try {
        if (File(out).existsSync()) File(out).deleteSync();
      } catch (_) {}
    }
    return segs;
  }
}

/// 解析 whisper-cli 的 -oj 输出
List<Map<String, Object?>> parseWhisperJson(String raw) {
  final out = <Map<String, Object?>>[];
  try {
    final data = jsonDecode(raw);
    final list = (data is Map && data['transcription'] is List)
        ? data['transcription'] as List
        : const [];
    for (final e in list) {
      if (e is! Map) continue;
      final offsets = e['offsets'];
      final text = (e['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) continue;
      int from = 0;
      int to = 0;
      if (offsets is Map) {
        from = (offsets['from'] as num?)?.toInt() ?? 0;
        to = (offsets['to'] as num?)?.toInt() ?? from;
      }
      out.add({'start': from, 'end': to, 'text': text, 'speaker': null});
    }
  } catch (_) {
    // 解析失败返回空，由调用方标记失败
  }
  return out;
}
