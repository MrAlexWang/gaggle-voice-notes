import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'db.dart';
import 'lan.dart';
import 'mobile_common.dart';
import 'mobile_transcribe.dart';
import 'sense_voice.dart';
import 'theme.dart';
import 'timeline.dart' show waveBars;
import 'transcriber.dart';
import 'widgets.dart';

/// 筛选：全部 / 录音 / 笔记 / 待转写
enum _Filter { all, audio, text, pending }

// ============================================================
// 手机端时间流
// ============================================================
class MobileTimeline extends StatefulWidget {
  const MobileTimeline({
    super.key,
    required this.onSettings,
    required this.onToChat,
  });

  final VoidCallback onSettings;

  /// 切到「AI 对话」页签（多选发给 AI 时用）
  final VoidCallback onToChat;

  @override
  State<MobileTimeline> createState() => _MobileTimelineState();
}

class _MobileTimelineState extends State<MobileTimeline> {
  final _searchCtrl = TextEditingController();
  String _kw = '';
  _Filter _filter = _Filter.all;
  bool _multi = false;
  final Set<String> _sel = {};
  int _version = -1;
  List<Item> _all = const [];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    _all = Db.instance.items(kw: _kw);
  }

  List<Item> get _visible {
    switch (_filter) {
      case _Filter.audio:
        return _all.where((e) => e.isAudio).toList();
      case _Filter.text:
        return _all.where((e) => !e.isAudio).toList();
      case _Filter.pending:
        return _all
            .where((e) => e.isAudio && e.transcriptStatus != 'done')
            .toList();
      case _Filter.all:
        return _all;
    }
  }

  void _setMulti(bool on) {
    setState(() {
      _multi = on;
      if (!on) _sel.clear();
    });
  }

  void _toggle(String id) {
    setState(() {
      if (_sel.contains(id)) {
        _sel.remove(id);
      } else {
        _sel.add(id);
      }
    });
  }

  Future<void> _openDetail(Item it) async {
    final st = AppScope.read(context);
    st.select(it.id);
    final r = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => MobileDetailPage(itemId: it.id)),
    );
    if (!mounted) return;
    if (r == 'ai') {
      st.pendingRefs = [it.id];
      widget.onToChat();
    } else {
      st.bumpData();
    }
  }



  Future<void> _deleteSelected() async {
    final ids = _sel.toList();
    if (ids.isEmpty) return;
    final ok = await showMobileConfirm(
      context,
      title: '删除 ${ids.length} 条？',
      desc: '删除后可在设置 → 回收站里恢复，保留 30 天。',
    );
    if (!mounted || !ok) return;
    for (final id in ids) {
      Db.instance.moveToTrash(id);
    }
    setState(() {
      _multi = false;
      _sel.clear();
    });
    AppScope.read(context).bumpData();
  }

  void _sendToAi() {
    final ids = _sel.toList();
    if (ids.isEmpty) return;
    final st = AppScope.read(context);
    st.pendingRefs = ids;
    setState(() {
      _multi = false;
      _sel.clear();
    });
    widget.onToChat();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 12.5)),
          backgroundColor: const Color(0xF20B2226),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 顶部「一键同步」：把所有还没同步过的录音和速记一次性传到电脑
  Future<void> _syncAll() async {
    final ids = pendingSyncIds();
    if (ids.isEmpty) {
      _toast('没有需要同步的内容');
      return;
    }
    _toast('正在同步 ${ids.length} 条内容到电脑…');
    final r = await uploadItemsToPc(ids);
    if (!mounted) return;
    AppScope.read(context).bumpData();
    if (r.noPc) {
      _toast('没找到电脑：请在同一 Wi-Fi 下打开电脑端雁书');
      return;
    }
    final parts = <String>[
      if (r.ok > 0) '已同步 ${r.ok} 条',
      if (r.failed > 0) '失败 ${r.failed} 条',
    ];
    _toast(parts.isEmpty ? '没有需要同步的内容' : parts.join(' · '));
  }

  /// 多选「重新上传」：把选中的录音再传一次（电脑端会标为重复）
  Future<void> _uploadSelected() async {
    final ids = _sel
        .where((id) {
          final it = Db.instance.byId(id);
          return it != null && it.isAudio && it.audioPath != null;
        })
        .toList();
    if (ids.isEmpty) {
      _toast('选中的内容里没有可上传的录音');
      return;
    }

    final ok = await showMobileConfirm(
      context,
      title: '重新上传 ${ids.length} 条录音？',
      desc: '会把选中的录音重新传一次到电脑，电脑端会多出标为「重复」的录音。',
      okLabel: '重新上传',
      cancelLabel: '取消',
      danger: false,
    );
    if (!ok || !mounted) return;

    setState(() {
      _multi = false;
      _sel.clear();
    });
    _toast('正在重新上传到电脑…');
    final r = await uploadItemsToPc(ids, includeUploaded: true);
    if (!mounted) return;
    AppScope.read(context).bumpData();
    if (r.noPc) {
      _toast('没找到电脑：请在同一 Wi-Fi 下打开电脑端雁书');
      return;
    }
    final parts = <String>[
      if (r.ok > 0) '已上传 ${r.ok} 条',
      if (r.skipped > 0) '跳过 ${r.skipped} 条（已传过）',
      if (r.failed > 0) '失败 ${r.failed} 条',
    ];
    _toast(parts.isEmpty ? '没有需要上传的录音' : parts.join(' · '));
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    if (st.dataVersion != _version) {
      _version = st.dataVersion;
      _reload();
    }
    final items = _visible;

    return Column(
      children: [
        // 标题行：设置在最左，右侧一键同步
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 10, 8),
          child: Row(
            children: [
              MobileIconBtn(
                icon: Icons.settings_outlined,
                onTap: widget.onSettings,
              ),
              const SizedBox(width: 4),
              const Text(
                '雁书',
                style: TextStyle(
                  fontSize: 20,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w600,
                  fontFamily: Palette.serifFamily,
                  fontFamilyFallback: Palette.serifFallback,
                  color: Palette.ink,
                ),
              ),
              const SizedBox(width: 9),
              const Text('Gaggle',
                  style: TextStyle(fontSize: 11, color: Palette.muted2)),
              const Spacer(),
              MobileBtn(
                label: '一键同步',
                height: 30,
                icon: Icons.cloud_upload_outlined,
                onTap: _syncAll,
              ),
            ],
          ),
        ),
        // 搜索
        Container(
          height: 38,
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Palette.line),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, size: 15, color: Palette.muted2),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() {
                    _kw = v;
                    _reload();
                  }),
                  style: const TextStyle(fontSize: 13, color: Palette.text),
                  cursorColor: Palette.gold,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '搜索转写内容…',
                    hintStyle: TextStyle(fontSize: 13, color: Color(0xFFB4BFBF)),
                    contentPadding: EdgeInsets.symmetric(vertical: 9),
                  ),
                ),
              ),
              if (_kw.isNotEmpty)
                MobileIconBtn(
                  icon: Icons.close,
                  size: 14,
                  onTap: () => setState(() {
                    _searchCtrl.clear();
                    _kw = '';
                    _reload();
                  }),
                ),
            ],
          ),
        ),
        // 筛选胶囊
        SizedBox(
          height: 28,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              MobilePill(
                label: '全部',
                active: _filter == _Filter.all,
                onTap: () => setState(() => _filter = _Filter.all),
              ),
              const SizedBox(width: 7),
              MobilePill(
                label: '录音',
                active: _filter == _Filter.audio,
                onTap: () => setState(() => _filter = _Filter.audio),
              ),
              const SizedBox(width: 7),
              MobilePill(
                label: '笔记',
                active: _filter == _Filter.text,
                onTap: () => setState(() => _filter = _Filter.text),
              ),
              const SizedBox(width: 7),
              MobilePill(
                label: '待转写',
                active: _filter == _Filter.pending,
                onTap: () => setState(() => _filter = _Filter.pending),
              ),
              const SizedBox(width: 7),
              MobilePill(
                label: _multi ? '退出多选' : '多选',
                active: _multi,
                onTap: () => _setMulti(!_multi),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 列表
        Expanded(
          child: Stack(
            children: [
              if (items.isEmpty)
                MobileEmptyHint(
                  icon: _kw.isEmpty ? Icons.mic_none : Icons.search_off,
                  title: _kw.isEmpty ? '还没有内容' : '没有匹配的内容',
                  desc: _kw.isEmpty ? '点下方金色按钮开始录音，或用右上角速记' : null,
                )
              else
                ListView.builder(
                  padding: EdgeInsets.fromLTRB(14, 2, 14, _multi ? 84 : 24),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _card(items[i]),
                ),
              if (_multi)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MobileActionBar(
                    label: '已选 ${_sel.length} 条',
                    actions: [
                      DarkMiniBtn(
                        label: _sel.length == items.length ? '清空' : '全选',
                        onTap: () => setState(() {
                          if (_sel.length == items.length) {
                            _sel.clear();
                          } else {
                            _sel
                              ..clear()
                              ..addAll(items.map((e) => e.id));
                          }
                        }),
                      ),
                      DarkMiniBtn(label: '重新上传', onTap: _uploadSelected),
                      DarkMiniBtn(label: '发给AI', onTap: _sendToAi),
                      DarkMiniBtn(
                          label: '删除', danger: true, onTap: _deleteSelected),
                      DarkMiniBtn(label: '取消', onTap: () => _setMulti(false)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _card(Item it) {
    final selected = _sel.contains(it.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: () {
          if (_multi) {
            _toggle(it.id);
          } else {
            _openDetail(it);
          }
        },
        onLongPress: () {
          if (!_multi) {
            setState(() {
              _multi = true;
              _sel.clear();
            });
          }
          _toggle(it.id);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(13, 13, 14, 13),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: selected ? Palette.ink : Palette.line),
            borderRadius: BorderRadius.circular(14),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Palette.ink.withOpacity(0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_multi) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 9),
                  child: CheckSquare(checked: selected),
                ),
                const SizedBox(width: 8),
              ],
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: it.isAudio ? Palette.goldBg : Palette.textIcBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  it.isAudio ? Icons.mic_none : Icons.edit_outlined,
                  size: 17,
                  color: it.isAudio ? Palette.gold : Palette.textIc,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      it.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                        color: Palette.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          it.isAudio
                              ? fmtDurMs(it.durationMs)
                              : '${it.charCount ?? 0} 字',
                          style: const TextStyle(
                              fontSize: 11.5, color: Palette.muted2),
                        ),
                        const Text('·',
                            style: TextStyle(
                                fontSize: 11.5, color: Palette.muted2)),
                        Text(
                          fmtClock(it.createdAt),
                          style: const TextStyle(
                              fontSize: 11.5, color: Palette.muted2),
                        ),
                        // 手机端只关心手机上的内容，电脑来源不再占位显示
                        if (it.sourceDevice != 'pc')
                          DeviceBadge(device: it.sourceDevice),
                        if (it.isAudio)
                          StatusBadge(status: it.transcriptStatus),
                        // 手机产生的录音/速记显示同步状态（电脑自己的内容本来就在电脑上）
                        if (it.uploaded)
                          const UploadedBadge()
                        else if (it.sourceDevice == 'phone')
                          const UnsyncedBadge(),
                        if (it.isDuplicate) const DuplicateBadge(),
                      ],
                    ),
                    const SizedBox(height: 7),
                    highlightedText(
                      mobileSnip(it),
                      _kw,
                      maxLines: 2,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6C7E82),
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 手机端速记（底部抽屉，纯文字）
// ============================================================
Future<bool> showMobileNoteSheet(BuildContext context) async {
  final ctrl = TextEditingController();
  final focus = FocusNode();
  final st = AppScope.read(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x660B2226),
    builder: (ctx) {
      // 按原型：近似全屏的编辑器（状态栏以下整块）
      // 键盘弹出时整体上移，输入区不会被输入法挡住
      final mq = MediaQuery.of(ctx);
      final kb = mq.viewInsets.bottom;
      final height = mq.size.height - kb - 46;
      final box = Container(
        height: height < 300 ? 300 : height,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetGrabber(),
            const SizedBox(height: 10),
            const Text('速记',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            const Text('纯文字记录 · 不录音',
                style: TextStyle(fontSize: 11.5, color: Palette.muted2)),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Palette.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: ctrl,
                  focusNode: focus,
                  autofocus: true,
                  maxLines: null,
                  minLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 15.5, height: 1.75),
                  cursorColor: Palette.gold,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '想到什么就写下来…',
                    hintStyle:
                        TextStyle(fontSize: 15.5, color: Color(0xFFB4BFBF)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 10,
                  child: MobileBtn(
                      label: '取消', height: 42, onTap: () => Navigator.pop(ctx)),
                ),
                const SizedBox(width: 9),
                Expanded(
                  flex: 16,
                  child: MobileBtn(
                    label: '保存',
                    height: 42,
                    solid: true,
                    onTap: () => Navigator.pop(ctx, true),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      // 键盘高度变化时平滑上移，保证输入框始终可见
      return AnimatedPadding(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: kb),
        child: box,
      );
    },
  );

  final text = ctrl.text.trim();
  focus.dispose();
  ctrl.dispose();
  if (ok != true || text.isEmpty) return false;
  final id = Db.instance.insertItem(
    type: 'text',
    title: text.length > 18 ? '${text.substring(0, 18)}…' : text,
    body: text,
    charCount: text.length,
    sourceDevice: 'phone',
  );
  st.select(id);
  st.bumpData();
  return true;
}

// ============================================================
// 手机端详情页
// ============================================================
class MobileDetailPage extends StatefulWidget {
  const MobileDetailPage({super.key, required this.itemId});

  final String itemId;

  @override
  State<MobileDetailPage> createState() => _MobileDetailPageState();
}

class _MobileDetailPageState extends State<MobileDetailPage> {
  final _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];

  late Item _item;
  List<Map<String, Object?>> _segs = const [];
  List<String> _tags = const [];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  bool _ready = false;
  bool _uploading = false;
  bool _localRunning = false;

  @override
  void initState() {
    super.initState();
    _item = Db.instance.byId(widget.itemId)!;
    _segs = Db.instance.segments(_item.id);
    _tags = Db.instance.tags(_item.id);
    Transcriber.instance.progress.addListener(_onProgress);
    _bind();
  }

  void _onProgress() {
    final p = Transcriber.instance.progress.value;
    if (!mounted) return;
    if (p == null || p.itemId == _item.id) _refresh();
  }

  void _refresh() {
    final it = Db.instance.byId(_item.id);
    if (it == null) return;
    setState(() {
      _item = it;
      _segs = Db.instance.segments(it.id);
      _tags = Db.instance.tags(it.id);
    });
  }

  Future<void> _bind() async {
    if (!_item.isAudio || _item.audioPath == null) return;
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
      await _player.setSourceDeviceFile(_item.audioPath!);
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
    Transcriber.instance.progress.removeListener(_onProgress);
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

  Future<void> _seek(int ms) async {
    if (!_ready) return;
    final d = Duration(milliseconds: ms);
    await _player.seek(d);
    if (mounted) setState(() => _pos = d);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 12.5)),
          backgroundColor: const Color(0xF20B2226),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 交给电脑转写（手机端没有本地模型时）
  Future<void> _uploadToPc() async {
    final path = _item.audioPath;
    if (path == null || _uploading) return;
    // 已经传过：需要用户明确确认才重复上传
    if (_item.uploaded) {
      final again = await showMobileConfirm(
        context,
        title: '这条已经上传过',
        desc: '重复上传会在电脑端多出一条标为「重复」的录音。',
        okLabel: '重复上传',
        cancelLabel: '取消',
        danger: false,
      );
      if (!again) return;
    }
    if (!mounted) return;
    setState(() => _uploading = true);
    Db.instance.setStatus(_item.id, 'running');
    // 立刻把状态同步到界面，避免徽章还停在「失败」而下面是上传中
    _refresh();
    final segs = await LanClient.instance.uploadTranscribe(
      path,
      durationMs: _item.durationMs,
    );
    if (!mounted) return;
    if (segs == null || segs.isEmpty) {
      Db.instance.setStatus(_item.id, 'failed');
      setState(() => _uploading = false);
      _refresh();
      _toast('转写失败：请确认电脑端雁书在线且在同一 Wi-Fi');
    } else {
      Db.instance.saveSegments(_item.id, segs);
      Db.instance.markUploaded(_item.id);
      setState(() => _uploading = false);
      _refresh();
      AppScope.read(context).bumpData();
      _toast('已上传完成');
    }
  }

  /// 用手机上的 SenseVoice-Small 离线转写
  Future<void> _localTranscribe() async {
    if (_localRunning || _uploading) return;
    setState(() => _localRunning = true);
    final err = await SenseVoice.instance.transcribeItem(
      _item.id,
      onPartial: () {
        if (mounted) _refresh();
      },
    );
    if (!mounted) return;
    setState(() => _localRunning = false);
    _refresh();
    AppScope.read(context).bumpData();
    _toast(err == null ? '转写完成' : '本机转写失败：$err');
  }

  Future<void> _editSegment(int start, String text) async {
    final v = await showMobileInput(
      context,
      title: '修改这一段',
      desc: '保存后会重建该条目的检索索引',
      initial: text,
      maxLines: 6,
    );
    if (!mounted || v == null || v.isEmpty) return;
    Db.instance.updateSegmentText(_item.id, start, v);
    _refresh();
    AppScope.read(context).bumpData();
  }

  Future<void> _rename() async {
    final v = await showMobileInput(
      context,
      title: '重命名',
      initial: _item.title,
      hint: '标题',
    );
    if (!mounted || v == null || v.isEmpty) return;
    Db.instance.rename(_item.id, v);
    _refresh();
    AppScope.read(context).bumpData();
  }

  Future<void> _editBody() async {
    final v = await showMobileInput(
      context,
      title: '编辑正文',
      desc: '保存后会重建检索索引',
      initial: _item.body ?? '',
      maxLines: 12,
    );
    if (!mounted || v == null || v.isEmpty) return;
    Db.instance.updateBodyText(_item.id, v);
    _refresh();
    AppScope.read(context).bumpData();
  }

  Future<void> _addTag() async {
    final existed = Db.instance.allTags().take(6).toList();
    final v = await showMobileInput(
      context,
      title: '添加标签',
      desc: existed.isEmpty
          ? '可用逗号一次加多个，例如：产品评审, 待办'
          : '可用逗号一次加多个 · 已有：${existed.join('、')}',
      hint: '标签名',
    );
    if (!mounted || v == null || v.isEmpty) return;
    for (final t in v.split(RegExp(r'[,，、\s]+'))) {
      if (t.trim().isNotEmpty) Db.instance.addTag(_item.id, t);
    }
    _refresh();
    AppScope.read(context).bumpData();
  }

  Future<void> _delete() async {
    final ok = await showMobileConfirm(
      context,
      title: '删除这条？',
      desc: '删除后可在设置 → 回收站里恢复，保留 30 天。',
    );
    if (!mounted || !ok) return;
    Db.instance.moveToTrash(_item.id);
    AppScope.read(context).bumpData();
    Navigator.pop(context);
  }

  Future<void> _renameSpeaker(String from) async {
    final v = await showMobileInput(
      context,
      title: '改说话人名字',
      desc: '该条目下所有「$from」都会一起改',
      initial: from,
      hint: '例如：我 / 李工 / 小王',
    );
    if (!mounted || v == null || v.isEmpty || v == from) return;
    Db.instance.renameSpeaker(_item.id, from, v);
    _refresh();
  }

  Future<void> _showMore() async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x660B2226),
      builder: (ctx) => Container(
        decoration: mobileSheetDecoration,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabber(),
            const SizedBox(height: 6),
            _sheetItem(Icons.drive_file_rename_outline, '重命名', 'rename'),
            if (!_item.isAudio)
              _sheetItem(Icons.edit_outlined, '编辑正文', 'body'),
            _sheetItem(Icons.auto_awesome, 'AI 分析', 'ai'),
            _sheetItem(Icons.sell_outlined, '添加标签', 'tag'),
            if (_item.isAudio)
              _sheetItem(
                Icons.cloud_upload_outlined,
                _item.transcriptStatus == 'done' ? '重新上传电脑转写' : '上传电脑转写',
                'upload',
              ),
            _sheetItem(Icons.delete_outline, '删除', 'delete', danger: true),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (act) {
      case 'rename':
        await _rename();
        break;
      case 'body':
        await _editBody();
        break;
      case 'ai':
        Navigator.pop(context, 'ai');
        break;
      case 'tag':
        await _addTag();
        break;
      case 'upload':
        await _uploadToPc();
        break;
      case 'delete':
        await _delete();
        break;
    }
  }

  Widget _sheetItem(IconData icon, String label, String value,
      {bool danger = false}) {
    final color = danger ? Palette.red : Palette.text;
    return Pressable(
      onTap: () => Navigator.pop(context, value),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 14, color: color)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.paper,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶栏
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  MobileIconBtn(
                    icon: Icons.chevron_left,
                    size: 22,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 2),
                  const Text('详细信息',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                  const Spacer(),
                  MobileIconBtn(
                    icon: Icons.more_vert,
                    size: 20,
                    onTap: _showMore,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            _head(),
            if (_item.isAudio) _playerCard(),
            if (_item.isAudio) _speakerBar(),
            Expanded(
              child: _item.isAudio
                  ? (_segs.isEmpty ? _emptyTranscript() : _segmentList())
                  : _textBody(),
            ),
            if (!_item.isAudio) _textActions(),
          ],
        ),
      ),
    );
  }

  Widget _head() {
    final it = _item;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                it.title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                  color: Palette.text,
                ),
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    it.isAudio
                        ? fmtDurMs(it.durationMs)
                        : '${it.charCount ?? 0} 字',
                    style: const TextStyle(
                        fontSize: 11.5, color: Palette.muted2),
                  ),
                  const Text('·',
                      style:
                          TextStyle(fontSize: 11.5, color: Palette.muted2)),
                  Text(fmtClock(it.createdAt),
                      style: const TextStyle(
                          fontSize: 11.5, color: Palette.muted2)),
                  if (it.sourceDevice != 'pc')
                    DeviceBadge(device: it.sourceDevice),
                  if (it.isAudio) StatusBadge(status: it.transcriptStatus),
                  if (it.uploaded)
                    const UploadedBadge()
                  else if (it.sourceDevice == 'phone')
                    const UnsyncedBadge(),
                  if (it.isDuplicate) const DuplicateBadge(),
                ],
              ),
              if (_tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in _tags)
                      TagChip(
                        tag: t,
                        dense: true,
                        onRemove: () {
                          Db.instance.removeTag(_item.id, t);
                          _refresh();
                          AppScope.read(context).bumpData();
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _playerCard() {
    final total = _dur.inMilliseconds <= 0 ? 1 : _dur.inMilliseconds;
    final progress = (_pos.inMilliseconds / total).clamp(0.0, 1.0);
    const barCount = 46;
    final bars = waveBars(_item.id, barCount);
    final on = (progress * barCount).round();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Pressable(
                onTap: _toggle,
                scale: 0.92,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: Palette.ink,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _playing ? Icons.pause : Icons.play_arrow_rounded,
                    size: 20,
                    color: const Color(0xFFF3EEE4),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, cons) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) {
                        final ratio =
                            (d.localPosition.dx / cons.maxWidth).clamp(0.0, 1.0);
                        _seek((ratio * total).round());
                      },
                      child: SizedBox(
                        height: 34,
                        child: Row(
                          children: List.generate(barCount, (i) {
                            return Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 1),
                                child: Container(
                                  height: 4 + bars[i] * 30,
                                  decoration: BoxDecoration(
                                    gradient: i < on
                                        ? const LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Color(0xFFD9A94F),
                                              Color(0xFFB9792F)
                                            ],
                                          )
                                        : null,
                                    color: i < on
                                        ? null
                                        : const Color(0xFFD9D3C7),
                                    borderRadius: BorderRadius.circular(2),
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
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Text(
                fmtSec(_pos),
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Palette.muted2,
                  fontFamily: Palette.monoFamily,
                  fontFamilyFallback: Palette.monoFallback,
                ),
              ),
              const Spacer(),
              Text(
                fmtSec(_dur),
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Palette.muted2,
                  fontFamily: Palette.monoFamily,
                  fontFamilyFallback: Palette.monoFallback,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _speakerBar() {
    final share = <String, int>{};
    var totalDur = 0;
    for (final s in _segs) {
      final sp = s['speaker'] as String?;
      final d = ((s['end'] as int?) ?? 0) - ((s['start'] as int?) ?? 0);
      totalDur += d > 0 ? d : 0;
      if (sp == null) continue;
      share[sp] = (share[sp] ?? 0) + (d > 0 ? d : 0);
    }
    if (share.isEmpty) return const SizedBox.shrink();
    final names = share.keys.toList();
    return SizedBox(
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: names.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (_, i) {
          final name = names[i];
          final pct =
              totalDur > 0 ? (share[name]! * 100 / totalDur).round() : 0;
          return SpeakerChip(
            name: name,
            percent: pct,
            index: i,
            onTap: () => _renameSpeaker(name),
          );
        },
      ),
    );
  }

  Widget _segmentList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
      itemCount: _segs.length,
      itemBuilder: (_, i) {
        final s = _segs[i];
        final start = (s['start'] as int?) ?? 0;
        final text = (s['text'] as String?) ?? '';
        final spk = s['speaker'] as String?;
        final cur = _pos.inMilliseconds >= start &&
            (i + 1 >= _segs.length ||
                _pos.inMilliseconds <
                    ((_segs[i + 1]['start'] as int?) ?? 1 << 30));
        return Pressable(
          onTap: () => _seek(start),
          onLongPress: () => _editSegment(start, text),
          scale: 0.994,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            decoration: BoxDecoration(
              color: cur ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: cur
                  ? [
                      const BoxShadow(
                          color: Palette.line,
                          blurRadius: 0,
                          offset: Offset(0, 1)),
                    ]
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 40,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      fmtSec(Duration(milliseconds: start)),
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Palette.muted2,
                        fontFamily: Palette.monoFamily,
                        fontFamilyFallback: Palette.monoFallback,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (spk != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Palette.goldBg,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(spk,
                              style: const TextStyle(
                                  fontSize: 10, color: Palette.goldDeep)),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.7,
                          color: cur ? Palette.text : Palette.textBody,
                        ),
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
  }

  Widget _emptyTranscript() {
    final localReady = TranscribeRoute.localReady;
    final usingLocal = _localRunning ||
        (TranscribeRoute.usesPhone && localReady && !_uploading);
    final running =
        _uploading || _localRunning || _item.transcriptStatus == 'running';
    if (running) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Palette.gold),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              usingLocal ? '正在用本机小模型转写…' : '正在上传到电脑转写…',
              style: const TextStyle(fontSize: 13, color: Palette.muted2),
            ),
            const SizedBox(height: 6),
            Text(
              usingLocal ? 'SenseVoice-Small · 全程离线' : '电脑端雁书需在同一 Wi-Fi 下运行',
              style: const TextStyle(fontSize: 11.5, color: Palette.muted2),
            ),
          ],
        ),
      );
    }
    final failed = _item.transcriptStatus == 'failed';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(failed ? Icons.cloud_off : Icons.text_snippet_outlined,
                size: 30, color: Palette.muted2),
            const SizedBox(height: 12),
            Text(failed ? '转写失败' : '尚未转写',
                style:
                    const TextStyle(fontSize: 13.5, color: Palette.muted2)),
            const SizedBox(height: 6),
            Text(
              localReady
                  ? 'SenseVoice-Small 已就绪，可以直接在本机离线转写'
                  : '可在设置里下载 SenseVoice-Small 小模型，或上传电脑转写',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 11.5, color: Palette.muted2, height: 1.7),
            ),
            const SizedBox(height: 16),
            if (localReady) ...[
              MobileBtn(
                label: '本机转写（${TranscribeRoute.localEngineName}）',
                solid: true,
                icon: Icons.auto_awesome,
                onTap: _localTranscribe,
              ),
              const SizedBox(height: 9),
            ],
            MobileBtn(
              label: '上传电脑转写',
              solid: !localReady,
              icon: Icons.cloud_upload_outlined,
              onTap: _uploadToPc,
            ),
          ],
        ),
      ),
    );
  }

  Widget _textBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Palette.line),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('正文',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Palette.muted,
                        letterSpacing: 0.8,
                      )),
                  const Spacer(),
                  MobileBtn(
                    label: '编辑',
                    height: 28,
                    icon: Icons.edit_outlined,
                    onTap: _editBody,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SelectableText(
                _item.body ?? '',
                style: const TextStyle(
                    fontSize: 14, height: 1.8, color: Palette.textBody),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 文字条目底部：加标签 + AI 分析
  Widget _textActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Row(
        children: [
          MobileBtn(
            label: _tags.isEmpty ? '添加标签' : '再加标签',
            height: 34,
            icon: Icons.add,
            onTap: _addTag,
          ),
          const Spacer(),
          MobileBtn(
            label: 'AI 分析',
            height: 34,
            icon: Icons.auto_awesome,
            onTap: () => Navigator.pop(context, 'ai'),
          ),
        ],
      ),
    );
  }
}
