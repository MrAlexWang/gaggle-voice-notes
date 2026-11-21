import 'dart:async';

import 'package:flutter/material.dart';

import 'a2a.dart' show A2aAgent;
import 'app_state.dart';
import 'chat.dart' show buildCorpus;
import 'db.dart';
import 'lan.dart';
import 'mobile_common.dart';
import 'mobile_timeline.dart' show MobileDetailPage;
import 'theme.dart';
import 'widgets.dart';

// ============================================================
// 手机端 AI 对话（经电脑端中继调用 A2A Agent）
// ============================================================
class MobileChat extends StatefulWidget {
  const MobileChat({
    super.key,
    required this.onSettings,
    this.active = false,
  });

  final VoidCallback onSettings;

  /// 当前是否停留在对话页签：切回来时若未连电脑会重新找一次
  final bool active;

  @override
  State<MobileChat> createState() => _MobileChatState();
}

class _MobileChatState extends State<MobileChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();

  List<_Conv> _convs = const [];
  String? _activeId;
  List<Map<String, Object?>> _msgs = const [];
  List<String> _refs = const [];

  bool _discovering = true;
  A2aAgent? _agent;
  bool _sending = false;
  String _streaming = '';

  /// 正在流式回复的是哪个会话（切到别的会话时不串内容）
  String? _streamConvId;
  StreamSubscription<String>? _sub;

  /// 发出提问后迟迟没有回包时的兜底计时器
  Timer? _replyGuard;

  @override
  void initState() {
    super.initState();
    _loadConvs();
    _discover();
  }

  @override
  void didUpdateWidget(covariant MobileChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每次切回对话页都重新确认一次连接与智能体状态（可能要等电脑端启动）
    if (!oldWidget.active && widget.active && !_discovering) {
      _discover();
    }
  }

  @override
  void dispose() {
    _replyGuard?.cancel();
    _sub?.cancel();
    _inputFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _connected => _agent != null;

  Future<void> _discover() async {
    setState(() => _discovering = true);
    final agents = await LanClient.instance.fetchAgents();
    if (!mounted) return;
    setState(() {
      _discovering = false;
      _agent = agents.isEmpty ? null : agents.first;
    });
  }

  void _loadConvs() {
    _convs = Db.instance.conversations().map((r) {
      final id = r['id'] as String;
      return _Conv(
        id: id,
        title: r['title'] as String,
        meta: _metaText(Db.instance.convRefs(id).length, r['createdAt'] as int?),
      );
    }).toList();
    if (_activeId != null && !_convs.any((c) => c.id == _activeId)) {
      _activeId = _convs.isEmpty ? null : _convs.first.id;
    }
    _activeId ??= _convs.isEmpty ? null : _convs.first.id;
    _reloadMessages();
  }

  void _reloadMessages() {
    final id = _activeId;
    _msgs = id == null ? const [] : Db.instance.messages(id);
    _refs = id == null ? const [] : Db.instance.convRefs(id);
  }

  String _metaText(int refCount, int? createdAt) {
    final d = DateTime.fromMillisecondsSinceEpoch(
        createdAt ?? DateTime.now().millisecondsSinceEpoch);
    final now = DateTime.now();
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final t = sameDay ? '今天 $hm' : '${d.month}-${d.day} $hm';
    return refCount > 0 ? '引用 $refCount 条 · $t' : t;
  }

  String _titleFromRefs(List<String> refs) {
    if (refs.isEmpty) return '新对话';
    final first = Db.instance.byId(refs.first)?.title ?? '新对话';
    final short = first.length > 12 ? '${first.substring(0, 12)}…' : first;
    return refs.length > 1
        ? 'AI 分析 · $short 等 ${refs.length} 条'
        : 'AI 分析 · $short';
  }

  String _newConvId() => 'c${DateTime.now().microsecondsSinceEpoch}';

  void _createConvWithRefs(List<String> refs) {
    final id = _newConvId();
    Db.instance.upsertConversation(
      id: id,
      title: _titleFromRefs(refs),
      meta: _metaText(refs.length, DateTime.now().millisecondsSinceEpoch),
      contextId: 'ctx-$id',
    );
    Db.instance.setConvRefs(id, refs);
    setState(() {
      _activeId = id;
      _loadConvs();
    });
    _toBottom();
  }

  void _newConv() {
    final id = _newConvId();
    Db.instance.upsertConversation(
      id: id,
      title: '新对话',
      meta: _metaText(0, DateTime.now().millisecondsSinceEpoch),
      contextId: 'ctx-$id',
    );
    setState(() {
      _activeId = id;
      _loadConvs();
    });
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
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

  Future<void> _stop() async {
    _replyGuard?.cancel();
    _replyGuard = null;
    await _sub?.cancel();
    _sub = null;
    final id = _streamConvId ?? _activeId;
    if (_streaming.isNotEmpty && id != null) {
      Db.instance.addMessage(id, 'agent', _streaming);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _streaming = '';
      _streamConvId = null;
      _reloadMessages();
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;

    if (!_connected) {
      _toast('未连接电脑：请在同一 Wi-Fi 下打开电脑端雁书');
      return;
    }
    // 发送前强制刷新一次，避免用上一步的过期状态误判
    await LanClient.instance.refreshStatus();
    if (!mounted) return;
    setState(() {});
    final issue = LanClient.instance.agentIssue;
    if (issue != null) {
      _toast(issue);
      return;
    }

    var id = _activeId;
    if (id == null) {
      _newConv();
      id = _activeId;
      if (id == null) return;
    }

    final refs = Db.instance.convRefs(id);
    final corpusItems = <Map<String, String>>[];
    for (final rid in refs) {
      final it = Db.instance.byId(rid);
      if (it == null) continue;
      final segs = Db.instance.segments(rid);
      final body = segs.isNotEmpty
          ? segs.map((s) => s['text'] as String? ?? '').join(' ')
          : (it.body ?? '');
      corpusItems.add({
        'title': it.title,
        'time': fmtClock(it.createdAt),
        'text': body,
      });
    }
    final prompt = corpusItems.isEmpty
        ? text
        : '${buildCorpus(corpusItems)}\n\n用户问题：$text';

    final msgId = Db.instance.addMessage(id, 'user', text);
    if (refs.isNotEmpty) Db.instance.setMessageRefs(msgId, refs);
    // 引用已经随这条消息存下来了：输入框上方的链接条发完就收掉，不重复显示
    if (refs.isNotEmpty) Db.instance.setConvRefs(id, const []);

    // 新对话用第一条问题当标题
    for (final c in _convs) {
      if (c.id == id && c.title == '新对话') {
        Db.instance.touchConversation(
          id,
          title: text.length > 14 ? '${text.substring(0, 14)}…' : text,
          meta: c.meta,
        );
        break;
      }
    }

    setState(() {
      _input.clear();
      _sending = true;
      _streaming = '';
      _streamConvId = id;
      _loadConvs();
    });
    _toBottom();

    final convId = id;
    _sub = LanClient.instance
        .chatStream(
      text: prompt,
      contextId: 'ctx-$convId',
    )
        .listen(
      (delta) {
        if (!mounted) return;
        setState(() => _streaming += delta);
        _toBottom();
      },
      onError: (Object e) {
        _replyGuard?.cancel();
        _replyGuard = null;
        final failed = _streaming.isEmpty ? '调用失败：$e' : _streaming;
        Db.instance.addMessage(convId, 'agent', failed);
        if (!mounted) return;
        setState(() {
          _sending = false;
          _streaming = '';
          _streamConvId = null;
          _loadConvs();
        });
        _toBottom();
      },
      onDone: () {
        _replyGuard?.cancel();
        _replyGuard = null;
        if (_streaming.isNotEmpty) {
          Db.instance.addMessage(convId, 'agent', _streaming);
        } else {
          Db.instance.addMessage(
            convId,
            'agent',
            '电脑智能体没有返回内容：请确认电脑端雁书与 Agent 正在运行。',
          );
        }
        if (!mounted) return;
        setState(() {
          _sending = false;
          _streaming = '';
          _streamConvId = null;
          _loadConvs();
        });
        _toBottom();
      },
      cancelOnError: true,
    );

    // 一直没回包时给个明确结果，避免界面永远停在「处理中」
    _replyGuard?.cancel();
    _replyGuard = Timer(const Duration(seconds: 75), () {
      if (!mounted || !_sending || _streaming.isNotEmpty) return;
      _sub?.cancel();
      _sub = null;
      Db.instance.addMessage(
        convId,
        'agent',
        '电脑智能体没有回应：请确认电脑端雁书与 Agent 正在运行，再重新发送。',
      );
      setState(() {
        _sending = false;
        _streaming = '';
        _streamConvId = null;
        _loadConvs();
      });
      _toBottom();
    });
  }

  Future<void> _openConvSheet() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x660B2226),
      isScrollControlled: true,
      builder: (_) => _ConvSheet(activeId: _activeId, metas: _convs),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() {
        _activeId = picked;
        _loadConvs();
      });
      _toBottom();
    } else {
      setState(_loadConvs);
    }
  }

  void _removeRef(String id) {
    final conv = _activeId;
    if (conv == null) return;
    final next = _refs.where((e) => e != id).toList();
    Db.instance.setConvRefs(conv, next);
    setState(() => _refs = next);
  }

  void _openItem(String id) {
    final it = Db.instance.byId(id);
    if (it == null) {
      _toast('这条内容已被删除');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MobileDetailPage(itemId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    // 时间流「发给 AI」→ 新建带引用的会话
    if (st.pendingRefs.isNotEmpty) {
      final refs = List<String>.from(st.pendingRefs);
      st.pendingRefs = [];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _createConvWithRefs(refs);
      });
    }

    return Column(
      children: [
        _header(),
        Expanded(child: _body()),
        if (_refs.isNotEmpty) _refBar(),
        _composer(),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 8, 8),
      child: Row(
        children: [
          const Text('AI 对话',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: Palette.text,
              )),
          const Spacer(),
          MobileIconBtn(
            icon: Icons.view_agenda_outlined,
            onTap: _openConvSheet,
          ),
          const SizedBox(width: 2),
          MobileIconBtn(
            icon: Icons.settings_outlined,
            onTap: widget.onSettings,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_discovering) {
      return const MobileEmptyHint(
        icon: Icons.wifi_find,
        title: '正在寻找电脑…',
        desc: '手机与电脑需在同一 Wi-Fi 下',
      );
    }

    return Column(
      children: [
        _linkBar(),
        Expanded(
          child: !_connected
              ? _offline()
              : (_msgs.isEmpty && !(_sending && _streamConvId == _activeId))
                  ? const MobileEmptyHint(
                      icon: Icons.chat_bubble_outline,
                      title: '问点什么',
                      desc: '可以在时间流多选内容发给 AI，作为对话上下文',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      // 只在发起回复的那个会话里显示流式气泡
                      itemCount: _msgs.length +
                          (_sending && _streamConvId == _activeId ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i >= _msgs.length) {
                          return _bubble({
                            'role': 'agent',
                            'text': _streaming.isEmpty
                                ? '电脑智能体正在处理…'
                                : '$_streaming▌',
                            'refs': const <String>[],
                          });
                        }
                        return _bubble(_msgs[i]);
                      },
                    ),
        ),
      ],
    );
  }

  /// 未连接电脑时的空态（原型 .poffempty）
  Widget _offline() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off, size: 30, color: Palette.muted2),
          const SizedBox(height: 12),
          const Text('未连接电脑',
              style: TextStyle(fontSize: 14, color: Palette.text)),
          const SizedBox(height: 8),
          const Text(
            '请在同一 Wi-Fi 下打开电脑端的雁书',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 12.5, color: Palette.muted2, height: 1.8),
          ),
          const SizedBox(height: 4),
          const Text('录音、转写、检索不受影响',
              style: TextStyle(fontSize: 11.5, color: Color(0xFFB4BFBF))),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              MobileBtn(
                label: '重新连接',
                icon: Icons.refresh,
                onTap: _discover,
              ),
              const SizedBox(width: 9),
              MobileBtn(
                label: '去设置',
                onTap: widget.onSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _linkBar() {
    final addr = LanClient.instance.targetAddress;
    final server = LanClient.instance.serverName;
    final who = server != null && server.isNotEmpty ? server : (addr ?? '电脑');
    final issue = LanClient.instance.agentIssue;
    // 极度精简：只说状态，主机名/协议这些细节不占地方
    final label = !_connected
        ? '未连接电脑'
        : issue ?? (_sending ? '智能体处理中…' : '电脑智能体已就绪');
    final on = _connected && issue == null;
    return Pressable(
      onTap: _discover,
      scale: 0.995,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: on ? Palette.greenBg : Palette.redBg,
          border: Border.all(color: on ? Palette.greenLine : Palette.redLine),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: on ? Palette.green : Palette.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: on ? Palette.green : Palette.red,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _refBar() {
    return SizedBox(
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _refs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final it = Db.instance.byId(_refs[i]);
          final label = it?.title ?? '（已删除）';
          return Container(
            height: 26,
            padding: const EdgeInsets.only(left: 9, right: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Palette.line),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: Palette.text),
                  ),
                ),
                const SizedBox(width: 6),
                Pressable(
                  onTap: () => _removeRef(_refs[i]),
                  scale: 0.85,
                  child: const Icon(Icons.close,
                      size: 13, color: Palette.muted2),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      color: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(13, 8, 8, 8),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Palette.line),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 13.5, height: 1.6),
                      cursorColor: Palette.gold,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '问点什么…',
                        hintStyle:
                            TextStyle(fontSize: 13.5, color: Palette.muted2),
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Pressable(
                    onTap: _sending ? _stop : _send,
                    scale: 0.92,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _sending ? Palette.red : Palette.ink,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        _sending
                            ? Icons.stop_rounded
                            : Icons.arrow_forward_rounded,
                        size: 17,
                        color: const Color(0xFFF3EEE4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(Map<String, Object?> m) {
    final isUser = m['role'] == 'user';
    final refs = (m['refs'] as List?)?.cast<String>() ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.86,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: isUser ? Palette.ink : Colors.white,
            border: isUser ? null : Border.all(color: Palette.line),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(isUser ? 14 : 5),
              bottomRight: Radius.circular(isUser ? 5 : 14),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (m['text'] as String?) ?? '',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.72,
                  color: isUser ? const Color(0xFFF0EBE1) : Palette.text,
                ),
              ),
              if (refs.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 5,
                  children: [
                    for (final id in refs) _refLink(id, isUser),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _refLink(String id, bool onDark) {
    final it = Db.instance.byId(id);
    final label = it?.title ?? '（已删除）';
    final tail = it == null
        ? ''
        : (it.isAudio ? fmtDurMs(it.durationMs) : '${it.charCount ?? 0} 字');
    final color = onDark ? Palette.goldSoft : Palette.blue;
    return Pressable(
      onTap: () => _openItem(id),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link, size: 12, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              tail.isEmpty ? label : '$label · $tail',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: color,
                decoration: TextDecoration.underline,
                decorationColor: color.withOpacity(0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Conv {
  _Conv({required this.id, required this.title, required this.meta});

  final String id;
  final String title;
  final String meta;
}

// ============================================================
// 会话列表抽屉
// ============================================================
class _ConvSheet extends StatefulWidget {
  const _ConvSheet({required this.activeId, required this.metas});

  final String? activeId;
  final List<_Conv> metas;

  @override
  State<_ConvSheet> createState() => _ConvSheetState();
}

class _ConvSheetState extends State<_ConvSheet> {
  List<_Conv> _list = const [];
  bool _multi = false;
  final Set<String> _sel = {};

  String? _renamingId;
  final _renameCtrl = TextEditingController();
  final _renameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _load();
    _renameFocus.addListener(() {
      if (!_renameFocus.hasFocus && _renamingId != null) _commitRename();
    });
  }

  @override
  void dispose() {
    _renameCtrl.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  void _load() {
    final metas = {for (final m in widget.metas) m.id: m.meta};
    _list = Db.instance.conversations().map((r) {
      final id = r['id'] as String;
      return _Conv(
        id: id,
        title: r['title'] as String,
        meta: metas[id] ??
            _metaText(
                Db.instance.convRefs(id).length, r['createdAt'] as int?),
      );
    }).toList();
  }

  String _metaText(int refCount, int? createdAt) {
    final d = DateTime.fromMillisecondsSinceEpoch(
        createdAt ?? DateTime.now().millisecondsSinceEpoch);
    final now = DateTime.now();
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final t = sameDay ? '今天 $hm' : '${d.month}-${d.day} $hm';
    return refCount > 0 ? '引用 $refCount 条 · $t' : t;
  }

  void _beginRename(_Conv c) {
    setState(() {
      _renamingId = c.id;
      _renameCtrl.text = c.title;
      _renameCtrl.selection =
          TextSelection(baseOffset: 0, extentOffset: c.title.length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameFocus.requestFocus();
    });
  }

  void _commitRename() {
    final id = _renamingId;
    if (id == null) return;
    final v = _renameCtrl.text.trim();
    _renamingId = null;
    if (_renameFocus.hasFocus) _renameFocus.unfocus();
    if (v.isNotEmpty) Db.instance.renameConversation(id, v);
    if (!mounted) return;
    setState(_load);
  }

  Future<void> _deleteOne(_Conv c) async {
    final ok = await showMobileConfirm(
      context,
      title: '删除会话？',
      desc: '会话记录删除后不可恢复，录音与笔记不受影响。',
    );
    if (!mounted || !ok) return;
    Db.instance.deleteConversations([c.id]);
    setState(_load);
  }

  Future<void> _deleteSelected() async {
    final ids = _sel.toList();
    if (ids.isEmpty) {
      _toast('请先选择会话');
      return;
    }
    final ok = await showMobileConfirm(
      context,
      title: '删除 ${ids.length} 个会话？',
      desc: '会话记录删除后不可恢复，录音与笔记不受影响。',
    );
    if (!mounted || !ok) return;
    Db.instance.deleteConversations(ids);
    setState(() {
      _multi = false;
      _sel.clear();
      _load();
    });
  }

  void _toast(String msg) {
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

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.64;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: mobileSheetDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetGrabber(),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 14, 10),
            child: Row(
              children: [
                const Text('会话',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                MobileBtn(
                  label: _multi ? '退出' : '多选',
                  height: 28,
                  onTap: () => setState(() {
                    _multi = !_multi;
                    if (!_multi) _sel.clear();
                  }),
                ),
                const SizedBox(width: 7),
                MobileBtn(
                  label: '＋ 新建',
                  height: 28,
                  onTap: () {
                    final id = 'c${DateTime.now().microsecondsSinceEpoch}';
                    Db.instance.upsertConversation(
                      id: id,
                      title: '新对话',
                      meta: _metaText(
                          0, DateTime.now().millisecondsSinceEpoch),
                      contextId: 'ctx-$id',
                    );
                    Navigator.pop(context, id);
                  },
                ),
                const SizedBox(width: 7),
                MobileBtn(
                  label: '关闭',
                  height: 28,
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Palette.line2),
          Flexible(
            child: _list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 26),
                    child: Text('还没有对话',
                        style:
                            TextStyle(fontSize: 12.5, color: Color(0xFF9AA8AA))),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                    itemCount: _list.length,
                    itemBuilder: (_, i) => _row(_list[i]),
                  ),
          ),
          if (_multi)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Palette.line2)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('已选 ${_sel.length} 个会话',
                        style: const TextStyle(
                            fontSize: 11.5, color: Palette.muted)),
                  ),
                  MobileBtn(
                    label: _sel.length == _list.length ? '取消全选' : '全选',
                    height: 30,
                    onTap: () => setState(() {
                      if (_sel.length == _list.length) {
                        _sel.clear();
                      } else {
                        _sel
                          ..clear()
                          ..addAll(_list.map((e) => e.id));
                      }
                    }),
                  ),
                  const SizedBox(width: 7),
                  MobileBtn(
                    label: '删除',
                    height: 30,
                    danger: true,
                    onTap: _deleteSelected,
                  ),
                  const SizedBox(width: 7),
                  MobileBtn(
                    label: '取消',
                    height: 30,
                    onTap: () => setState(() {
                      _multi = false;
                      _sel.clear();
                    }),
                  ),
                ],
              ),
            ),
          SizedBox(height: 14 + MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }

  Widget _row(_Conv c) {
    final on = c.id == widget.activeId;
    final sel = _sel.contains(c.id);
    final renaming = _renamingId == c.id;
    return Pressable(
      onTap: () {
        if (_multi) {
          setState(() {
            if (sel) {
              _sel.remove(c.id);
            } else {
              _sel.add(c.id);
            }
          });
        } else {
          Navigator.pop(context, c.id);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.fromLTRB(10, 11, 8, 11),
        decoration: BoxDecoration(
          color: sel
              ? Colors.white
              : (on && !_multi ? const Color(0xFFF7F4EF) : Colors.transparent),
          borderRadius: BorderRadius.circular(11),
          border: sel
              ? Border.all(color: Palette.ink)
              : Border.all(color: Colors.transparent),
        ),
        child: Row(
          children: [
            if (_multi) ...[
              CheckSquare(checked: sel),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (renaming)
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: Palette.gold),
                        borderRadius: BorderRadius.circular(6),
                        color: Colors.white,
                      ),
                      child: TextField(
                        controller: _renameCtrl,
                        focusNode: _renameFocus,
                        style: const TextStyle(fontSize: 13),
                        cursorColor: Palette.gold,
                        onSubmitted: (_) => _commitRename(),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 3),
                        ),
                      ),
                    )
                  else
                    Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: Palette.text,
                      ),
                    ),
                  const SizedBox(height: 3),
                  Text(c.meta,
                      style: const TextStyle(
                          fontSize: 11, color: Palette.muted2)),
                ],
              ),
            ),
            // 多选态下只留勾选框（原型：隐藏改名与单条删除）
            if (!_multi) ...[
              MobileIconBtn(
                icon: Icons.edit_outlined,
                size: 15,
                color: const Color(0xFFB4BFBF),
                onTap: () => _beginRename(c),
              ),
              MobileIconBtn(
                icon: Icons.close,
                size: 15,
                color: const Color(0xFFB4BFBF),
                onTap: () => _deleteOne(c),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
