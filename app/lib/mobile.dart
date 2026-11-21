import 'dart:ui';

import 'package:flutter/material.dart';

import 'dart:async';

import 'app_state.dart';
import 'lan.dart';
import 'mobile_chat.dart';
import 'mobile_common.dart';
import 'mobile_settings.dart';
import 'mobile_timeline.dart';
import 'theme.dart';

/// 手机端外壳：底部导航（凸起录音按钮）+ 时间流 / AI 对话 + 全屏录音浮层
class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // 后台探一次电脑，学习它能否解码 m4a（决定后续录音存 AAC 还是 WAV）
    unawaited(LanClient.instance.discover());
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileSettingsPage(
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// 底部「速记」入口
  Future<void> _openNote() async {
    final ok = await showMobileNoteSheet(context);
    if (ok && mounted) AppScope.read(context).bumpData();
  }

  Future<void> _startRecord() async {
    final st = AppScope.read(context);
    if (st.recording) return;
    try {
      await st.startRecord();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('$e', style: const TextStyle(fontSize: 12.5)),
            backgroundColor: const Color(0xF20B2226),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    // 键盘弹出时收起底部导航，避免挡住输入框
    final kb = MediaQuery.of(context).viewInsets.bottom;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: Palette.paper,
          body: SafeArea(
            bottom: false,
            child: IndexedStack(
              index: _tab,
              children: [
                MobileTimeline(
                  onSettings: _openSettings,
                  onToChat: () => setState(() => _tab = 1),
                ),
                MobileChat(
                  onSettings: _openSettings,
                  active: _tab == 1,
                ),
              ],
            ),
          ),
          bottomNavigationBar: kb > 0
              ? null
              : MobileNavBar(
                  tab: _tab,
                  recording: st.recording,
                  onTab: (i) => setState(() => _tab = i),
                  onNote: _openNote,
                  onRecord: _startRecord,
                ),
        ),
        if (st.recording)
          const Positioned.fill(child: MobileRecordingOverlay()),
      ],
    );
  }
}

// ============================================================
// 底部导航：时间流 / AI 对话 / 速记 / 开始录音
// ============================================================
class MobileNavBar extends StatelessWidget {
  const MobileNavBar({
    super.key,
    required this.tab,
    required this.recording,
    required this.onTab,
    required this.onNote,
    required this.onRecord,
  });

  final int tab;
  final bool recording;
  final ValueChanged<int> onTab;
  final VoidCallback onNote;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      height: 74 + bottom,
      padding: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFDFCF8), Color(0xFFF4F1E9)],
        ),
        border: const Border(top: BorderSide(color: Color(0xFFE7E0D3))),
        boxShadow: [
          BoxShadow(
            color: Palette.ink.withOpacity(0.07),
            blurRadius: 18,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _navBtn(
              icon: Icons.view_agenda_outlined,
              label: '时间流',
              active: tab == 0,
              onTap: () => onTab(0),
            ),
          ),
          Expanded(
            child: _navBtn(
              icon: Icons.chat_bubble_outline,
              label: 'AI 对话',
              active: tab == 1,
              onTap: () => onTab(1),
            ),
          ),
          Expanded(
            child: _navBtn(
              icon: Icons.edit_outlined,
              label: '速记',
              active: false,
              onTap: onNote,
            ),
          ),
          Expanded(child: _recordBtn()),
        ],
      ),
    );
  }

  /// 开始录音（金色圆按钮，和原来凸起的按钮同一个视觉重心）
  Widget _recordBtn() {
    return Pressable(
      onTap: onRecord,
      scale: 0.94,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: recording
                    ? [const Color(0xFFD96A5B), const Color(0xFF9C3A30)]
                    : [const Color(0xFFE8BE63), const Color(0xFFB9792F)],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.55), width: 1.4),
              boxShadow: [
                BoxShadow(
                  color: (recording ? Palette.red : const Color(0xFFC0913F))
                      .withOpacity(0.42),
                  blurRadius: 16,
                  spreadRadius: 2,
                  offset: const Offset(0, 5),
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.7),
                  blurRadius: 1.5,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Icon(
              recording ? Icons.stop_rounded : Icons.mic_none,
              size: 20,
              color: recording ? Colors.white : const Color(0xFF2A1602),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            recording ? '录音中' : '开始录音',
            style: TextStyle(
              fontSize: 10.5,
              color: recording ? Palette.red : Palette.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _navBtn({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Pressable(
      onTap: onTap,
      scale: 0.94,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 选中态：图标下面垫一层浅金胶囊，看起来更有分量
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: 44,
            height: 28,
            decoration: BoxDecoration(
              color: active ? Palette.goldBg : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 20,
              color: active ? Palette.goldDeep : const Color(0xFF97A6A9),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? Palette.ink : const Color(0xFF97A6A9),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 录音浮层（原型 .prec：暗底 + 居中卡片）
// ============================================================
class MobileRecordingOverlay extends StatelessWidget {
  const MobileRecordingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);

    return Container(
      color: const Color(0x8C0B2226),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F2B31),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 40,
                      offset: const Offset(0, 20),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _PulseDot(),
                    const SizedBox(height: 14),
                    Text(
                      fmtSec(st.elapsed),
                      style: const TextStyle(
                        fontSize: 38,
                        letterSpacing: 1.6,
                        color: Color(0xFFF5EFE3),
                        fontFamily: Palette.monoFamily,
                        fontFamilyFallback: Palette.monoFallback,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      st.paused ? '已暂停' : '正在录音 · 麦克风',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF7E969B)),
                    ),
                    const SizedBox(height: 20),
                    _wave(st.level),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _overlayBtn(
                            label: st.paused ? '继续' : '暂停',
                            icon: st.paused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            onTap: st.togglePause,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _overlayBtn(
                            label: '停止并保存',
                            stop: true,
                            onTap: () async {
                              try {
                                await st.stopRecord();
                              } catch (_) {}
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: () async {
                        final ok = await showMobileConfirm(
                          context,
                          title: '放弃本次录音？',
                          desc: '录音尚未保存，放弃后无法恢复。',
                          okLabel: '放弃',
                        );
                        if (!ok) return;
                        await st.discardRecord();
                      },
                      child: const Text('取消本次录音',
                          style: TextStyle(
                              fontSize: 11.5, color: Color(0xFF6D8288))),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wave(double level) {
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(24, (i) {
          final seed = ((i * 37) % 100) / 100.0;
          final h = 0.16 + seed * (0.35 + 0.65 * level.clamp(0.0, 1.0)) * 0.84;
          return Container(
            width: 4,
            height: 48 * h,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(
              color: const Color(0xFFC0913F),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }

  Widget _overlayBtn({
    required String label,
    required VoidCallback onTap,
    IconData? icon,
    bool stop = false,
  }) {
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: stop ? const Color(0xFFB0453C) : Colors.white.withOpacity(0.09),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: const Color(0xFFD6E2E3)),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: stop ? Colors.white : const Color(0xFFD6E2E3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: const Color(0xFFE4695A)
              .withOpacity(0.55 + 0.45 * _c.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
