import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 数据目录位置：存在 %LOCALAPPDATA%\Gaggle\location.json，
/// 必须在打开数据库之前读取，所以不能用 DB 里的 setting。
class DataLocation {
  /// 刚改完、尚未重启生效的新目录；界面靠它实时刷新显示
  static final ValueNotifier<String?> pendingPath = ValueNotifier<String?>(null);

  /// 界面应该显示的目录（优先显示刚改好的新目录）
  static String get displayPath => pendingPath.value ?? read() ?? '';


  static String get _configFile {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.current.path;
    return p.join(base, 'Gaggle', 'location.json');
  }

  /// 自定义目录（不存在或无效则返回 null）
  static String? read() {
    try {
      final f = File(_configFile);
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      final v = (j is Map) ? j['path'] as String? : null;
      if (v == null || v.isEmpty) return null;
      if (!Directory(v).existsSync()) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  static bool write(String path) {
    try {
      final f = File(_configFile);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'path': path}));
      return true;
    } catch (_) {
      return false;
    }
  }

  static void clear() {
    try {
      final f = File(_configFile);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 递归复制目录（用于迁移数据）
  static Future<int> copyDir(String from, String to) async {
    var count = 0;
    final src = Directory(from);
    if (!src.existsSync()) return 0;
    await for (final entity in src.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: from);
      final target = p.join(to, rel);
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        final tf = File(target);
        tf.parent.createSync(recursive: true);
        await entity.copy(tf.path);
        count++;
      }
    }
    return count;
  }

  /// 目录占用空间（字节）
  static int sizeOf(String dir) {
    var total = 0;
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      for (final f in d.listSync(recursive: true, followLinks: false)) {
        if (f is File) {
          try {
            total += f.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 开机自启（写 HKCU 的 Run 键，无需管理员）
class AutoStart {
  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _valueName = 'Gaggle';

  static Future<bool> enabled() async {
    try {
      final r = await Process.run('reg', ['query', _runKey, '/v', _valueName]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setEnabled(bool on) async {
    try {
      if (on) {
        final exe = Platform.resolvedExecutable;
        final r = await Process.run('reg', [
          'add', _runKey, '/v', _valueName, '/t', 'REG_SZ',
          '/d', '"$exe"', '/f',
        ]);
        return r.exitCode == 0;
      }
      final r = await Process.run('reg', ['delete', _runKey, '/v', _valueName, '/f']);
      // 值本来就不存在时 reg 返回 1，也算成功
      return r.exitCode == 0 || (r.stderr as String).contains('unable');
    } catch (_) {
      return false;
    }
  }
}
