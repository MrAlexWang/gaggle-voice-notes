import 'package:flutter/material.dart';

/// 与原型 prototype/index.html 的 CSS 变量完全一致
class Palette {
  static const ink = Color(0xFF0B2226);
  static const ink2 = Color(0xFF123037);
  static const ink3 = Color(0xFF1B4149);
  static const inkHover = Color(0xFF16414A);

  static const paper = Color(0xFFF7F4EF);
  static const card = Color(0xFFFFFFFF);
  static const line = Color(0xFFE6E0D6);
  static const line2 = Color(0xFFF0EBE2);

  static const text = Color(0xFF16262B);
  static const textBody = Color(0xFF22333A);
  static const muted = Color(0xFF7C8B8E);
  static const muted2 = Color(0xFF9AA8AA);

  static const gold = Color(0xFFC0913F);
  static const goldSoft = Color(0xFFEBD8B6);
  static const goldBg = Color(0xFFFBF3E3);
  static const goldDeep = Color(0xFFA6762A);

  static const green = Color(0xFF2E7D62);
  static const greenBg = Color(0xFFE8F3EE);
  static const greenLine = Color(0xFFCDE6DB);

  static const red = Color(0xFFB0453C);
  static const redBg = Color(0xFFFBEDEB);
  static const redLine = Color(0xFFEDD8D4);

  static const blue = Color(0xFF3A6EA5);
  static const blueBg = Color(0xFFEAF1F8);
  static const blueLine = Color(0xFFD3E1F0);

  static const watch = Color(0xFF6E4E9E);
  static const watchBg = Color(0xFFF3EDF8);

  static const textIc = Color(0xFF5C7B82);
  static const textIcBg = Color(0xFFEEF2F4);
  static const hoverBg = Color(0xFFF4F0E8);
  static const listBg = Color(0xFFFBF9F5);
  static const dotGrey = Color(0xFFCBD3D4);
  static const scrollThumb = Color(0xFFDED8CD);

  /// 字体：原型使用 系统字体栈（微软雅黑 / 苹方）
  static const fontFamily = 'Microsoft YaHei';
  static const serifFamily = 'SimSun';
  static const monoFamily = 'Consolas';

  /// Android/iOS 上没有 SimSun / Consolas，用通用族名兜底，
  /// 保证手机端的衬线标题与等宽计时不变样
  static const serifFallback = ['serif', 'Noto Serif CJK SC'];
  static const monoFallback = ['monospace'];
}

String fmtDurMs(int? ms) {
  if (ms == null || ms <= 0) return '--:--';
  final s = ms ~/ 1000;
  final m = s ~/ 60;
  final sec = s % 60;
  return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

String fmtClock(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  if (that == today) return '今天 $hm';
  if (that == today.subtract(const Duration(days: 1))) return '昨天 $hm';
  return '${d.month}-${d.day} $hm';
}

/// 年月日时分秒（录音默认标题用）
String fmtStamp(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String fmtSec(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
