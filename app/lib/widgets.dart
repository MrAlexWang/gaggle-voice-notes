import 'package:flutter/material.dart';

import 'theme.dart';

/// 带 hover 状态的点击容器（原型里所有可点元素都有 hover 反馈）
class HoverBox extends StatefulWidget {
  const HoverBox({
    super.key,
    required this.onTap,
    required this.builder,
    this.onDoubleTap,
  });

  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final Widget Function(bool hover) builder;

  @override
  State<HoverBox> createState() => _HoverBoxState();
}

class _HoverBoxState extends State<HoverBox> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final doubleTap = widget.onDoubleTap;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: doubleTap,
        child: widget.builder(_hover),
      ),
    );
  }
}

/// 按钮气质：白瓷 / 墨玉 / 朱砂 / 鎏金 / 幽灵 / 深色
enum BtnTone { plain, primary, danger, gold, ghost, dark }

class _BtnStyle {
  const _BtnStyle(this.gradient, this.border, this.fg, this.shadow);

  final List<Color> gradient;
  final Color border;
  final Color fg;
  final List<BoxShadow> shadow;
}

/// 统一质感的桌面按钮
///
/// 质感来源：① 上亮下暗的竖向渐变（受光面）② 1px 描边 + 底边暗线（厚度）
/// ③ 近/远双层阴影（浮起）④ 悬停微微上浮、按下回弹缩放
class QualityButton extends StatefulWidget {
  const QualityButton({
    super.key,
    required this.label,
    required this.onTap,
    this.tone = BtnTone.plain,
    this.icon,
    this.height = 32,
    this.expand = false,
    this.fontSize,
    this.hPad,
    this.radius = 9,
  });

  final String label;
  final VoidCallback? onTap;
  final BtnTone tone;
  final IconData? icon;
  final double height;
  final bool expand;
  final double? fontSize;
  final double? hPad;
  final double radius;

  @override
  State<QualityButton> createState() => _QualityButtonState();
}

class _QualityButtonState extends State<QualityButton> {
  bool _hover = false;
  bool _pressed = false;

  bool get _enabled => widget.onTap != null;

  _BtnStyle _style() {
    final hover = _hover && !_pressed;
    final pressed = _pressed;
    const bevel = Color(0xFFE4DCCD);
    switch (widget.tone) {
      case BtnTone.primary:
        return _BtnStyle(
          pressed
              ? const [Color(0xFF0D272C), Color(0xFF081B1F)]
              : (hover
                  ? const [Color(0xFF1E525C), Color(0xFF13353C)]
                  : const [Color(0xFF194A53), Color(0xFF0C2529)]),
          hover ? const Color(0xFF2E6A75) : const Color(0xFF0F3036),
          const Color(0xFFF3EEE4),
          pressed
              ? const [BoxShadow(color: Color(0x24203B42), blurRadius: 3, offset: Offset(0, 1))]
              : [
                  BoxShadow(
                    color: Palette.ink.withOpacity(hover ? 0.30 : 0.20),
                    blurRadius: hover ? 16 : 10,
                    offset: Offset(0, hover ? 6 : 4),
                  ),
                  const BoxShadow(
                      color: Color(0xFF073034), blurRadius: 0, offset: Offset(0, 1.2)),
                ],
        );
      case BtnTone.danger:
        return _BtnStyle(
          pressed
              ? const [Color(0xFFF5DCD8), Color(0xFFEDCFC9)]
              : (hover
                  ? const [Color(0xFFFFF8F6), Color(0xFFFBE7E3)]
                  : const [Colors.white, Color(0xFFFDF4F2)]),
          hover ? const Color(0xFFE1B9B3) : Palette.redLine,
          Palette.red,
          pressed
              ? const [BoxShadow(color: Color(0x14B0453C), blurRadius: 3, offset: Offset(0, 1))]
              : [
                  BoxShadow(
                    color: Palette.red.withOpacity(hover ? 0.16 : 0.10),
                    blurRadius: hover ? 12 : 7,
                    offset: Offset(0, hover ? 4 : 2),
                  ),
                  const BoxShadow(
                      color: Color(0xFFF0DED9), blurRadius: 0, offset: Offset(0, 1)),
                ],
        );
      case BtnTone.gold:
        return _BtnStyle(
          pressed
              ? const [Color(0xFFC08E38), Color(0xFFA87A2C)]
              : (hover
                  ? const [Color(0xFFE3B45E), Color(0xFFC69239)]
                  : const [Color(0xFFD8A74E), Color(0xFFBB8A33)]),
          hover ? const Color(0xFFB98A33) : const Color(0xFFA97B29),
          const Color(0xFF2A1602),
          pressed
              ? const [BoxShadow(color: Color(0x24B9792F), blurRadius: 3, offset: Offset(0, 1))]
              : [
                  BoxShadow(
                    color: const Color(0xFFB9792F).withOpacity(hover ? 0.38 : 0.26),
                    blurRadius: hover ? 16 : 10,
                    offset: Offset(0, hover ? 5 : 3),
                  ),
                ],
        );
      case BtnTone.ghost:
        return _BtnStyle(
          pressed
              ? const [Color(0xFFEAE4D9), Color(0xFFE4DDD0)]
              : (hover
                  ? const [Color(0xFFF6F2EA), Color(0xFFF1ECE2)]
                  : const [Colors.transparent, Colors.transparent]),
          Colors.transparent,
          hover ? Palette.text : Palette.muted,
          const [],
        );
      case BtnTone.dark:
        return _BtnStyle(
          pressed
              ? const [Color(0x1FFFFFFF), Color(0x14FFFFFF)]
              : (hover
                  ? const [Color(0x33FFFFFF), Color(0x1FFFFFFF)]
                  : const [Color(0x1FFFFFFF), Color(0x12FFFFFF)]),
          Colors.transparent,
          hover ? Colors.white : const Color(0xFFEAF0F0),
          pressed
              ? const []
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(hover ? 0.28 : 0.16),
                    blurRadius: hover ? 10 : 6,
                    offset: Offset(0, hover ? 3 : 2),
                  ),
                ],
        );
      case BtnTone.plain:
        return _BtnStyle(
          pressed
              ? const [Color(0xFFF3EEE5), Color(0xFFEDE7DB)]
              : (hover
                  ? const [Color(0xFFFFFDF9), Color(0xFFFAF6EE)]
                  : const [Colors.white, Color(0xFFFAF7F1)]),
          hover ? const Color(0xFFD5CBBC) : Palette.line,
          Palette.text,
          pressed
              ? const [BoxShadow(color: Color(0x0F0B2226), blurRadius: 3, offset: Offset(0, 1))]
              : [
                  BoxShadow(
                    color: const Color(0xFF0B2226).withOpacity(hover ? 0.13 : 0.07),
                    blurRadius: hover ? 12 : 6,
                    offset: Offset(0, hover ? 4 : 2),
                  ),
                  const BoxShadow(color: bevel, blurRadius: 0, offset: Offset(0, 1)),
                ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _style();
    final fs = widget.fontSize ?? (widget.height <= 26 ? 11.5 : 12.5);
    return MouseRegion(
      cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (_enabled) setState(() => _hover = true);
      },
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.965 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOut,
            height: widget.height,
            width: widget.expand ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: widget.hPad ?? 13),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: s.gradient,
              ),
              border: Border.all(color: s.border),
              borderRadius: BorderRadius.circular(widget.radius),
              boxShadow: s.shadow,
            ),
            child: Row(
              mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment:
                  widget.expand ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                if (widget.icon != null)
                  Icon(widget.icon, size: widget.height <= 26 ? 12 : 14, color: s.fg),
                if (widget.icon != null && widget.label.isNotEmpty)
                  const SizedBox(width: 6),
                if (widget.label.isNotEmpty)
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: fs,
                      color: s.fg,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 通用按钮（白瓷 / 主色 / 危险色），内部走 [QualityButton] 的统一质感
class DialogBtn extends StatelessWidget {
  const DialogBtn({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
    this.icon,
    this.height = 32,
    this.expand = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;
  final IconData? icon;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return QualityButton(
      label: label,
      onTap: onTap,
      icon: icon,
      height: height,
      expand: expand,
      hPad: height <= 26 ? 10 : 13,
      fontSize: height <= 26 ? 11.5 : 12.5,
      tone: primary
          ? BtnTone.primary
          : (danger ? BtnTone.danger : BtnTone.plain),
    );
  }
}

/// 空状态提示
class EmptyHint extends StatelessWidget {
  const EmptyHint({
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: Palette.muted2),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 13.5, color: Palette.muted2)),
          if (desc != null) ...[
            const SizedBox(height: 6),
            Text(desc!,
                style: const TextStyle(fontSize: 11.5, color: Palette.muted2)),
          ],
        ],
      ),
    );
  }
}

/// 来源端徽标：电脑 / 手机 / 手表
class DeviceBadge extends StatelessWidget {
  const DeviceBadge({super.key, required this.device});

  final String device;

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color bg;
    late final Color fg;
    late final IconData icon;
    if (device == 'phone') {
      label = '手机';
      bg = Palette.blueBg;
      fg = Palette.blue;
      icon = Icons.smartphone;
    } else if (device == 'watch') {
      label = '手表';
      bg = Palette.watchBg;
      fg = Palette.watch;
      icon = Icons.watch;
    } else {
      label = '电脑';
      bg = const Color(0xFFF1F2F3);
      fg = const Color(0xFF6C7E82);
      icon = Icons.desktop_windows_outlined;
    }
    return Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 9, color: fg),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10, color: fg, height: 1.5)),
        ],
      ),
    );
  }
}

/// 极简小徽标（已上传 / 重复 等）
class TinyBadge extends StatelessWidget {
  const TinyBadge({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
    this.icon,
  });

  final String label;
  final Color bg;
  final Color fg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 9, color: fg),
            const SizedBox(width: 3),
          ],
          Text(label,
              style: TextStyle(fontSize: 10, color: fg, height: 1.5)),
        ],
      ),
    );
  }
}

/// 「已上传到电脑」
class UploadedBadge extends StatelessWidget {
  const UploadedBadge({super.key});

  @override
  Widget build(BuildContext context) => const TinyBadge(
        label: '已传电脑',
        bg: Palette.greenBg,
        fg: Palette.green,
        icon: Icons.cloud_done_outlined,
      );
}

/// 「还没同步到电脑」
class UnsyncedBadge extends StatelessWidget {
  const UnsyncedBadge({super.key});

  @override
  Widget build(BuildContext context) => const TinyBadge(
        label: '未同步',
        bg: Color(0xFFF1F2F3),
        fg: Color(0xFF8A9A9D),
        icon: Icons.cloud_off_outlined,
      );
}

/// 「重复录音」
class DuplicateBadge extends StatelessWidget {
  const DuplicateBadge({super.key});

  @override
  Widget build(BuildContext context) => const TinyBadge(
        label: '重复',
        bg: Palette.redBg,
        fg: Palette.red,
        icon: Icons.content_copy,
      );
}

/// 转写状态徽标
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color bg;
    late final Color fg;
    switch (status) {
      case 'done':
        label = '已转写';
        bg = Palette.greenBg;
        fg = Palette.green;
        break;
      case 'running':
        label = '转写中';
        bg = Palette.goldBg;
        fg = Palette.goldDeep;
        break;
      case 'failed':
        label = '失败';
        bg = Palette.redBg;
        fg = Palette.red;
        break;
      case 'none':
        return const SizedBox.shrink();
      default:
        label = '待转写';
        bg = const Color(0xFFF0F1F2);
        fg = const Color(0xFF839295);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: TextStyle(fontSize: 10.5, color: fg, height: 1.5)),
    );
  }
}

/// 多选勾选框
class CheckSquare extends StatelessWidget {
  const CheckSquare({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? Palette.ink : Colors.white,
        border: Border.all(
          color: checked ? Palette.ink : const Color(0xFFCFC7B9),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(5),
      ),
      child: checked
          ? const Icon(Icons.check, size: 11, color: Colors.white)
          : null,
    );
  }
}

/// 标签胶囊：传 onRemove 时可点删除（详情页），不传则只读（列表页）
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.tag,
    this.onRemove,
    this.dense = false,
  });

  final String tag;
  final VoidCallback? onRemove;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final removable = onRemove != null;
    Widget body(bool hover) => Container(
          height: dense ? 17 : 23,
          padding: EdgeInsets.only(left: dense ? 6 : 9, right: dense ? 6 : 7),
          decoration: BoxDecoration(
            color: Palette.goldBg,
            borderRadius: BorderRadius.circular(dense ? 4 : 6),
            border: Border.all(
              color: removable && hover
                  ? Palette.gold.withOpacity(0.55)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tag,
                style: TextStyle(
                  fontSize: dense ? 10 : 11.5,
                  color: Palette.goldDeep,
                  height: 1.5,
                ),
              ),
              if (removable) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.close,
                  size: 11,
                  color:
                      hover ? Palette.red : Palette.goldDeep.withOpacity(0.55),
                ),
              ],
            ],
          ),
        );
    // 只读时不拦截点击，让列表行的点击照常生效
    if (!removable) return body(false);
    return HoverBox(onTap: onRemove!, builder: body);
  }
}

/// 说话人标签（带发言占比，与原型一致）
class SpeakerChip extends StatelessWidget {
  const SpeakerChip({
    super.key,
    required this.name,
    required this.onTap,
    this.percent,
    this.index = 0,
  });

  final String name;
  final VoidCallback onTap;
  final int? percent;
  final int index;

  static const _dotColors = [
    Palette.gold,
    Color(0xFF4A7FBF),
    Color(0xFF7B5EA7),
    Color(0xFF2E7D62),
    Color(0xFFB5654A),
    Color(0xFF5E7A88),
  ];

  @override
  Widget build(BuildContext context) {
    final dot = _dotColors[index % _dotColors.length];
    return HoverBox(
      onTap: onTap,
      builder: (hover) => Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: hover ? const Color(0xFFFDFBF7) : Colors.white,
          border: Border.all(color: hover ? const Color(0xFFD6CDBF) : Palette.line),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(name,
                style: const TextStyle(fontSize: 11.5, color: Palette.text)),
            if (percent != null) ...[
              const SizedBox(width: 5),
              Text('$percent%',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Palette.muted2,
                    fontFamily: Palette.monoFamily,
                  )),
            ],
          ],
        ),
      ),
    );
  }
}
