import 'dart:io';

import 'package:path/path.dart' as p;

import 'db.dart';

/// 音频转码工具：录制产物按 PRD D14 统一归档为 AAC / m4a。
///
/// 分工：
/// - 桌面端：`record` 直出 AAC 失败时录 WAV，停录后由本类转 m4a
/// - Android：`record` 原生支持 AAC 直出，不需要转码（端上没有 ffmpeg）
/// - 转写侧：whisper / SenseVoice 需要 16k 单声道 PCM，由调用方各自解码
class AudioConvert {
  AudioConvert._();

  /// 查找 ffmpeg：安装目录 → 数据目录 → 开发机兜底
  static String? ffmpegPath() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(exeDir, 'engine', 'ffmpeg.exe'),
      p.join(Db.instance.rootPath, 'engine', 'ffmpeg.exe'),
      r'C:\Users\Administrator\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static bool get canTranscode => ffmpegPath() != null;

  /// 把任意音频转成 AAC/m4a（44.1kHz 单声道 128kbps）。
  /// 成功返回新文件路径；失败返回 null（调用方应保留原文件）。
  static Future<String?> toM4a(String srcPath, {int bitrateK = 128}) async {
    if (srcPath.toLowerCase().endsWith('.m4a')) return srcPath;
    final ff = ffmpegPath();
    if (ff == null) return null;

    final dot = srcPath.lastIndexOf('.');
    final out = dot > 0 ? '${srcPath.substring(0, dot)}.m4a' : '$srcPath.m4a';
    if (File(out).existsSync()) {
      try {
        File(out).deleteSync();
      } catch (_) {}
    }

    try {
      final r = await Process.run(ff, [
        '-y',
        '-i', srcPath,
        '-vn', // 丢弃视频轨（导入视频时只留音轨）
        '-ac', '1',
        '-ar', '44100',
        '-c:a', 'aac',
        '-b:a', '${bitrateK}k',
        out,
      ]);
      if (r.exitCode != 0) return null;
      final f = File(out);
      // 转码后过小的文件视为失败，避免把空文件当成品
      if (!f.existsSync() || f.lengthSync() < 1024) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 转成 16kHz 单声道 PCM wav（喂给 whisper / SenseVoice 用）。
  /// 成功返回 outPath。
  static Future<String?> to16kWav(String srcPath, String outPath) async {
    final ff = ffmpegPath();
    if (ff == null) return null;
    Directory(p.dirname(outPath)).createSync(recursive: true);
    try {
      final r = await Process.run(ff, [
        '-y',
        '-i', srcPath,
        '-ar', '16000',
        '-ac', '1',
        '-c:a', 'pcm_s16le',
        outPath,
      ]);
      if (r.exitCode != 0 || !File(outPath).existsSync()) return null;
      return outPath;
    } catch (_) {
      return null;
    }
  }
}
