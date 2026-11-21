import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'ai_client.dart';
import 'app_state.dart';
import 'db.dart';
import 'theme.dart';
import 'transcriber.dart';
import 'widgets.dart';

// ============================================================
// 时间流：左列表 + 右详情
// ============================================================
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key});

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  bool _multi = false;
  final Set<String> _sel = {};

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final items = Db.instance.items(kw: st.keyword);
    st.ensureSelection(items);

    Item? current;
    for (final it in items) {
      if (it.id == st.selectedId) {
        current = it;
        break;
      }
    }

    return Row(
      children: [
        // 左列表
        Container(
          width: 352,
          decoration: const BoxDecoration(
            color: Palette.listBg,
            border: Border(right: BorderSide(color: Palette.line)),
          ),
          child: Column(
            children: [
              // 列表头
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    const Text(
                      '时间流',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Palette.muted,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${items.length} 条',
                        style: const TextStyle(fontSize: 11.5, color: Palette.muted2)),
                    const Spacer(),
                    _MiniBtn(
                      label: _multi ? '退出' : '多选',
                      active: _multi,
                      onTap: () => setState(() {
                        _multi = !_multi;
                        if (!_multi) _sel.clear();
                      }),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? const EmptyHint(
                        icon: Icons.mic_none,
                        title: '还没有内容',
                        desc: '点左下角金色按钮开始录音，或顶栏「导入音频」',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                        itemCount: items.length,
                        itemBuilder: (_, i) => _ItemRow(
                          item: items[i],
                          tags: Db.instance.tags(items[i].id),
                          active: !_multi && items[i].id == st.selectedId,
                          multi: _multi,
                          checked: _sel.contains(items[i].id),
                          onTap: () {
                            if (_multi) {
                              setState(() {
                                if (_sel.contains(items[i].id)) {
                                  _sel.remove(items[i].id);
                                } else {
                                  _sel.add(items[i].id);
                                }
                              });
                            } else {
                              st.select(items[i].id);
                            }
                          },
                          onRename: () => _rename(context, items[i], st),
                          onDelete: () => _delete(items[i], st),
                        ),
                      ),
              ),
              // 批量操作条：贴在列表底部（与原型一致）
              if (_multi)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                  child: _BatchBar(
                    count: _sel.length,
                    allSelected: items.isNotEmpty && _sel.length == items.length,
                    onSelectAll: () => setState(() {
                      if (_sel.length == items.length) {
                        _sel.clear();
                      } else {
                        _sel
                          ..clear()
                          ..addAll(items.map((e) => e.id));
                      }
                    }),
                    onChat: () {
                      if (_sel.isEmpty) return;
                      st.pendingRefs = _sel.toList();
                      st.setTab(1);
                      setState(() => _multi = false);
                      _sel.clear();
                    },
                    onDelete: () {
                      for (final id in _sel) {
                        Db.instance.moveToTrash(id);
                      }
                      _sel.clear();
                      setState(() => _multi = false);
                      st.bumpData();
                    },
                    onCancel: () => setState(() {
                      _multi = false;
                      _sel.clear();
                    }),
                  ),
                ),
            ],
          ),
        ),
        // 右详情
        Expanded(
          child: current == null
              ? const EmptyHint(
                  icon: Icons.view_agenda_outlined,
                  title: '选择左侧一条内容',
                  desc: '查看播放、转写与检索定位',
                )
              : DetailPane(key: ValueKey(current.id), item: current, state: st),
        ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, Item it, AppState st) async {
    final ctrl = TextEditingController(text: it.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 460,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('重命名',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13.5),
                  cursorColor: Palette.gold,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.gold),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DialogBtn(label: '取消', onTap: () => Navigator.pop(ctx, false)),
                    const SizedBox(width: 9),
                    DialogBtn(label: '保存', primary: true, onTap: () => Navigator.pop(ctx, true)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final v = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || v.isEmpty) return;
    Db.instance.rename(it.id, v);
    st.bumpData();
  }

  void _delete(Item it, AppState st) {
    Db.instance.moveToTrash(it.id);
    st.bumpData();
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.tags,
    required this.active,
    required this.multi,
    required this.checked,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Item item;
  final List<String> tags;
  final bool active;
  final bool multi;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: HoverBox(
        onTap: onTap,
        builder: (hover) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: active
                ? Colors.white
                : (hover ? Palette.hoverBg : Colors.transparent),
            border: Border.all(color: active ? Palette.line : Colors.transparent),
            borderRadius: BorderRadius.circular(11),
            boxShadow: active
                ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2))]
                : null,
          ),
          child: Row(
            children: [
              if (multi) ...[
                CheckSquare(checked: checked),
                const SizedBox(width: 9),
              ],
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: item.isAudio ? Palette.goldBg : Palette.textIcBg,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  item.isAudio ? Icons.mic_none : Icons.edit_outlined,
                  size: 17,
                  color: item.isAudio ? Palette.gold : Palette.textIc,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: Palette.text,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 7,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          item.isAudio
                              ? fmtDurMs(item.durationMs)
                              : '${item.charCount ?? (item.body?.length ?? 0)} 字',
                          style: const TextStyle(fontSize: 11.5, color: Palette.muted2),
                        ),
                        const _Dot(),
                        Text(fmtClock(item.createdAt),
                            style: const TextStyle(fontSize: 11.5, color: Palette.muted2)),
                        DeviceBadge(device: item.sourceDevice),
                        if (item.isAudio)
                          StatusBadge(status: item.transcriptStatus),
                        // 重复录音：同一条录音被再次上传/导入时标出来
                        if (item.isDuplicate) const DuplicateBadge(),
                        for (final t in tags.take(2)) TagChip(tag: t, dense: true),
                      ],
                    ),
                  ],
                ),
              ),
              if (!multi)
                // 原型里「⋯」只在悬停时淡入，不占位跳动
                IgnorePointer(
                  ignoring: !hover,
                  child: AnimatedOpacity(
                    opacity: hover ? 1 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: _RowMenu(onRename: onRename, onDelete: onDelete),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.onRename, required this.onDelete});

  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      padding: EdgeInsets.zero,
      splashRadius: 14,
      icon: const Icon(Icons.more_horiz, size: 17, color: Palette.muted2),
      onSelected: (v) {
        if (v == 'rename') onRename();
        if (v == 'del') onDelete();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'rename',
          height: 40,
          child: Text('重命名', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          value: 'del',
          height: 40,
          child: Text('删除', style: TextStyle(fontSize: 13, color: Palette.red)),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 3,
      decoration: const BoxDecoration(color: Palette.dotGrey, shape: BoxShape.circle),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  const _MiniBtn({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return QualityButton(
      label: label,
      height: 25,
      hPad: 9,
      fontSize: 11,
      tone: active ? BtnTone.primary : BtnTone.ghost,
      onTap: onTap,
    );
  }
}

class _BatchBar extends StatelessWidget {
  const _BatchBar({
    required this.count,
    required this.allSelected,
    required this.onSelectAll,
    required this.onChat,
    required this.onDelete,
    required this.onCancel,
  });

  final int count;
  final bool allSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onChat;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xF70B2226),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Palette.ink.withOpacity(0.55), blurRadius: 30, offset: const Offset(0, 14)),
        ],
      ),
      child: Row(
        children: [
          Text('已选 $count 条',
              style: const TextStyle(fontSize: 12, color: Color(0xFFBFD0D3))),
          const Spacer(),
          // 全选 / 取消全选
          _DarkBtn(label: allSelected ? '清空' : '全选', onTap: onSelectAll),
          const SizedBox(width: 6),
          _DarkBtn(label: '发给 AI', onTap: onChat),
          const SizedBox(width: 6),
          _DarkBtn(label: '删除', onTap: onDelete, danger: true),
          const SizedBox(width: 6),
          _DarkBtn(label: '取消', onTap: onCancel),
        ],
      ),
    );
  }
}

class _DarkBtn extends StatelessWidget {
  const _DarkBtn({required this.label, required this.onTap, this.danger = false});

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return QualityButton(
      label: label,
      height: 28,
      hPad: 11,
      tone: danger ? BtnTone.danger : BtnTone.dark,
      onTap: onTap,
    );
  }
}

// ============================================================
// 详情面板
// ============================================================
class DetailPane extends StatefulWidget {
  const DetailPane({super.key, required this.item, required this.state});

  final Item item;
  final AppState state;

  @override
  State<DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<DetailPane> {
  final _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  bool _ready = false;
  double _speed = 1.0;
  List<Map<String, Object?>> _segs = const [];
  List<String> _tags = const [];
  bool _tagging = false;
  String _tagNote = '';

  // 段落内联编辑（双击）
  int? _editingStart;
  final TextEditingController _segCtrl = TextEditingController();
  final FocusNode _segFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _segs = Db.instance.segments(widget.item.id);
    _tags = Db.instance.tags(widget.item.id);
    _segFocus.addListener(_onSegFocus);
    Transcriber.instance.progress.addListener(_onTranscribeProgress);
    _bind();
  }

  void _onSegFocus() {
    if (!_segFocus.hasFocus && _editingStart != null) {
      _commitSegment();
    }
  }

  void _onTranscribeProgress() {
    if (!mounted) return;
    final p = Transcriber.instance.progress.value;
    if (p == null || p.itemId == widget.item.id) {
      setState(() {
        _segs = Db.instance.segments(widget.item.id);
        _tags = Db.instance.tags(widget.item.id);
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _bind() async {
    final it = widget.item;
    if (!it.isAudio || it.audioPath == null) return;

    _subs.add(_player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    }));
    _subs.add(_player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    }));
    _subs.add(_player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    }));

    try {
      await _player.setSourceDeviceFile(it.audioPath!);
      final d = await _player.getDuration();
      if (mounted) {
        setState(() {
          _dur = d ?? Duration.zero;
          _ready = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _ready = false);
    }
  }

  @override
  void dispose() {
    Transcriber.instance.progress.removeListener(_onTranscribeProgress);
    _segFocus.removeListener(_onSegFocus);
    _segFocus.dispose();
    _segCtrl.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_ready) return;
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      await _player.resume();
      if (mounted) setState(() => _playing = true);
    }
  }

  Future<void> _seek(Duration d) async {
    if (!_ready) return;
    await _player.seek(d);
    if (mounted) setState(() => _pos = d);
  }

  Future<void> _cycleSpeed() async {
    const speeds = [1.0, 1.25, 1.5, 2.0];
    final i = speeds.indexOf(_speed);
    _speed = speeds[(i + 1) % speeds.length];
    await _player.setPlaybackRate(_speed);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return Container(
      color: Palette.paper,
      child: Column(
        children: [
          _head(it),
          if (it.isAudio) _playerBar(it),
          Expanded(child: _transcript(it)),
        ],
      ),
    );
  }

  Widget _head(Item it) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Palette.line2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it.title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: Palette.text,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Text(fmtClock(it.createdAt),
                        style: const TextStyle(fontSize: 12, color: Palette.muted)),
                    const SizedBox(width: 8),
                    const _Dot(),
                    const SizedBox(width: 8),
                    Text(
                      it.isAudio ? fmtDurMs(it.durationMs) : '${it.charCount ?? 0} 字',
                      style: const TextStyle(fontSize: 12, color: Palette.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 标签：手动添加 + AI 自动生成
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final t in _tags)
                      TagChip(tag: t, onRemove: () => _removeTag(it, t)),
                    DialogBtn(
                      label: '添加标签',
                      icon: Icons.add,
                      height: 23,
                      onTap: () => _addTag(it),
                    ),
                    DialogBtn(
                      label: _tagging ? '生成中…' : 'AI 打标签',
                      icon: Icons.auto_awesome,
                      height: 23,
                      onTap: _tagging ? () {} : () => _aiTag(it),
                    ),
                    if (_tagNote.isNotEmpty)
                      Text(
                        _tagNote,
                        style: TextStyle(
                          fontSize: 11,
                          color: _tagNote.startsWith('打标签失败')
                              ? Palette.red
                              : Palette.muted2,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DialogBtn(
                label: '重命名',
                onTap: () async {
                  // 复用列表页的重命名入口较绕，这里直接就地弹窗
                  await _renameInline(it);
                },
              ),
              const SizedBox(width: 8),
              if (it.isAudio && _segs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DialogBtn(
                    label: '重新转写',
                    icon: Icons.refresh,
                    onTap: () => Transcriber.instance.retranscribe(it.id),
                  ),
                ),
              DialogBtn(
                label: 'AI 分析',
                primary: true,
                onTap: () {
                  widget.state.pendingRefs = [it.id];
                  widget.state.setTab(1);
                },
              ),
              const SizedBox(width: 8),
              DialogBtn(
                label: '删除',
                danger: true,
                onTap: () {
                  Db.instance.moveToTrash(it.id);
                  widget.state.bumpData();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 段落内联编辑（双击文字） ----------

  void _startSegmentEdit(int startMs, String text) {
    if (_editingStart == startMs) return;
    if (_editingStart != null) _commitSegment();
    setState(() {
      _editingStart = startMs;
      _segCtrl.text = text;
      _segCtrl.selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _segFocus.requestFocus();
    });
  }

  void _commitSegment() {
    final start = _editingStart;
    if (start == null) return;
    final v = _segCtrl.text.trim();
    _editingStart = null;
    if (_segFocus.hasFocus) _segFocus.unfocus();
    if (v.isNotEmpty) {
      Db.instance.updateSegmentText(widget.item.id, start, v);
    }
    setState(() => _segs = Db.instance.segments(widget.item.id));
    widget.state.bumpData();
  }

  void _cancelSegment() {
    if (_editingStart == null) return;
    _editingStart = null;
    if (_segFocus.hasFocus) _segFocus.unfocus();
    setState(() {});
  }

  // ---------- 标签 ----------

  Future<void> _addTag(Item it) async {
    final ctrl = TextEditingController();
    final existed = Db.instance.allTags().take(6).toList();
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x570B2226),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 440,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('添加标签',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  existed.isEmpty
                      ? '可用逗号一次加多个，例如：产品评审, 待办'
                      : '可用逗号一次加多个 · 已有：${existed.join('、')}',
                  style: const TextStyle(fontSize: 11.5, color: Palette.muted2),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13.5),
                  cursorColor: Palette.gold,
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '标签名',
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.gold),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DialogBtn(label: '取消', onTap: () => Navigator.pop(ctx, false)),
                    const SizedBox(width: 9),
                    DialogBtn(
                        label: '添加',
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
    final raw = ctrl.text;
    ctrl.dispose();
    if (ok != true || raw.trim().isEmpty) return;
    for (final t in raw.split(RegExp(r'[,，、\s]+'))) {
      if (t.trim().isNotEmpty) Db.instance.addTag(it.id, t);
    }
    if (!mounted) return;
    setState(() => _tags = Db.instance.tags(it.id));
    widget.state.bumpData();
  }

  void _removeTag(Item it, String tag) {
    Db.instance.removeTag(it.id, tag);
    setState(() => _tags = Db.instance.tags(it.id));
    widget.state.bumpData();
  }

  /// 让 AI 重新生成标签（手动标签会保留）；结果就地显示在标签行，不弹提示
  Future<void> _aiTag(Item it) async {
    if (_tagging) return;
    setState(() {
      _tagging = true;
      _tagNote = '';
    });
    try {
      final tags = await AiClient.tagItem(it.id);
      if (!mounted) return;
      setState(() {
        _tags = Db.instance.tags(it.id);
        _tagNote = tags.isEmpty ? '没有生成新标签' : '已生成 ${tags.length} 个标签';
      });
      widget.state.bumpData();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tagNote = '打标签失败：${AiClient.friendly(e, AiClient.load())}';
      });
    } finally {
      if (mounted) setState(() => _tagging = false);
    }
  }

  /// 编辑纯文字条目正文
  Future<void> _editBody(Item it) async {
    final ctrl = TextEditingController(text: it.body ?? '');
    final ok = await _showEditDialog('编辑正文', '保存后会更新检索索引', ctrl, maxLines: 10);
    final v = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || v.isEmpty) return;
    Db.instance.updateBodyText(it.id, v);
    widget.state.bumpData();
  }

  Future<bool?> _showEditDialog(
    String title,
    String desc,
    TextEditingController ctrl, {
    int maxLines = 4,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: const Color(0x570B2226),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 560,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(desc,
                    style: const TextStyle(
                        fontSize: 11.5, color: Palette.muted2)),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  minLines: 2,
                  maxLines: maxLines,
                  style: const TextStyle(fontSize: 14, height: 1.7),
                  cursorColor: Palette.gold,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.all(11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.gold),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DialogBtn(
                        label: '取消', onTap: () => Navigator.pop(ctx, false)),
                    const SizedBox(width: 9),
                    DialogBtn(
                        label: '保存',
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
  }

  /// 说话人改名（原型：点击标签可改名）
  Future<void> _renameSpeaker(Item it, String from) async {
    final ctrl = TextEditingController(text: from);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 420,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('改说话人名字',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('该条目下所有「$from」都会一起改',
                    style: const TextStyle(fontSize: 11.5, color: Palette.muted2)),
                const SizedBox(height: 14),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13.5),
                  cursorColor: Palette.gold,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '例如：我 / 李工 / 小王',
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: Palette.gold),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DialogBtn(label: '取消', onTap: () => Navigator.pop(ctx, false)),
                    const SizedBox(width: 9),
                    DialogBtn(
                        label: '保存',
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
    final v = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || v.isEmpty || v == from) return;
    Db.instance.renameSpeaker(it.id, from, v);
    setState(() => _segs = Db.instance.segments(it.id));
  }

  Future<void> _renameInline(Item it) async {
    final ctrl = TextEditingController(text: it.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 460,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('重命名',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                TextField(controller: ctrl, autofocus: true),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DialogBtn(label: '取消', onTap: () => Navigator.pop(ctx, false)),
                    const SizedBox(width: 9),
                    DialogBtn(label: '保存', primary: true, onTap: () => Navigator.pop(ctx, true)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final v = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || v.isEmpty) return;
    Db.instance.rename(it.id, v);
    widget.state.bumpData();
  }

  /// 内联编辑时的 ✓ / ✕ 小按钮
  Widget _segEditBtn(IconData icon, Color color, VoidCallback onTap) {
    return HoverBox(
      onTap: onTap,
      builder: (hover) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: hover ? Palette.hoverBg : Colors.white,
          border: Border.all(color: Palette.line),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(icon, size: 14, color: color),
      ),
    );
  }

  Widget _playerBar(Item it) {
    final total = _dur.inMilliseconds <= 0 ? 1 : _dur.inMilliseconds;
    final progress = (_pos.inMilliseconds / total).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      decoration: const BoxDecoration(
        color: Color(0x80FFFFFF),
        border: Border(bottom: BorderSide(color: Palette.line2)),
      ),
      child: Row(
        children: [
          HoverBox(
            onTap: _toggle,
            builder: (hover) => Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: hover ? Palette.inkHover : Palette.ink,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Palette.ink.withOpacity(0.5),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(_playing ? Icons.pause : Icons.play_arrow_rounded,
                  color: const Color(0xFFF3EEE4), size: 22),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, cons) {
                const barCount = 220;
                final bars = waveBars(it.id, barCount);
                final onCount = (progress * barCount).round();
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    if (!_ready) return;
                    final ratio = (d.localPosition.dx / cons.maxWidth).clamp(0.0, 1.0);
                    _seek(Duration(milliseconds: (ratio * total).round()));
                  },
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: List.generate(barCount, (i) {
                        return Expanded(
                          child: Padding(
                            // 细密柱：与原型一致的 1px 间隙
                            padding: const EdgeInsets.symmetric(horizontal: 0.5),
                            child: Container(
                              height: 4 + bars[i] * 32,
                              decoration: BoxDecoration(
                                color: i < onCount
                                    ? const Color(0xFFB9792F)
                                    : const Color(0xFFD9D3C7),
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 16),
          Text(
            '${fmtSec(_pos)} / ${fmtSec(_dur)}',
            style: const TextStyle(
              fontSize: 11.5,
              color: Palette.muted,
              fontFamily: Palette.monoFamily,
            ),
          ),
          const SizedBox(width: 10),
          HoverBox(
            onTap: _cycleSpeed,
            builder: (hover) => Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: hover ? const Color(0xFFD6CDBF) : Palette.line),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Center(
                child: Text('${_speed}x',
                    style: const TextStyle(fontSize: 11.5, color: Palette.muted)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _transcript(Item it) {
    if (!it.isAudio) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 18, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '正文',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Palette.muted,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                DialogBtn(
                  label: '编辑',
                  icon: Icons.edit_outlined,
                  onTap: () => _editBody(it),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              it.body ?? '',
              style: const TextStyle(
                  fontSize: 14, height: 1.8, color: Palette.textBody),
            ),
          ],
        ),
      );
    }

    if (_segs.isEmpty) {
      final p = Transcriber.instance.progress.value;
      final mine = p != null && p.itemId == it.id;
      final tr = Transcriber.instance;

      if (mine) {
        final pct = p.percent.clamp(0, 100);
        return Center(
          child: Container(
            width: 420,
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Palette.line),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Palette.gold),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(p.phase,
                        style: const TextStyle(fontSize: 13.5, color: Palette.text)),
                    const Spacer(),
                    Text('$pct%',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Palette.muted,
                          fontFamily: Palette.monoFamily,
                        )),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 6,
                    backgroundColor: const Color(0xFFEDE8DE),
                    valueColor: const AlwaysStoppedAnimation(Palette.gold),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  p.queueLeft > 0 ? '队列中还有 ${p.queueLeft} 条' : '本地转写，音频不出本机',
                  style: const TextStyle(fontSize: 11.5, color: Palette.muted2),
                ),
              ],
            ),
          ),
        );
      }

      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tr.ready ? Icons.text_snippet_outlined : Icons.warning_amber_rounded,
              size: 32,
              color: Palette.muted2,
            ),
            const SizedBox(height: 12),
            Text(tr.ready ? '尚未转写' : '本地转写不可用',
                style: const TextStyle(fontSize: 13.5, color: Palette.muted2)),
            const SizedBox(height: 6),
            Text(
              tr.ready
                  ? '本地模型已就绪，点击开始转写'
                  : (tr.hasEngine ? '缺少模型文件，请放到数据目录的 models 文件夹' : '缺少转写引擎文件'),
              style: const TextStyle(fontSize: 11.5, color: Palette.muted2),
            ),
            const SizedBox(height: 16),
            if (tr.ready)
              DialogBtn(
                label: '开始转写',
                primary: true,
                icon: Icons.auto_awesome,
                onTap: () => Transcriber.instance.enqueue(it.id),
              ),
          ],
        ),
      );
    }

    // 说话人统计：按发言时长算占比
    final share = <String, int>{};
    var totalDur = 0;
    for (final s in _segs) {
      final sp = s['speaker'] as String?;
      final d = ((s['end'] as int?) ?? 0) - ((s['start'] as int?) ?? 0);
      totalDur += d > 0 ? d : 0;
      if (sp == null) continue;
      share[sp] = (share[sp] ?? 0) + (d > 0 ? d : 0);
    }
    final speakers = share.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 「转写文本」标题行
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 16, 28, 0),
          child: Row(
            children: [
              Text(
                '转写文本',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Palette.muted,
                  letterSpacing: 1,
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '点击段落定位时间 · 双击文字可直接修改',
                  style: TextStyle(fontSize: 11.5, color: Palette.muted2),
                ),
              ),
            ],
          ),
        ),
        if (speakers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...speakers.asMap().entries.map((e) {
                  final name = e.value;
                  final pct =
                      totalDur > 0 ? (share[name]! * 100 / totalDur).round() : 0;
                  return SpeakerChip(
                    name: name,
                    percent: pct,
                    index: e.key,
                    onTap: () => _renameSpeaker(it, name),
                  );
                }),
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text('点击标签可改名',
                      style: TextStyle(fontSize: 11, color: Palette.muted2)),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
            itemCount: _segs.length,
            itemBuilder: (_, i) {
              final s = _segs[i];
              final start = (s['start'] as int?) ?? 0;
              final text = (s['text'] as String?) ?? '';
              final spk = s['speaker'] as String?;
              final cur = _pos.inMilliseconds >= start &&
                  (i + 1 >= _segs.length ||
                      _pos.inMilliseconds < ((_segs[i + 1]['start'] as int?) ?? 1 << 30));
              final editing = _editingStart == start;
              return HoverBox(
                onTap: () => _seek(Duration(milliseconds: start)),
                onDoubleTap: () => _startSegmentEdit(start, text),
                builder: (hover) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  decoration: BoxDecoration(
                    color: cur || editing
                        ? Colors.white
                        : (hover ? Colors.white.withOpacity(0.7) : Colors.transparent),
                    borderRadius: BorderRadius.circular(9),
                    border: editing
                        ? Border.all(color: Palette.gold.withOpacity(0.45))
                        : Border.all(color: Colors.transparent),
                    boxShadow: cur
                        ? [
                            const BoxShadow(color: Palette.line, blurRadius: 0, offset: Offset(0, 1)),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.06),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 52,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            fmtSec(Duration(milliseconds: start)),
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Palette.muted2,
                              fontFamily: Palette.monoFamily,
                            ),
                          ),
                        ),
                      ),
                      if (spk != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 10, top: 2),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Palette.goldBg,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(spk,
                                style: const TextStyle(
                                    fontSize: 10.5, color: Palette.goldDeep)),
                          ),
                        ),
                      ],
                      Expanded(
                        child: editing
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    // Esc 放弃，Ctrl/⌘+Enter 保存
                                    child: CallbackShortcuts(
                                      bindings: {
                                        const SingleActivator(
                                                LogicalKeyboardKey.escape):
                                            _cancelSegment,
                                        const SingleActivator(
                                                LogicalKeyboardKey.enter,
                                                control: true):
                                            _commitSegment,
                                        const SingleActivator(
                                                LogicalKeyboardKey.enter,
                                                meta: true):
                                            _commitSegment,
                                      },
                                      child: TextField(
                                        controller: _segCtrl,
                                        focusNode: _segFocus,
                                        autofocus: true,
                                        minLines: 1,
                                        maxLines: 8,
                                        style: const TextStyle(
                                            fontSize: 14, height: 1.6),
                                        cursorColor: Palette.gold,
                                        decoration: InputDecoration(
                                          isDense: true,
                                          filled: true,
                                          fillColor: Colors.white,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 9, vertical: 8),
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: const BorderSide(
                                                color: Palette.line),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: const BorderSide(
                                                color: Palette.line),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: const BorderSide(
                                                color: Palette.gold),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _segEditBtn(Icons.check, Palette.green,
                                      _commitSegment),
                                  const SizedBox(width: 4),
                                  _segEditBtn(Icons.close, Palette.muted2,
                                      _cancelSegment),
                                ],
                              )
                            : Text(
                                text,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.72,
                                  color: cur ? Palette.text : Palette.textBody,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 由条目 ID 生成稳定的伪波形（M2 接入真实音频包络后替换）
List<double> waveBars(String seed, int n) {
  final r = math.Random(seed.hashCode);
  final bars = <double>[];
  var prev = 0.4;
  for (var i = 0; i < n; i++) {
    // 平滑随机：让波形看起来像语音，而不是噪点
    final target = 0.15 + r.nextDouble() * 0.85;
    prev = prev * 0.55 + target * 0.45;
    bars.add(prev.clamp(0.12, 1.0));
  }
  return bars;
}

// ============================================================
// 导入音频
// ============================================================
Future<void> importAudioFlow(BuildContext context) async {
  final st = AppScope.read(context);
  const group = XTypeGroup(label: '音频/视频', extensions: [
    'm4a', 'aac', 'mp3', 'wav', 'flac', 'ogg', 'opus', 'amr',
    'mp4', 'mov', 'mkv', 'avi',
  ]);
  List<XFile> files;
  try {
    files = await openFiles(acceptedTypeGroups: const [group]);
  } catch (_) {
    return;
  }
  if (files.isEmpty) return;

  final dir = Directory(p.join(Db.instance.rootPath, 'audio'));
  if (!dir.existsSync()) dir.createSync(recursive: true);

  String? lastId;
  for (final f in files) {
    final ext = p.extension(f.path);
    final dest = p.join(dir.path, 'imp_${DateTime.now().microsecondsSinceEpoch}$ext');
    try {
      File(f.path).copySync(dest);
    } catch (_) {
      continue;
    }
    final id = Db.instance.insertItem(
      type: 'audio',
      title: p.basenameWithoutExtension(f.path),
      audioPath: dest,
      transcriptStatus: 'queued',
    );
    lastId = id;
    final ms = await probeDuration(dest);
    if (ms != null) Db.instance.setDuration(id, ms);
    Transcriber.instance.enqueue(id);
  }
  if (lastId != null) st.selectedId = lastId;
  st.bumpData();
}

Future<int?> probeDuration(String path) async {
  final pl = AudioPlayer();
  try {
    await pl.setSourceDeviceFile(path);
    final d = await pl.getDuration();
    return d?.inMilliseconds;
  } catch (_) {
    return null;
  } finally {
    await pl.dispose();
  }
}
