import 'dart:io';

import 'package:path/path.dart' as p;

import 'db.dart';

/// 一个可选模型档位
class ModelOption {
  const ModelOption({
    required this.file,
    required this.name,
    required this.sizeMB,
    required this.desc,
    required this.tier,
  });

  final String file;
  final String name;
  final int sizeMB;
  final String desc;
  final String tier; // tiny / fast / balanced / accurate

  String get tierLabel {
    switch (tier) {
      case 'tiny':
        return '应急';
      case 'fast':
        return '速度优先';
      case 'balanced':
        return '平衡';
      case 'accurate':
        return '准确优先';
      default:
        return '';
    }
  }
}

const kAllModels = <ModelOption>[
  ModelOption(
    file: 'ggml-small-q5_1.bin',
    name: 'small',
    sizeMB: 181,
    desc: '44 秒音频约 24 秒转完，中文准确率可用',
    tier: 'fast',
  ),
  ModelOption(
    file: 'ggml-medium-q5_0.bin',
    name: 'medium',
    sizeMB: 514,
    desc: '44 秒音频约 32 秒，准确率略高于 small',
    tier: 'balanced',
  ),
  ModelOption(
    file: 'ggml-large-v3-q5_0.bin',
    name: 'large-v3',
    sizeMB: 1100,
    desc: '准确率最高，无独显时明显偏慢',
    tier: 'accurate',
  ),
  ModelOption(
    file: 'ggml-base-q5_1.bin',
    name: 'base',
    sizeMB: 57,
    desc: '最小最快，错字较多，仅应急使用',
    tier: 'tiny',
  ),
];

/// 模型档位管理：安装检测、选择、硬件推荐
class ModelManager {
  static String get dir => p.join(Db.instance.rootPath, 'models');

  static bool isInstalled(ModelOption m) {
    final f = File(p.join(dir, m.file));
    return f.existsSync() && f.lengthSync() > 10 * 1024 * 1024;
  }

  static List<ModelOption> installed() =>
      kAllModels.where(isInstalled).toList();

  /// 当前选中的模型文件（绝对路径）
  static String? selectedPath() {
    final saved = Db.instance.getSetting('model');
    if (saved != null && saved.isNotEmpty) {
      final f = File(p.join(dir, saved));
      if (f.existsSync() && f.lengthSync() > 10 * 1024 * 1024) return f.path;
    }
    final rec = recommended();
    if (rec == null) return null;
    return p.join(dir, rec.file);
  }

  static String? selectedFile() {
    final path = selectedPath();
    return path == null ? null : p.basename(path);
  }

  static void select(String file) => Db.instance.setSetting('model', file);

  /// 推荐档位：优先已安装的 small（无独显场景速度优先），再依次回退
  static ModelOption? recommended() {
    final order = [
      'ggml-small-q5_1.bin',
      'ggml-medium-q5_0.bin',
      'ggml-base-q5_1.bin',
      'ggml-large-v3-q5_0.bin',
    ];
    for (final f in order) {
      final m = kAllModels.firstWhere((e) => e.file == f);
      if (isInstalled(m)) return m;
    }
    return null;
  }

  /// 硬件摘要（CPU 核心数 + 是否独显），用于设置页说明
  static Future<String> hardwareSummary() async {
    final cores = Platform.numberOfProcessors;
    String gpu = '未检测到独立显卡';
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-CimInstance Win32_VideoController).Name -join ";"',
      ]).timeout(const Duration(seconds: 6));
      final s = (r.stdout as String).toLowerCase();
      if (s.contains('nvidia') || s.contains('geforce') || s.contains('rtx')) {
        gpu = '检测到 NVIDIA 独立显卡';
      } else if (s.contains('radeon') || s.contains('rx ')) {
        gpu = '检测到 AMD 独立显卡';
      }
    } catch (_) {}
    return '$cores 核 CPU · $gpu';
  }
}
