import 'package:flutter/material.dart';

import 'db.dart';
import 'theme.dart';

// ============================================================
// 手机端通用组件：与原型 prototype/index.html 的 .picon / .pchip /
// .pmulti / .pconfirm 等保持一致
// ============================================================

/// 按下时轻微缩放的点击容器（原型 .pcard:active）
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.986,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final long = widget.onLongPress;
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) {
        if (widget.onTap != null || long != null) _set(true);
      },
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: long == null
          ? null
          : () {
              _set(false);
              long();
            },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// 手机端图标按钮（原型 .picon：34×34，圆角 10）
class MobileIconBtn extends StatelessWidget {
  const MobileIconBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.active = false,
    this.size = 18,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.9,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: active ? Palette.goldBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          size: size,
          color: color ?? (active ? Palette.gold : const Color(0xFF5E7378)),
        ),
      ),
    );
  }
}

/// 筛选胶囊（原型 .pchip）
class MobilePill extends StatelessWidget {
  const MobilePill({
    super.key,
    required this.label,
    this.active = false,
    this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active ? Palette.ink : Colors.white,
          border: Border.all(color: active ? Palette.ink : Palette.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: active ? const Color(0xFFF3EEE4) : Palette.muted,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// 通用按钮（手机端尺寸更大，label 居中）
class MobileBtn extends StatelessWidget {
  const MobileBtn({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
    this.solid = false,
    this.height = 38,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;
  final bool solid;
  final double height;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color border;
    Color fg;
    if (solid || primary) {
      if (danger) {
        bg = Palette.red;
        border = Palette.red;
        fg = Colors.white;
      } else {
        bg = Palette.ink;
        border = Palette.ink;
        fg = const Color(0xFFF3EEE4);
      }
    } else if (danger) {
      bg = Colors.white;
      border = Palette.redLine;
      fg = Palette.red;
    } else {
      bg = Colors.white;
      border = Palette.line;
      fg = Palette.text;
    }
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        height: height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
            ],
            Text(label, style: TextStyle(fontSize: 13, color: fg)),
          ],
        ),
      ),
    );
  }
}

/// 深色批量操作条上的小按钮（原型 .pmini）
class DarkMiniBtn extends StatelessWidget {
  const DarkMiniBtn({
    super.key,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: danger
              ? Palette.red.withOpacity(0.92)
              : Colors.white.withOpacity(0.13),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: danger
                ? Colors.white.withOpacity(0.14)
                : Colors.white.withOpacity(0.08),
          ),
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: danger ? Colors.white : const Color(0xFFEAF0F0),
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮动批量操作条（原型 .pmulti / .mcbar）
class MobileActionBar extends StatelessWidget {
  const MobileActionBar({
    super.key,
    required this.label,
    required this.actions,
    this.margin = const EdgeInsets.fromLTRB(12, 0, 12, 10),
  });

  final String label;
  final List<Widget> actions;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: const Color(0xF70B2226),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Palette.ink.withOpacity(0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 7),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFBFD0D3)),
            ),
          ),
          // 一排平分整个宽度，按钮不再是小小一颗
          Row(
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(child: actions[i]),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 空态提示
class MobileEmptyHint extends StatelessWidget {
  const MobileEmptyHint({
    super.key,
    required this.icon,
    required this.title,
    this.desc,
  });

  final IconData icon;
  final String title;
  final String? desc;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: Palette.muted2),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13.5, color: Palette.muted2)),
            if (desc != null) ...[
              const SizedBox(height: 8),
              Text(desc!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12, color: Palette.muted2, height: 1.8)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 二次确认（原型 .pconfirm）
Future<bool> showMobileConfirm(
  BuildContext context, {
  required String title,
  required String desc,
  String okLabel = '删除',
  String cancelLabel = '取消',
  bool danger = true,
}) async {
  final r = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x730B2226),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(desc,
                style: const TextStyle(
                    fontSize: 12.5, color: Palette.muted, height: 1.7)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: MobileBtn(
                    label: cancelLabel,
                    onTap: () => Navigator.pop(ctx, false),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: MobileBtn(
                    label: okLabel,
                    solid: true,
                    danger: danger,
                    onTap: () => Navigator.pop(ctx, true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return r == true;
}

/// 输入框弹窗（重命名 / 添加标签 / 编辑正文 等）
Future<String?> showMobileInput(
  BuildContext context, {
  required String title,
  String desc = '',
  String initial = '',
  String hint = '',
  int maxLines = 1,
  String okLabel = '保存',
}) async {
  final ctrl = TextEditingController(text: initial);
  ctrl.selection =
      TextSelection(baseOffset: 0, extentOffset: initial.length);
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x730B2226),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(desc,
                  style: const TextStyle(
                      fontSize: 11.5, color: Palette.muted2, height: 1.6)),
            ],
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              decoration: BoxDecoration(
                color: Palette.paper,
                border: Border.all(color: Palette.line),
                borderRadius: BorderRadius.circular(10),
              ),
              child: TextField(
                controller: ctrl,
                autofocus: true,
                minLines: maxLines == 1 ? 1 : 3,
                maxLines: maxLines,
                style: const TextStyle(fontSize: 14, height: 1.6),
                cursorColor: Palette.gold,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: hint,
                  hintStyle:
                      const TextStyle(fontSize: 14, color: Palette.muted2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: MobileBtn(
                      label: '取消', onTap: () => Navigator.pop(ctx, false)),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: MobileBtn(
                      label: okLabel,
                      solid: true,
                      onTap: () => Navigator.pop(ctx, true)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  final v = ctrl.text.trim();
  ctrl.dispose();
  if (ok != true) return null;
  return v;
}

/// 搜索命中高亮（原型 .snip mark）
Widget highlightedText(
  String text,
  String kw, {
  TextStyle? style,
  int? maxLines,
  TextAlign? textAlign,
}) {
  final base = style ?? const TextStyle(fontSize: 12, color: Color(0xFF6C7E82));
  final k = kw.trim();
  if (k.isEmpty) {
    return Text(text,
        style: base, maxLines: maxLines, overflow: TextOverflow.ellipsis);
  }
  final lower = text.toLowerCase();
  final lk = k.toLowerCase();
  final spans = <TextSpan>[];
  var i = 0;
  while (true) {
    final idx = lower.indexOf(lk, i);
    if (idx < 0) {
      if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
      break;
    }
    if (idx > i) spans.add(TextSpan(text: text.substring(i, idx)));
    if (idx + k.length > text.length) break;
    spans.add(TextSpan(
      text: text.substring(idx, idx + k.length),
      style: const TextStyle(
        color: Palette.goldDeep,
        backgroundColor: Color(0xFFF7E5BE),
      ),
    ));
    i = idx + k.length;
  }
  return Text.rich(
    TextSpan(children: spans, style: base),
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    textAlign: textAlign,
  );
}

/// 列表卡片的摘要文字：音频取转写首段，笔记取正文
String mobileSnip(Item it) {
  if (!it.isAudio) return (it.body ?? '').trim();
  final segs = Db.instance.segments(it.id);
  if (segs.isEmpty) {
    switch (it.transcriptStatus) {
      case 'queued':
        return '排队中，等待转写…';
      case 'running':
        return '正在转写…';
      case 'failed':
        return '转写失败，可在详情页重试';
      default:
        return '等待转写';
    }
  }
  final buf = StringBuffer();
  for (final s in segs) {
    final t = (s['text'] as String? ?? '').trim();
    if (t.isEmpty) continue;
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(t);
    if (buf.length > 120) break;
  }
  return buf.toString();
}

/// 底部抽屉的统一外观
BoxDecoration get mobileSheetDecoration => const BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    );

/// 抽屉顶部的小把手
class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFE3DDD2),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
