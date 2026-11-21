import 'dart:io';

/// 音频内容哈希（FNV-1a 64 位），用于判重。
/// 只要求"同内容必同值、不同内容基本不同"，不需要密码学强度。
String audioFileHash(String path, {int maxBytes = 200 * 1024 * 1024}) {
  const int offset = 0xcbf29ce484222325;
  const int prime = 0x100000001b3;
  var hash = offset;
  try {
    final f = File(path);
    if (!f.existsSync()) return '';
    final raf = f.openSync();
    try {
      var read = 0;
      while (read < maxBytes) {
        final chunk = raf.readSync(1024 * 1024);
        if (chunk.isEmpty) break;
        read += chunk.length;
        for (final b in chunk) {
          hash = (hash ^ b) * prime; // Dart int 溢出即环绕，等价于 64 位无符号
        }
      }
    } finally {
      raf.closeSync();
    }
    final len = f.lengthSync();
    hash = (hash ^ len) * prime;
    // 拆成高低 32 位输出，保证是无符号十六进制（Dart 的 int 是 64 位有符号）
    final hi = ((hash >> 32) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final lo = (hash & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$hi$lo';
  } catch (_) {
    return '';
  }
}
