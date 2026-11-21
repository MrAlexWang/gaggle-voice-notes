import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// 0.7.0 的新 API 与 0.5.x 不兼容，这里直接用官方提供的 legacy 入口
import 'package:window_manager/legacy.dart';

import 'a2a.dart';
import 'ai_client.dart';
import 'app_state.dart';
import 'audio_convert.dart';
import 'chat.dart';
import 'config.dart';
import 'audio_hash.dart';
import 'db.dart';
import 'lan.dart';
import 'mobile.dart';
import 'models.dart';
import 'ollama.dart';
import 'theme.dart';
import 'timeline.dart';
import 'transcriber.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final base = await getApplicationSupportDirectory();
  // 用户可能在设置里改过数据目录，必须优先用它
  final custom = DataLocation.read();
  await Db.open(custom ?? p.join(base.path, 'Gaggle'));

  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(1360, 866),
      minimumSize: Size(940, 620),
      center: true,
      title: '雁书 Gaggle',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // 由 onWindowClose 决定是退出还是最小化
    await windowManager.setPreventClose(true);
    windowManager.addListener(_AppWindowListener());

    // 电脑端：起局域网服务，供手机调用转写与 Agent
    LanServer.instance.start();
  }

  runApp(const GaggleApp());
}

/// 关闭主窗口时的行为：读设置里的 close_action
class _AppWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    final action = Db.instance.getSetting('close_action') ?? 'exit';
    if (action == 'minimize') {
      await windowManager.minimize();
    } else {
      await windowManager.destroy();
    }
  }
}

class GaggleApp extends StatefulWidget {
  const GaggleApp({super.key});

  @override
  State<GaggleApp> createState() => _GaggleAppState();
}

class _GaggleAppState extends State<GaggleApp> {
  final AppState _state = AppState();

  @override
  void initState() {
    super.initState();
    // 手机上传录音等外部改动 → 电脑界面立刻刷新
    LanServer.instance.onItemsChanged = _state.bumpData;
    // 老数据补内容哈希，保证「重复上传」能判出来
    unawaited(_backfillAudioHashes());
  }

  /// 已有录音补 audio_hash（只补缺的，后台慢慢算，不阻塞界面）
  Future<void> _backfillAudioHashes() async {
    try {
      final items = Db.instance.itemsMissingHash();
      for (final it in items) {
        final path = it.audioPath;
        if (path == null) continue;
        final h = audioFileHash(path);
        if (h.isNotEmpty) Db.instance.setAudioHash(it.id, h);
        // 让出一帧，避免长任务卡住 UI
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    LanServer.instance.onItemsChanged = null;
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: MaterialApp(
        title: '雁书 Gaggle',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: Palette.paper,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Palette.ink,
            primary: Palette.ink,
            surface: Palette.paper,
          ),
          fontFamily: Palette.fontFamily,
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          dividerColor: Palette.line,
          tooltipTheme: const TooltipThemeData(
            waitDuration: Duration(milliseconds: 400),
            decoration: BoxDecoration(
              color: Color(0xF20B2226),
              borderRadius: BorderRadius.all(Radius.circular(7)),
            ),
            textStyle: TextStyle(fontSize: 11.5, color: Color(0xFFEAF0F0)),
          ),
        ),
        home: const ShellPage(),
      ),
    );
  }
}

/// 按可用宽度自动选择布局：≥760 用桌面三栏，否则用手机单列
class ShellPage extends StatelessWidget {
  const ShellPage({super.key});

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final body = w < 760 ? const MobileShell() : const DesktopShell();
    // 速记入口：原型顶栏没有按钮，走快捷键 Ctrl+Shift+N
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true):
            () => showQuickNote(context),
      },
      child: Focus(autofocus: true, child: body),
    );
  }
}

class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              const SideBar(),
              Expanded(
                child: Column(
                  children: [
                    const TopBar(),
                    Expanded(
                      child: IndexedStack(
                        index: st.tab,
                        children: const [
                          TimelineScreen(),
                          ChatScreen(),
                          SettingsScreen(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (st.recording)
            const Positioned(right: 24, bottom: 24, child: FloatRecordBar()),
        ],
      ),
    );
  }
}

// ============================================================
// 侧栏
// ============================================================
class SideBar extends StatelessWidget {
  const SideBar({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return Container(
      width: 78,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, 0.6, 1],
          colors: [Palette.ink, Palette.ink2, Color(0xFF16383F)],
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 18),
          const _VerticalLogo(),
          const SizedBox(height: 18),
          _NavButton(
            icon: Icons.view_agenda_outlined,
            tip: '时间流',
            active: st.tab == 0,
            onTap: () => st.setTab(0),
          ),
          _NavButton(
            icon: Icons.chat_bubble_outline,
            tip: 'AI 对话',
            active: st.tab == 1,
            onTap: () => st.setTab(1),
          ),
          const Spacer(),
          // 底部三段：录音 → 速记 → 设置
          _RecordFab(),
          const SizedBox(height: 8),
          _NavButton(
            icon: Icons.edit_outlined,
            tip: '速记 (Ctrl+Shift+N)',
            active: false,
            onTap: () => showQuickNote(context),
          ),
          const SizedBox(height: 2),
          _NavButton(
            icon: Icons.settings_outlined,
            tip: '设置',
            active: st.tab == 2,
            onTap: () => st.setTab(2),
          ),
          const SizedBox(height: 10),
          const Text('v0.1', style: TextStyle(fontSize: 10, color: Color(0xFF5E7478))),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _VerticalLogo extends StatelessWidget {
  const _VerticalLogo();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        Text('雁',
            style: TextStyle(
              fontSize: 19,
              height: 1.6,
              color: Palette.goldSoft,
              fontFamily: Palette.serifFamily,
              fontWeight: FontWeight.w600,
            )),
        Text('书',
            style: TextStyle(
              fontSize: 19,
              height: 1.6,
              color: Palette.goldSoft,
              fontFamily: Palette.serifFamily,
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton({
    required this.icon,
    required this.tip,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String tip;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? 0.92 : 1.0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  width: 44,
                  height: 44,
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  decoration: BoxDecoration(
                    gradient: active
                        ? const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x33D8A74E), Color(0x14D8A74E)],
                          )
                        : (_hover
                            ? const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x1AFFFFFF), Color(0x0AFFFFFF)],
                              )
                            : null),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: active
                          ? Palette.gold.withOpacity(0.38)
                          : (_hover ? Colors.white.withOpacity(0.12) : Colors.transparent),
                    ),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: Palette.gold.withOpacity(_hover ? 0.30 : 0.20),
                              blurRadius: _hover ? 18 : 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    widget.icon,
                    size: 21,
                    color: active
                        ? Palette.gold
                        : (_hover ? const Color(0xFFE3EDEE) : const Color(0xFF7E969B)),
                  ),
                ),
                if (active)
                  Positioned(
                    left: -18,
                    top: 13,
                    child: Container(
                      width: 3,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Palette.gold,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: [
                          BoxShadow(
                            color: Palette.gold.withOpacity(0.6),
                            blurRadius: 8,
                          ),
                        ],
                      ),
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

/// 左下角金色录音按钮
class _RecordFab extends StatefulWidget {
  const _RecordFab();

  @override
  State<_RecordFab> createState() => _RecordFabState();
}

class _RecordFabState extends State<_RecordFab> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final on = st.recording;
    return Tooltip(
      message: on ? '停止并保存' : '开始录音',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: () async {
            try {
              await st.toggleRecord();
            } catch (e) {
              // 录音失败只记录日志：界面不弹底部提示
              debugPrint('录音失败: $e');
            }
          },
          child: AnimatedScale(
            // 按下回弹，悬停轻抬
            scale: _pressed ? 0.93 : (_hover ? 1.04 : 1.0),
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: on
                      ? [
                          _pressed ? const Color(0xFFB24A3E) : const Color(0xFFD06054),
                          const Color(0xFF8E3128),
                        ]
                      : [
                          _pressed ? const Color(0xFFC2913A) : const Color(0xFFE0B457),
                          const Color(0xFFAD6F26),
                        ],
                ),
                border: Border.all(
                  color: Colors.white.withOpacity(0.22),
                  width: 1,
                ),
                boxShadow: _pressed
                    ? [
                        BoxShadow(
                          color: (on ? Palette.red : const Color(0xFFB9792F))
                              .withOpacity(0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: (on ? Palette.red : const Color(0xFFB9792F))
                              .withOpacity(_hover ? 0.62 : 0.5),
                          blurRadius: _hover ? 26 : 20,
                          offset: Offset(0, _hover ? 10 : 8),
                        ),
                        // 顶部内高光，像金属镀层
                        BoxShadow(
                          color: Colors.white.withOpacity(0.28),
                          blurRadius: 2,
                          offset: const Offset(0, -1),
                        ),
                      ],
              ),
              child: Icon(
                on ? Icons.stop_rounded : Icons.mic_none,
                size: 24,
                color: on ? Colors.white : const Color(0xFF2A1602),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 顶栏
// ============================================================
class TopBar extends StatefulWidget {
  const TopBar({super.key});

  @override
  State<TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<TopBar> {
  Timer? _timer;
  bool _aiReady = false;
  bool _trReady = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  void _refresh() {
    final cfg = AiClient.load();
    final trReady = Transcriber.instance.ready;
    if (!mounted) return;
    if (trReady == _trReady && cfg.ready == _aiReady) return;
    setState(() {
      _trReady = trReady;
      _aiReady = cfg.ready;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Color(0xB8FFFFFF),
        border: Border(bottom: BorderSide(color: Palette.line)),
      ),
      child: Row(
        children: [
          // 搜索框（宽度约为原来的 2/3）
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: SizedBox(
              height: 36,
              width: 320,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Palette.line),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    const Icon(Icons.search, size: 16, color: Palette.muted2),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: st.keywordCtrl,
                        onChanged: st.setKeyword,
                        style: const TextStyle(fontSize: 13.5, color: Palette.text),
                        cursorColor: Palette.gold,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索录音、速记、转写内容、对话…',
                          hintStyle: TextStyle(fontSize: 13.5, color: Palette.muted2),
                          contentPadding: EdgeInsets.symmetric(vertical: 9),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (st.tab == 0)
            // 导入音频紧跟搜索框
            _TopAction(
              icon: Icons.file_download_outlined,
              label: '导入音频',
              onTap: () => importAudioFlow(context),
            ),
          const Spacer(),
          _Chip(
            icon: Icons.memory,
            label: _trReady ? '转写就绪' : '转写未就绪',
            fg: _trReady ? Palette.green : Palette.muted,
            bg: _trReady ? Palette.greenBg : Colors.white,
            border: _trReady ? Palette.greenLine : Palette.line,
          ),
          const SizedBox(width: 8),
          _Chip(
            icon: null,
            label: _aiReady ? 'AI 就绪' : 'AI 未配置',
            fg: _aiReady ? Palette.green : Palette.muted,
            bg: _aiReady ? Palette.greenBg : Colors.white,
            border: _aiReady ? Palette.greenLine : Palette.line,
            dot: _aiReady,
          ),
        ],
      ),
    );
  }
}

class _TopAction extends StatelessWidget {
  const _TopAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return QualityButton(
      label: label,
      icon: icon,
      onTap: onTap,
      height: 34,
      hPad: 13,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.fg,
    required this.bg,
    required this.border,
    this.icon,
    this.dot = true,
  });

  final String label;
  final Color fg;
  final Color bg;
  final Color border;
  final IconData? icon;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot)
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
          if (dot) const SizedBox(width: 5),
          if (icon != null) Icon(icon, size: 12, color: fg),
          if (icon != null) const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11.5, color: fg)),
        ],
      ),
    );
  }
}

// ============================================================
// 录音浮条
// ============================================================
class FloatRecordBar extends StatelessWidget {
  const FloatRecordBar({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final mm = st.elapsed.inMinutes.toString().padLeft(2, '0');
    final ss = (st.elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      width: 430,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Palette.ink2, Palette.ink],
        ),
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Palette.ink.withOpacity(0.45),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          _PulsingDot(),
          const SizedBox(width: 10),
          Text(
            '$mm:$ss',
            style: const TextStyle(
              fontSize: 17,
              fontFamily: Palette.monoFamily,
              color: Color(0xFFF0EBE1),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 18,
                child: Row(
                  children: List.generate(28, (i) {
                    final active = (i / 28) < st.level;
                    return Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          color: active ? Palette.gold : const Color(0xFF254247),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            st.paused ? '已暂停' : '录音中',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF8FA6AA)),
          ),
          const SizedBox(width: 8),
          _SmallIconBtn(
            icon: st.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            tip: st.paused ? '继续' : '暂停',
            onTap: st.togglePause,
          ),
          const SizedBox(width: 6),
          QualityButton(
            label: '停止并保存',
            height: 30,
            hPad: 12,
            tone: BtnTone.danger,
            onTap: () async {
              try {
                await st.stopRecord();
              } catch (_) {}
            },
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
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
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: const Color(0xFFE4695A).withOpacity(0.55 + 0.45 * _c.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _SmallIconBtn extends StatelessWidget {
  const _SmallIconBtn({required this.icon, required this.tip, required this.onTap});

  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: QualityButton(
        label: '',
        icon: icon,
        onTap: onTap,
        tone: BtnTone.dark,
        height: 30,
        hPad: 8,
      ),
    );
  }
}

// ============================================================
// 速记窗
// ============================================================
Future<void> showQuickNote(BuildContext context) async {
  final st = AppScope.read(context);
  final ctrl = TextEditingController();
  final focus = FocusNode();
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x570B2226),
    builder: (ctx) {
      // 按原型：近全屏的编辑面板（四周留 26px）
      final size = MediaQuery.of(ctx).size;
      return Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.all(26),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: SizedBox(
          width: size.width - 52,
          height: size.height - 52,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 18, 28, 8),
                child: Row(
                  children: [
                    const Icon(Icons.edit_outlined, size: 14, color: Palette.gold),
                    const SizedBox(width: 9),
                    const Text('速记 · 纯文字，不录音 · 记完按 Esc 保存',
                        style: TextStyle(fontSize: 12.5, color: Palette.muted)),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: TextField(
                    controller: ctrl,
                    focusNode: focus,
                    autofocus: true,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                        fontSize: 16.5, height: 1.82, color: Palette.text),
                    cursorColor: Palette.gold,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '想到什么就写下来…（不会打断你正在做的事）',
                      hintStyle: TextStyle(fontSize: 16.5, color: Color(0xFFB4BFBF)),
                    ),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(28, 14, 28, 14),
                decoration: const BoxDecoration(
                  color: Color(0xFFFBF9F5),
                  border: Border(top: BorderSide(color: Palette.line2)),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('保存后立刻出现在时间流顶部',
                          style: TextStyle(fontSize: 11.5, color: Palette.muted2)),
                    ),
                    _DialogBtn(label: '取消', onTap: () => Navigator.pop(ctx, false)),
                    const SizedBox(width: 9),
                    _DialogBtn(
                      label: '保存',
                      primary: true,
                      onTap: () => Navigator.pop(ctx, true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  final text = ctrl.text.trim();
  focus.dispose();
  ctrl.dispose();
  if (ok != true || text.isEmpty) return;
  final id = Db.instance.insertItem(
    type: 'text',
    title: text.length > 18 ? '${text.substring(0, 18)}…' : text,
    body: text,
    charCount: text.length,
  );
  st.selectedId = id;
  st.bumpData();
}

class _DialogBtn extends StatelessWidget {
  const _DialogBtn({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return QualityButton(
      label: label,
      onTap: onTap,
      tone: primary
          ? BtnTone.primary
          : (danger ? BtnTone.danger : BtnTone.plain),
    );
  }
}

// ============================================================
// 设置页
// ============================================================
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 30, bottom: 60),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('设置',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: Palette.text)),
                const SizedBox(height: 4),
                const Text('所有数据都存在本地，不上传任何服务器',
                    style: TextStyle(fontSize: 12.5, color: Palette.muted)),
                const SizedBox(height: 24),
                const _StorageCard(),
                const _GeneralCard(),
                const _TranscribeCard(),
                const _AiServiceCard(),
                _SetCard(title: '关于', children: const [
                  _SetRow(
                    title: '雁书 Gaggle',
                    desc: '把念头，寄给未来的自己',
                    trailing: Text('0.1.0 (M1)',
                        style: TextStyle(fontSize: 12, color: Palette.muted2)),
                  ),
                  _SetRow(
                    title: '开源协议',
                    desc: '计划采用 MIT',
                    trailing: Text('M1 后补 LICENSE',
                        style: TextStyle(fontSize: 12, color: Palette.muted2)),
                  ),
                ]),
                const SizedBox(height: 18),
                // 页面底部常驻显示当前数据目录（改完目录会立刻跟着变）
                ValueListenableBuilder<String?>(
                  valueListenable: DataLocation.pendingPath,
                  builder: (_, pending, __) {
                    final root = pending ??
                        DataLocation.read() ??
                        Db.instance.rootPath;
                    return Row(
                      children: [
                        const Icon(Icons.folder_outlined,
                            size: 13, color: Palette.muted2),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            pending == null
                                ? '数据目录：$root'
                                : '数据目录：$root（重启后生效）',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: pending == null
                                  ? Palette.muted2
                                  : Palette.goldDeep,
                              fontFamily: Palette.monoFamily,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 设置：转写（模型档位 + 硬件检测）
// ============================================================
class _TranscribeCard extends StatefulWidget {
  const _TranscribeCard();

  @override
  State<_TranscribeCard> createState() => _TranscribeCardState();
}

class _TranscribeCardState extends State<_TranscribeCard> {
  String _hw = '检测中…';
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = ModelManager.selectedFile();
    ModelManager.hardwareSummary().then((v) {
      if (mounted) setState(() => _hw = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final installed = ModelManager.installed();
    final rec = ModelManager.recommended();
    final diarOk = Transcriber.instance.diarizeModelsDir() != null;

    return _SetCard(
      title: '转写',
      children: [
        _SetRow(
          title: '硬件',
          desc: '已安装的模型会自动选档，也可手动切换',
          trailing: Text(_hw,
              style: const TextStyle(fontSize: 12, color: Palette.muted2)),
        ),
        _SetRow(
          title: '音频归档',
          desc: AudioConvert.canTranscode
              ? '录音存 AAC/m4a（约 57MB/小时），导入的其它格式也能解码'
              : '未找到 ffmpeg，录音改存 WAV（约 1GB/小时）。把 ffmpeg.exe 放进数据目录的 engine 文件夹即可启用 AAC',
          trailing: Text(
            AudioConvert.canTranscode ? 'AAC · 已就绪' : 'WAV · 缺 ffmpeg',
            style: TextStyle(
              fontSize: 12,
              color: AudioConvert.canTranscode ? Palette.green : Palette.red,
            ),
          ),
        ),
        if (installed.isEmpty)
          const _SetRow(
            title: '尚未安装模型',
            desc: '把 ggml-small-q5_1.bin 放进数据目录的 models 文件夹',
            trailing: SizedBox.shrink(),
          )
        else
          ...installed.map((m) {
            final isSel = _selected == m.file;
            final isRec = rec?.file == m.file;
            return HoverBox(
              onTap: () {
                ModelManager.select(m.file);
                setState(() => _selected = m.file);
              },
              builder: (hover) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: hover ? const Color(0xFFFDFBF7) : Colors.transparent,
                  border: const Border(bottom: BorderSide(color: Palette.line2)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSel ? Palette.ink : Colors.transparent,
                        border: Border.all(
                          color: isSel ? Palette.ink : const Color(0xFFCFC7B9),
                          width: 1.5,
                        ),
                      ),
                      child: isSel
                          ? const Icon(Icons.check, size: 10, color: Colors.white)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(m.name,
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w500,
                                      color: Palette.text)),
                              const SizedBox(width: 7),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Palette.goldBg,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(m.tierLabel,
                                    style: const TextStyle(
                                        fontSize: 9.5, color: Palette.goldDeep)),
                              ),
                              if (isRec) ...[
                                const SizedBox(width: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Palette.greenBg,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('推荐',
                                      style: TextStyle(
                                          fontSize: 9.5, color: Palette.green)),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text('${m.sizeMB} MB · ${m.desc}',
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Palette.muted2,
                                  height: 1.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        _SetRow(
          title: '说话人区分',
          desc: '声纹分离自动标注，详情页点标签可改名',
          trailing: Text(
            diarOk ? '已就绪' : '未安装模型',
            style: TextStyle(
              fontSize: 12,
              color: diarOk ? Palette.green : Palette.muted2,
            ),
          ),
        ),
        const _SetRow(
          title: '云转写',
          desc: '把音频发到云端识别',
          trailing: Text('即将支持',
              style: TextStyle(fontSize: 12, color: Palette.muted2)),
        ),
      ],
    );
  }
}

// ============================================================
// 设置：存储（目录可改 + 占用空间）
// ============================================================
class _StorageCard extends StatefulWidget {
  const _StorageCard();

  @override
  State<_StorageCard> createState() => _StorageCardState();
}

class _StorageCardState extends State<_StorageCard> {
  int _size = 0;
  bool _busy = false;
  String _err = '';

  /// 已迁移但尚未重启生效的新目录（为空表示就是当前运行目录）
  String? _pending;

  @override
  void initState() {
    super.initState();
    final saved = DataLocation.pendingPath.value ?? DataLocation.read();
    if (saved != null && saved != Db.instance.rootPath) _pending = saved;
    _calc();
  }

  /// 界面上应该显示的目录：优先显示刚改好的新目录
  String get _shownRoot => _pending ?? Db.instance.rootPath;

  bool get _isPending => _pending != null;

  void _calc() {
    final s = DataLocation.sizeOf(_shownRoot);
    if (mounted) setState(() => _size = s);
  }

  Future<void> _changeDir() async {
    final picked = await getDirectoryPath();
    if (picked == null || !mounted) return;
    if (picked == Db.instance.rootPath) return;

    final ok = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x570B2226),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 470,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('迁移数据目录',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(
                  '将把现有数据复制到：\n$picked\n\n'
                  '复制完成后需要重启雁书才会生效。原目录会保留，确认没问题后可手动删除。',
                  style: const TextStyle(
                      fontSize: 12, color: Palette.muted, height: 1.75),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DialogBtn(
                        label: '取消', onTap: () => Navigator.pop(ctx, false)),
                    const SizedBox(width: 9),
                    DialogBtn(
                        label: '开始迁移',
                        primary: true,
                        onTap: () => Navigator.pop(ctx, true)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await DataLocation.copyDir(Db.instance.rootPath, picked);
      DataLocation.write(picked);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = '';
        // 立刻显示新目录（重启前用这个路径展示与统计）
        _pending = picked;
      });
      // 通知设置页底部那行也同步刷新
      DataLocation.pendingPath.value = picked;
      _calc();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = '迁移失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = _shownRoot;
    return _SetCard(
      title: '存储',
      children: [
        _SetRow(
          title: _isPending ? '数据目录（重启后生效）' : '数据目录',
          desc: _err.isNotEmpty
              ? _err
              : (_isPending ? '$root\n已迁移完成，重启雁书后自动切换' : root),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DialogBtn(
                  label: '打开', onTap: () => Process.run('explorer', [root])),
              const SizedBox(width: 8),
              DialogBtn(
                label: _busy ? '迁移中…' : '更改',
                onTap: _busy ? () {} : _changeDir,
              ),
            ],
          ),
        ),
        _SetRow(
          title: '已占用空间',
          desc: '录音、转写与索引合计',
          trailing: Text(
            DataLocation.human(_size),
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF4B6166)),
          ),
        ),
        _SetRow(
          title: '回收站',
          desc: '已删除的条目保留 30 天，到期自动清除',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${Db.instance.items(trash: true).length} 条',
                  style:
                      const TextStyle(fontSize: 12.5, color: Color(0xFF4B6166))),
              const SizedBox(width: 8),
              DialogBtn(
                  label: '查看', onTap: () => showTrashDialog(context)),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================
// 设置：通用（开机自启 / 关闭行为）
// ============================================================
class _GeneralCard extends StatefulWidget {
  const _GeneralCard();

  @override
  State<_GeneralCard> createState() => _GeneralCardState();
}

class _GeneralCardState extends State<_GeneralCard> {
  bool _autoStart = false;
  bool _loaded = false;
  String _err = '';
  String _closeAction = 'exit';

  @override
  void initState() {
    super.initState();
    _closeAction = Db.instance.getSetting('close_action') ?? 'exit';
    AutoStart.enabled().then((v) {
      if (!mounted) return;
      setState(() {
        _autoStart = v;
        _loaded = true;
      });
    });
  }

  Future<void> _toggleAutoStart(bool v) async {
    final ok = await AutoStart.setEnabled(v);
    if (!mounted) return;
    setState(() {
      if (ok) {
        _autoStart = v;
        _err = '';
      } else {
        _err = '设置失败，可能被系统策略或安全软件阻止';
      }
    });
  }

  void _setClose(String v) {
    Db.instance.setSetting('close_action', v);
    setState(() => _closeAction = v);
  }

  @override
  Widget build(BuildContext context) {
    return _SetCard(
      title: '通用',
      children: [
        _SetRow(
          title: '开机自动启动',
          desc: _err.isEmpty ? '登录 Windows 后自动启动雁书' : _err,
          trailing: Switch(
            value: _autoStart,
            activeThumbColor: Palette.gold,
            onChanged: _loaded ? _toggleAutoStart : null,
          ),
        ),
        _SetRow(
          title: '关闭主窗口时',
          desc: '点右上角 × 之后的行为',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _choice('退出程序', 'exit'),
              const SizedBox(width: 8),
              _choice('最小化到任务栏', 'minimize'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _choice(String label, String value) {
    final active = _closeAction == value;
    return QualityButton(
      label: label,
      height: 28,
      hPad: 12,
      fontSize: 12,
      tone: active ? BtnTone.primary : BtnTone.plain,
      onTap: () => _setClose(value),
    );
  }
}

// ============================================================
// 设置：AI 服务（默认本地 Ollama，可切云端）
// ============================================================
class _AiServiceCard extends StatefulWidget {
  const _AiServiceCard();

  @override
  State<_AiServiceCard> createState() => _AiServiceCardState();
}

class _AiServiceCardState extends State<_AiServiceCard> {
  String _provider = 'ollama';
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  bool _testing = false;
  bool _preparing = false;
  bool _autoTag = true;
  bool _autoName = true;
  String _result = '';
  String _prepareMsg = '';
  bool _ollamaAlive = false;
  bool _ollamaInstalled = false;

  /// 本机扫描到的 A2A 智能体
  List<A2aAgent> _agents = const [];
  bool _scanning = false;
  String _a2aSelected = '';
  String _agentMsg = '';

  @override
  void initState() {
    super.initState();
    final c = AiClient.load();
    _provider = c.provider;
    _baseUrl.text = c.baseUrl;
    _model.text = c.model;
    _apiKey.text = c.apiKey;
    _autoTag = AiClient.autoTagEnabled;
    _autoName = AiClient.autoNameEnabled;
    _ollamaInstalled = Ollama.installed;
    _a2aSelected = Db.instance.getSetting('a2a_selected') ?? '';
    _agents = A2aClient.instance.agents;
    // 进页面就自动扫一次本机智能体，无需手动点
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _agents.isEmpty) _scanAgents();
    });
    Ollama.task.addListener(_onTask);
    AiClient.ollamaAlive().then((v) {
      if (mounted) setState(() => _ollamaAlive = v);
    });
    // 已装 Ollama 就把模型准备好（没下载就静默下载，服务没跑就顺手拉起）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_provider == 'ollama' && Ollama.installed) _startBackgroundPrepare();
    });
  }

  @override
  void dispose() {
    Ollama.task.removeListener(_onTask);
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _onTask() {
    if (!mounted) return;
    setState(() => _preparing = Ollama.task.value.running);
  }

  void _pickProvider(String key) {
    final preset = AiConfig.presets[key]!;
    setState(() {
      _provider = key;
      _baseUrl.text = preset['baseUrl']!;
      _model.text = preset['model']!;
      if (key == 'ollama') _apiKey.text = '';
    });
    if (key == 'a2a') _scanAgents();
  }

  /// 扫描本机已安装/正在运行的 A2A 智能体
  Future<void> _scanAgents() async {
    setState(() {
      _scanning = true;
      _agentMsg = '正在扫描本机智能体…';
    });
    final list = await A2aClient.instance.discover();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _agents = list;
      if (list.isEmpty) {
        _agentMsg = '没扫描到智能体：确认它已在运行（例如「启动AI助手.bat」），再点「重新扫描」';
      } else {
        _agentMsg = '扫描到 ${list.length} 个智能体，选一个作为对话后端';
        if (_a2aSelected.isEmpty) _a2aSelected = list.first.endpoint;
      }
    });
  }

  void _useAgent(A2aAgent a) {
    Db.instance.setSetting('a2a_selected', a.endpoint);
    setState(() {
      _a2aSelected = a.endpoint;
      _provider = 'a2a';
      _model.text = a.name;
      _baseUrl.text = '';
      _result = '已切换到「${a.name}」，去 AI 对话直接提问即可';
    });
    // 关键：立刻落库，否则对话页读到的还是旧服务商
    AiClient.save(_cfg);
  }

  AiConfig get _cfg => AiConfig(
        provider: _provider,
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        apiKey: _apiKey.text.trim(),
      );

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = '';
    });
    // 本地 Ollama：测之前先确保服务在跑（没跑就自动拉起）
    if (_cfg.isOllama && !await Ollama.alive()) {
      if (mounted) setState(() => _result = '正在启动本地 Ollama…');
      final ok = await Ollama.ensureRunning(wait: const Duration(seconds: 20));
      if (!ok && mounted) {
        setState(() {
          _testing = false;
          _ollamaAlive = false;
          _result = Ollama.installed
              ? 'Ollama 启动失败，请点「一键准备」重试'
              : '本机没有找到 Ollama，请先安装（ollama.com/download）';
        });
        return;
      }
    }
    final r = await AiClient.test(_cfg);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = r;
      _ollamaAlive = _cfg.isOllama && r.startsWith('已连接');
      _ollamaInstalled = Ollama.installed;
    });
    // 测通了就顺手保存，避免用户忘记点保存
    if (r.startsWith('已连接')) AiClient.save(_cfg);
  }

  /// 后台静默准备：启动 Ollama → 缺模型就下载 → 预热进内存
  /// 全程不阻塞界面，进度由 [Ollama.task] 推送
  void _startBackgroundPrepare() {
    if (_preparing || Ollama.busy) return;
    AiClient.save(_cfg);
    final model = _model.text.trim();
    setState(() {
      _preparing = true;
      _prepareMsg = '启动 Ollama 服务…';
      _result = '';
    });
    Ollama.prepareInBackground(model).then((err) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _ollamaAlive = err.isEmpty;
        _ollamaInstalled = Ollama.installed;
        _result = err.isEmpty ? '已连接 · $model' : err;
        _prepareMsg = err.isEmpty ? '已就绪 · $model' : err;
      });
    });
  }

  /// 打开下载页；用户装好后自动在后台静默下载模型，无需再点一次
  Future<void> _openOllamaDownload() async {
    await Ollama.openDownloadPage();
    // 下载 + 安装可能要好几分钟，这里持续盯着，一装好就自动开始拉模型
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(seconds: 6));
      if (!mounted) return;
      if (Ollama.installed) {
        setState(() => _ollamaInstalled = true);
        _startBackgroundPrepare();
        return;
      }
    }
  }

  String _brief(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 90 ? '${t.substring(0, 90)}…' : t;
  }

  void _save() {
    AiClient.save(_cfg);
    setState(() => _result = '已保存');
  }

  @override
  Widget build(BuildContext context) {
    return _SetCard(
      title: 'AI 服务',
      children: [
        _SetBlock(
          title: '服务商',
          desc: _provider == 'ollama'
              ? (_ollamaAlive
                  ? '本机 Ollama 正在运行'
                  : 'Ollama 未运行也没关系，保存后会自动帮你启动')
              : _provider == 'a2a'
                  ? '自动扫描本机已安装的 A2A 智能体，选中后直接用它对话'
                  : '云端服务，需要联网并消耗额度',
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: AiConfig.presets.entries
                .map((e) => _providerChip(e.key, e.value['label']!))
                .toList(),
          ),
        ),
        if (_provider != 'a2a')
          _SetRow(
            title: '接口地址',
            desc: 'OpenAI 兼容的 base_url',
            trailing: _field(_baseUrl, 'https://…/v1', 250),
          ),
        if (_provider != 'a2a')
          _SetRow(
            title: '模型',
            desc: '如 qwen2.5:3b / deepseek-chat',
            trailing: _field(_model, 'model', 200),
          ),
        if (_provider == 'a2a') ...[
          _SetRow(
            title: '本机智能体',
            desc: _agentMsg.isEmpty
                ? '自动扫描本机常见 A2A 端口（9999 / 8080 / 8000 / 5000…）'
                : _agentMsg,
            trailing: DialogBtn(
              label: _scanning ? '扫描中…' : '重新扫描',
              icon: Icons.radar,
              onTap: _scanning ? () {} : _scanAgents,
            ),
          ),
          for (final a in _agents)
            _SetRow(
              title: a.name,
              desc: '${a.endpoint} · A2A ${a.protocolVersion}'
                  '${a.skills.isEmpty ? '' : ' · ${a.skills.join('、')}'}',
              trailing: DialogBtn(
                label: _a2aSelected == a.endpoint ? '使用中' : '用它对话',
                primary: _a2aSelected == a.endpoint,
                icon: _a2aSelected == a.endpoint
                    ? Icons.check
                    : Icons.play_arrow_rounded,
                onTap: () => _useAgent(a),
              ),
            ),
        ],
        if (_provider == 'ollama')
          _SetRow(
            title: '自动启动本地模型',
            desc: _prepareDesc(),
            trailing: !_ollamaAlive && !_ollamaInstalled
                ? DialogBtn(
                    label: '下载 Ollama',
                    icon: Icons.download,
                    onTap: _openOllamaDownload,
                  )
                : _prepareBtn(),
          ),
        _SetRow(
          title: 'AI 自动命名录音',
          desc: '转写完成后用 AI 起名，格式「标题 · 年月日时分秒」',
          trailing: _miniSwitch(_autoName, (v) {
            AiClient.setAutoNameEnabled(v);
            setState(() => _autoName = v);
          }),
        ),
        _SetRow(
          title: 'AI 自动打标签',
          desc: '转写完成后自动生成标签，详情页可手动增删',
          trailing: _miniSwitch(_autoTag, (v) {
            AiClient.setAutoTagEnabled(v);
            setState(() => _autoTag = v);
          }),
        ),
        if (_provider != 'ollama' && _provider != 'a2a')
          _SetRow(
            title: 'API Key',
            desc: '只存在本机数据库',
            trailing: _field(_apiKey, 'sk-…', 250, obscure: true),
          ),
        _SetRow(
          title: '连接状态',
          desc: _result.isEmpty ? '建议先「测试连接」，再保存' : _result,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_provider != 'a2a') ...[
                DialogBtn(
                    label: _testing ? '测试中…' : '测试连接',
                    onTap: _testing ? () {} : _test),
                const SizedBox(width: 8),
              ],
              DialogBtn(label: '保存', primary: true, onTap: _save),
            ],
          ),
        ),
      ],
    );
  }

  /// 这一行的说明：后台任务进行中优先显示实时进度
  String _prepareDesc() {
    final t = Ollama.task.value;
    if (t.running) {
      final pct = t.percent;
      return _brief(pct != null ? '${t.phase} $pct%' : t.phase);
    }
    if (_preparing || _prepareMsg.isNotEmpty) return _brief(_prepareMsg);
    if (!_ollamaAlive && !_ollamaInstalled) {
      return '本机未安装 Ollama：点右侧「下载 Ollama」装好，模型会自动在后台下载';
    }
    if (_ollamaAlive) return '服务已运行；点「一键准备」检查模型并加载进内存';
    return '点一次即可自动启动 Ollama、拉取模型，以后不用手动开';
  }

  /// 「一键准备」按钮：后台任务进行中显示进度条与百分比，界面不阻塞
  Widget _prepareBtn() {
    final t = Ollama.task.value;
    final running = _preparing || t.running;
    final pct = t.percent;
    final label = !running
        ? '一键准备'
        : (pct != null && pct > 0 ? '下载中 $pct%' : '准备中…');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (running && pct != null) ...[
          SizedBox(
            width: 84,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 4,
                backgroundColor: const Color(0xFFEDE8DE),
                valueColor: const AlwaysStoppedAnimation(Palette.gold),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        DialogBtn(
          label: label,
          icon: running ? null : Icons.bolt,
          primary: !running,
          onTap: running ? () {} : _startBackgroundPrepare,
        ),
      ],
    );
  }

  /// 小号开关（与整体风格一致的胶囊样式）
  Widget _miniSwitch(bool value, ValueChanged<bool> onChanged) {
    return HoverBox(
      onTap: () => onChanged(!value),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 40,
        height: 22,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value
              ? Palette.gold
              : (hover ? const Color(0xFFD3CBBC) : const Color(0xFFDFD8CB)),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Align(
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }

  Widget _providerChip(String key, String label) {
    final active = _provider == key;
    return QualityButton(
      label: label,
      height: 27,
      hPad: 11,
      fontSize: 11.5,
      tone: active ? BtnTone.primary : BtnTone.plain,
      onTap: () => _pickProvider(key),
    );
  }

  Widget _field(TextEditingController c, String hint, double width,
      {bool obscure = false}) {
    return Container(
      width: width,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Palette.paper,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: TextField(
          controller: c,
          obscureText: obscure,
          style: const TextStyle(fontSize: 12, fontFamily: Palette.monoFamily),
          cursorColor: Palette.gold,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12, color: Palette.muted2),
          ),
        ),
      ),
    );
  }
}

class _SetCard extends StatelessWidget {
  const _SetCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(13),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Palette.line2)),
            ),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Palette.muted,
                letterSpacing: 0.8,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// 上下结构的一行：标题/说明在上，内容在下方整行展开（用于芯片过多的情况）
class _SetBlock extends StatelessWidget {
  const _SetBlock({
    required this.title,
    required this.desc,
    required this.child,
  });

  final String title;
  final String desc;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Palette.line2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: Palette.text)),
          const SizedBox(height: 3),
          Text(desc,
              style:
                  const TextStyle(fontSize: 11.5, color: Palette.muted2, height: 1.5)),
          const SizedBox(height: 11),
          child,
        ],
      ),
    );
  }
}

class _SetRow extends StatelessWidget {
  const _SetRow({required this.title, required this.desc, this.trailing});

  final String title;
  final String desc;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Palette.line2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w500, color: Palette.text)),
                const SizedBox(height: 3),
                Text(desc,
                    style: const TextStyle(fontSize: 11.5, color: Palette.muted2, height: 1.5)),
              ],
            ),
          ),
          if (trailing != null) ...([const SizedBox(width: 16), trailing!]),
        ],
      ),
    );
  }
}

Future<void> showTrashDialog(BuildContext context) async {
  final st = AppScope.read(context);
  await showDialog(
    context: context,
    barrierColor: const Color(0x570B2226),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setInner) {
          final rows = Db.instance.items(trash: true);
          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: SizedBox(
              width: 680,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline, size: 16, color: Palette.muted),
                        const SizedBox(width: 8),
                        const Text('回收站',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        const Text('保留 30 天，到期自动清除',
                            style: TextStyle(fontSize: 11.5, color: Palette.muted2)),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Palette.line2),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: rows.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: Text('回收站是空的',
                                style: TextStyle(fontSize: 12.5, color: Palette.muted2)),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: rows.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, color: Palette.line2),
                            itemBuilder: (_, i) {
                              final it = rows[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: Palette.textIcBg,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Icon(
                                        it.isAudio ? Icons.mic_none : Icons.edit_outlined,
                                        size: 15,
                                        color: Palette.textIc,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(it.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 13, fontWeight: FontWeight.w500)),
                                          const SizedBox(height: 4),
                                          Text(
                                            '删除于 ${fmtClock(it.deletedAt ?? it.createdAt)}',
                                            style: const TextStyle(
                                                fontSize: 11, color: Palette.muted2),
                                          ),
                                        ],
                                      ),
                                    ),
                                    _DialogBtn(
                                      label: '恢复',
                                      onTap: () {
                                        Db.instance.restore(it.id);
                                        st.bumpData();
                                        setInner(() {});
                                      },
                                    ),
                                    const SizedBox(width: 7),
                                    _DialogBtn(
                                      label: '彻底删除',
                                      danger: true,
                                      onTap: () {
                                        Db.instance.purge(it.id);
                                        st.bumpData();
                                        setInner(() {});
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(22, 12, 22, 12),
                    decoration: const BoxDecoration(
                      color: Color(0xFFFBF9F5),
                      border: Border(top: BorderSide(color: Palette.line2)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('共 ${rows.length} 条',
                              style: const TextStyle(fontSize: 11.5, color: Palette.muted)),
                        ),
                        _DialogBtn(
                          label: '清空回收站',
                          danger: true,
                          onTap: () {
                            for (final r in Db.instance.items(trash: true)) {
                              Db.instance.purge(r.id);
                            }
                            st.bumpData();
                            setInner(() {});
                          },
                        ),
                        const SizedBox(width: 9),
                        _DialogBtn(label: '关闭', onTap: () => Navigator.pop(ctx)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}


