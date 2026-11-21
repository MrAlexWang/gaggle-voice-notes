import 'dart:async';

import 'package:record/record.dart';

/// 一次录音的落盘结果
class RecordStart {
  const RecordStart(this.path, this.aac);

  final String path;

  /// true = 直接录的 AAC/m4a；false = 录的 WAV（停录后需要转码归档）
  final bool aac;
}

/// 麦克风录音封装。
///
/// 归档格式按 PRD D14 统一为 **AAC / m4a**：
/// - 优先让 `record` 直出 AAC（Android 原生支持；Windows 视声卡而定）
/// - 直出失败时退回 WAV，停录后由 `AudioConvert.toM4a` 转码归档
class RecorderService {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _sub;
  final StreamController<double> _levelCtrl = StreamController<double>.broadcast();

  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  Stream<double> get levels => _levelCtrl.stream;
  Duration get elapsed => _elapsed;
  bool get isRecording => _ticker != null;

  Future<bool> ensurePermission() async {
    try {
      return await _rec.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// 开始录音。
  ///
  /// [basePathNoExt] 不带扩展名（如 `.../rec_1737...`），实际扩展名由采用
  /// 的编码决定。返回 null 表示没能开始（权限或设备问题）。
  Future<RecordStart?> start(
    String basePathNoExt, {
    bool preferAac = true,
  }) async {
    if (!await ensurePermission()) return null;

    if (preferAac) {
      final path = '$basePathNoExt.m4a';
      if (await _tryStart(path, AudioEncoder.aacLc)) {
        return RecordStart(path, true);
      }
    }
    final path = '$basePathNoExt.wav';
    if (await _tryStart(path, AudioEncoder.wav)) {
      return RecordStart(path, false);
    }
    return null;
  }

  Future<bool> _tryStart(String path, AudioEncoder encoder) async {
    try {
      await _rec.start(
        RecordConfig(
          encoder: encoder,
          sampleRate: 44100,
          numChannels: 1,
          // 仅 AAC 需要码率；128kbps 对应 PRD D14
          bitRate: encoder == AudioEncoder.aacLc ? 128000 : 128000,
        ),
        path: path,
      );
    } catch (_) {
      // 某些声卡/机型不支持该编码：清理后交给上层重试另一种格式
      try {
        await _rec.cancel();
      } catch (_) {}
      return false;
    }

    _sub = _rec
        .onAmplitudeChanged(const Duration(milliseconds: 180))
        .listen((amp) {
      // current 为 dBFS（负值），映射到 0~1
      final v = ((amp.current + 55) / 55).clamp(0.0, 1.0);
      _levelCtrl.add(v.toDouble());
    });
    _elapsed = Duration.zero;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsed += const Duration(seconds: 1);
    });
    return true;
  }

  Future<void> pause() async {
    try {
      await _rec.pause();
      _ticker?.cancel();
      _ticker = null;
    } catch (_) {}
  }

  Future<void> resume() async {
    try {
      await _rec.resume();
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        _elapsed += const Duration(seconds: 1);
      });
    } catch (_) {}
  }

  /// 停止并返回最终文件路径
  Future<String?> stop() async {
    await _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _ticker = null;
    try {
      return await _rec.stop();
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _ticker?.cancel();
    await _rec.dispose();
    await _levelCtrl.close();
  }
}
