import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_client.dart';
import 'app_state.dart';
import 'db.dart';
import 'theme.dart';
import 'widgets.dart';

/// 把选中的条目拼成给模型的语料
String buildCorpus(List<Map<String, String>> items) {
  final b = StringBuffer();
  for (final it in items) {
    b.writeln('【${it['title']}】（${it['time']}）');
    b.writeln(it['text']);
    b.writeln();
  }
  return b.toString().trim();
}

class _Chat {
  _Chat({
    required this.id,
    required this.title,
    required this.meta,
    required this.contextId,
    this.hit,
  });

  final String id;
  String title;
  String meta;
  final String contextId;

  /// 搜索命中的消息片段
  String? hit;
}

/// AI 对话：左会话列（262）+ 右聊天区，与原型一致；会话与消息持久化到 SQLite
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Chat> _chats = [];
  final TextEditingController _input = TextEditingController();

  final ScrollController _scroll = ScrollController();
  final Set<String> _sel = {};

  String? _activeId;
  String _kw = '';
  int _seq = 0;
  bool _loaded = false;
  bool _multi = false;

  /// 每个会话推荐的「接下来可以问什么」
  final Map<String, List<String>> _sugg = {};

  /// 还没开始聊时的默认推荐（点击直接提问）
  static const _fallbackQuestions = <String>[
    '一句话总结这些内容',
    '转述给别人听，怎么说？',
    '有哪些值得怀疑的地方？',
  ];

  bool _sending = false;
  bool _aiReady = false;
  String _aiLabel = '';

  String _streamingText = '';

  /// 正在流式回复的是哪个会话：切到别的对话时不要把气泡/内容显示过去
  String? _streamConvId;
  StreamSubscription<String>? _sub;
  final FocusNode _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _inputFocus.onKeyEvent = _onInputKey;
  }

  /// Enter 发送，Shift+Enter 换行
  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _reloadAi() {
    final cfg = AiClient.load();
    _aiReady = cfg.ready;
    _aiLabel = cfg.isA2a ? 'A2A 智能体' : cfg.model;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _reloadAi();
    _loadChats();
    _applyPendingRefs();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _inputFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------------- 数据 ----------------
  void _loadChats() {
    _chats.clear();
    for (final r in Db.instance.conversations(kw: _kw)) {
      final id = r['id'] as String;
      final refCount = Db.instance.convRefs(id).length;
      _chats.add(_Chat(
        id: id,
        title: r['title'] as String,
        meta: _metaText(refCount, r['createdAt'] as int?),
        contextId: (r['contextId'] as String?) ?? 'ctx-$id',
        hit: _kw.isEmpty ? null : Db.instance.hitSnippet(id, _kw),
      ));
    }
    _activeId ??= _chats.isEmpty ? null : _chats.first.id;
  }

  String _metaText(int refCount, int? createdAt) {
    final d = DateTime.fromMillisecondsSinceEpoch(
        createdAt ?? DateTime.now().millisecondsSinceEpoch);
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final t = sameDay ? '今天 $hm' : '${d.month}-${d.day} $hm';
    return refCount > 0 ? '引用 $refCount 条 · $t' : t;
  }

  /// 从时间流「发给 AI / AI 分析」进来时，每次都在 AI 对话里新建一条会话
  void _applyPendingRefs() {
    final st = AppScope.read(context);
    if (st.pendingRefs.isEmpty) return;
    final refs = List<String>.from(st.pendingRefs);
    st.pendingRefs = [];

    final id = 'c${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    Db.instance.upsertConversation(
      id: id,
      title: _titleFromRefs(refs),
      meta: _metaText(refs.length, DateTime.now().millisecondsSinceEpoch),
      contextId: 'ctx-$id',
    );
    Db.instance.setConvRefs(id, refs);

    _kw = '';
    AppScope.read(context).clearKeyword();
    _activeId = id;
    _sugg[id] = _fallbackQuestions;
    _loadChats();
    setState(() {});

    // 用 AI 给这次分析起个标题（不阻塞界面）
    _aiTitleForRefs(id, refs);
  }

  /// 引用条目变化后，让 AI 给会话起名字
  Future<void> _aiTitleForRefs(String convId, List<String> refs) async {
    try {
      final t = await AiClient.suggestTitleFromItems(refs);
      if (t.isEmpty || !mounted) return;
      Db.instance.touchConversation(
        convId,
        title: t,
        meta: _metaText(refs.length, DateTime.now().millisecondsSinceEpoch),
      );
      for (final c in _chats) {
        if (c.id == convId) {
          c.title = t;
          break;
        }
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// 一轮回答结束后：生成会话标题（首轮）+ 推荐下一个问题
  Future<void> _afterReply(String convId) async {
    final cfg = AiClient.load();
    if (!cfg.ready) return;

    final refs = Db.instance.convRefs(convId);
    final refTitles = refs
        .map((id) => Db.instance.byId(id)?.title ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    final msgs = Db.instance.messages(convId);

    // 1) 首轮用 AI 起标题
    if (msgs.length <= 2) {
      final firstQ = msgs
          .where((m) => m['role'] == 'user')
          .map((m) => (m['text'] as String?) ?? '')
          .firstWhere((e) => e.isNotEmpty, orElse: () => '');
      if (firstQ.isNotEmpty) {
        try {
          final t = await AiClient.suggestConvTitle(
            question: firstQ,
            refTitles: refTitles,
          );
          if (t.isNotEmpty && mounted) {
            Db.instance.touchConversation(
              convId,
              title: t,
              meta: _metaText(refs.length, DateTime.now().millisecondsSinceEpoch),
            );
            for (final c in _chats) {
              if (c.id == convId) {
                c.title = t;
                break;
              }
            }
            if (mounted) setState(() {});
          }
        } catch (_) {}
      }
    }

    // 2) 推荐接下来的问题
    try {
      final turns = msgs
          .take(4)
          .map((m) => '${m['role'] == 'user' ? '问' : '答'}：${(m['text'] as String?) ?? ''}')
          .toList();
      final qs = await AiClient.suggestQuestions(
        refTitles: refTitles,
        recentTurns: turns,
      );
      if (qs.isNotEmpty && mounted) {
        setState(() => _sugg[convId] = qs);
      }
    } catch (_) {}
  }

  /// 用引用条目的标题给新会话起个名字
  String _titleFromRefs(List<String> refs) {
    if (refs.isEmpty) return '新对话';
    final first = Db.instance.byId(refs.first)?.title ?? '新对话';
    final short = first.length > 12 ? '${first.substring(0, 12)}…' : first;
    return refs.length > 1
        ? 'AI 分析 · $short 等 ${refs.length} 条'
        : 'AI 分析 · $short';
  }

  _Chat? get _active {
    for (final c in _chats) {
      if (c.id == _activeId) return c;
    }
    return null;
  }

  void _newChat() {
    final id = 'c${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    Db.instance.upsertConversation(
      id: id,
      title: '新对话',
      meta: _metaText(0, DateTime.now().millisecondsSinceEpoch),
      contextId: 'ctx-$id',
    );
    // 新建后清空搜索，避免新会话被过滤掉看不见
    _kw = '';
    AppScope.read(context).clearKeyword();
    _loadChats();
    _activeId = id;
    setState(() {});
  }

  void _deleteChats(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    Db.instance.deleteConversations(list);
    setState(() {
      _sel.clear();
      _multi = false;
      for (final id in list) {
        _sugg.remove(id);
      }
      _loadChats();
      if (_activeId != null && list.contains(_activeId)) {
        _activeId = _chats.isEmpty ? null : _chats.first.id;
      }
    });
  }

  /// 停止生成：断开连接，已收到的部分保留（落到发起的那个会话，不是当前会话）
  void _stop() {
    _sub?.cancel();
    _sub = null;
    final convId = _streamConvId ?? _active?.id;
    if (_streamingText.isNotEmpty && convId != null) {
      Db.instance.addMessage(convId, 'agent', _streamingText);
    }
    setState(() {
      _sending = false;
      _streamingText = '';
      _streamConvId = null;
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;

    var chat = _active;
    if (chat == null) {
      _newChat();
      chat = _active;
      if (chat == null) return;
    }

    final refs = Db.instance.convRefs(chat.id);
    final corpusItems = <Map<String, String>>[];
    for (final id in refs) {
      final it = Db.instance.byId(id);
      if (it == null) continue;
      final segs = Db.instance.segments(id);
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

    final newTitle = chat.title == '新对话'
        ? (text.length > 14 ? '${text.substring(0, 14)}…' : text)
        : null;

    final userMsgId = Db.instance.addMessage(chat.id, 'user', text);
    // 引用作为链接随这条消息一起进入对话框
    if (refs.isNotEmpty) Db.instance.setMessageRefs(userMsgId, refs);
    if (newTitle != null) {
      Db.instance.touchConversation(chat.id, title: newTitle, meta: chat.meta);
      chat.title = newTitle;
    }

    final convId = chat.id;
    setState(() {
      _input.clear();
      _sending = true;
      _streamingText = '';
      _streamConvId = convId;
      // 推荐问题用掉了就先收起来，等回答完再给新的
      _sugg.remove(convId);
    });
    _jumpBottom();
    final cfg = AiClient.load();
    if (!cfg.ready) {
      Db.instance.addMessage(
        convId,
        'agent',
        '还没配置 AI 服务。\n\n'
            '打开「设置 → AI 服务」：\n'
            '· 本地：装好 Ollama 并拉取模型（默认 qwen2.5:3b）\n'
            '· 云端：选 DeepSeek / 通义 等，填入 API Key\n\n'
            '配好后点「测试连接」，通过即可对话。',
      );
      if (mounted) setState(() => _sending = false);
      _jumpBottom();
      return;
    }

    setState(() => _sending = true);
    _sub = AiClient.chat(prompt: prompt).listen(
      (delta) {
        if (!mounted) return;
        setState(() => _streamingText += delta);
        _jumpBottom();
      },
      onError: (Object e) {
        final failed = _streamingText.isEmpty ? '调用失败：$e' : _streamingText;
        Db.instance.addMessage(convId, 'agent', failed);
        if (!mounted) return;
        setState(() {
          _sending = false;
          _streamingText = '';
          _streamConvId = null;
        });
      },
      onDone: () {
        if (_streamingText.isNotEmpty) {
          Db.instance.addMessage(convId, 'agent', _streamingText);
        }
        if (!mounted) return;
        setState(() {
          _sending = false;
          _streamingText = '';
          _streamConvId = null;
        });
        _jumpBottom();
        // 回答完：AI 起标题 + 推荐下一个问题
        _afterReply(convId);
      },
      cancelOnError: true,
    );
  }

  void _jumpBottom() {
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

  @override
  Widget build(BuildContext context) {
    // 这个页面在 IndexedStack 里只初始化一次，所以每次重建都要检查
    // 时间流是否新推了「发给 AI」的引用条目
    final st = AppScope.of(context);
    // 顶栏搜索现在同时过滤会话列表
    final kw = st.keyword.trim();
    if (kw != _kw) {
      _kw = kw;
      _loadChats();
    }
    if (st.pendingRefs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyPendingRefs();
      });
    }

    return Row(
      children: [
        _convCol(),
        Expanded(child: _chatCol()),
      ],
    );
  }

  // ---------------- 左：会话列 ----------------
  Widget _convCol() {
    return Container(
      width: 262,
      decoration: const BoxDecoration(
        color: Palette.listBg,
        border: Border(right: BorderSide(color: Palette.line)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
            child: Column(
              children: [
                HoverBox(
                  onTap: _newChat,
                  builder: (hover) => Container(
                    height: 36,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: hover ? Palette.goldBg : Colors.white,
                      border: Border.all(
                        color: hover ? Palette.gold : const Color(0xFFD8D0C2),
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add,
                            size: 15, color: hover ? Palette.gold : Palette.muted),
                        const SizedBox(width: 6),
                        Text('新对话',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: hover ? Palette.gold : Palette.muted,
                            )),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // 搜索统一走顶栏那个框（这里不再单独放一个）
                Row(
                  children: [
                    Text(_kw.isEmpty ? '会话记录' : '找到 ${_chats.length} 条',
                        style: const TextStyle(
                            fontSize: 11.5, color: Palette.muted2)),
                    const Spacer(),
                    HoverBox(
                      onTap: () => setState(() {
                        _multi = !_multi;
                        if (!_multi) _sel.clear();
                      }),
                      builder: (hover) => Container(
                        height: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: _multi
                              ? Palette.ink
                              : (hover ? const Color(0xFFF2EEE6) : Colors.transparent),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            _multi ? '退出' : '多选',
                            style: TextStyle(
                              fontSize: 11,
                              color: _multi ? const Color(0xFFF3EEE4) : Palette.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _chats.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
                    child: Text(
                        _kw.isEmpty
                            ? '还没有对话\n点上面「新对话」开始'
                            : '没有匹配的对话\n换个关键词试试',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 11.5, color: Palette.muted2, height: 1.9)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                    itemCount: _chats.length,
                    itemBuilder: (_, i) => _convRow(_chats[i]),
                  ),
          ),
          if (_multi)
            Container(
              margin: const EdgeInsets.fromLTRB(8, 4, 8, 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xF70B2226),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Text('已选 ${_sel.length} 个',
                      style: const TextStyle(fontSize: 10.5, color: Color(0xFFBFD0D3))),
                  const Spacer(),
                  _miniDark('全选', () {
                    setState(() {
                      if (_sel.length == _chats.length) {
                        _sel.clear();
                      } else {
                        _sel
                          ..clear()
                          ..addAll(_chats.map((c) => c.id));
                      }
                    });
                  }),
                  const SizedBox(width: 4),
                  _miniDark('删除', () => _deleteChats(_sel), danger: true),
                  const SizedBox(width: 4),
                  _miniDark('取消', () => setState(() {
                        _multi = false;
                        _sel.clear();
                      })),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniDark(String label, VoidCallback onTap, {bool danger = false}) {
    return QualityButton(
      label: label,
      height: 23,
      hPad: 8,
      fontSize: 10,
      radius: 7,
      tone: danger ? BtnTone.danger : BtnTone.dark,
      onTap: onTap,
    );
  }

  Widget _convRow(_Chat c) {
    final active = c.id == _activeId && !_multi;
    final checked = _sel.contains(c.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: HoverBox(
        onTap: () {
          if (_multi) {
            setState(() {
              if (checked) {
                _sel.remove(c.id);
              } else {
                _sel.add(c.id);
              }
            });
          } else {
            setState(() => _activeId = c.id);
            _jumpBottom();
          }
        },
        builder: (hover) => Container(
          padding: const EdgeInsets.fromLTRB(11, 10, 8, 10),
          decoration: BoxDecoration(
            color: active
                ? Colors.white
                : (hover ? const Color(0xFFF2EEE6) : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_multi) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: CheckSquare(checked: checked),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: active ? Palette.text : const Color(0xFF40555B),
                        fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(c.meta,
                        style: const TextStyle(fontSize: 11, color: Palette.muted2)),
                    if (c.hit != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        c.hit!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Palette.goldDeep,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!_multi && hover)
                GestureDetector(
                  onTap: () => _deleteChats([c.id]),
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(Icons.close, size: 13, color: Palette.muted2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 右：聊天区 ----------------
  Widget _chatCol() {
    final chat = _active;
    final msgs =
        chat == null ? <Map<String, Object?>>[] : Db.instance.messages(chat.id);
    final refs = chat == null ? <String>[] : Db.instance.convRefs(chat.id);
    final sugg = chat == null
        ? const <String>[]
        : (_sugg[chat.id] ??
            (msgs.isEmpty && refs.isNotEmpty
                ? _fallbackQuestions
                : const <String>[]));

    return Column(
      children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: const BoxDecoration(
            color: Color(0x99FFFFFF),
            border: Border(bottom: BorderSide(color: Palette.line2)),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient:
                      const LinearGradient(colors: [Palette.inkHover, Palette.ink]),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Text('雁',
                      style: TextStyle(
                        fontSize: 13,
                        color: Palette.goldSoft,
                        fontFamily: Palette.serifFamily,
                      )),
                ),
              ),
              const SizedBox(width: 10),
              Text(chat?.title ?? '雁书 Agent',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              // 只留状态点：具体用哪个服务在「设置 → AI 服务」里配
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: _aiReady ? Palette.green : Palette.muted2,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(_aiReady ? '就绪' : '未配置',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: _aiReady ? Palette.green : Palette.muted2,
                  )),
              const Spacer(),
              if (_aiReady)
                Text(_aiLabel,
                    style: const TextStyle(fontSize: 11, color: Palette.muted2)),
            ],
          ),
        ),
        Expanded(
          child: chat == null
              ? const EmptyHint(
                  icon: Icons.chat_bubble_outline,
                  title: '还没有对话',
                  desc: '点左上「新对话」，或先在时间流里多选内容「发给 AI」',
                )
              : (msgs.isEmpty && !(_sending && _streamConvId == chat.id))
                  ? EmptyHint(
                      icon: Icons.chat_bubble_outline,
                      title: '还没有消息',
                      desc: _refHint(chat),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
                      // 只有正在生成的那个会话才显示流式气泡，切走不会串到别的对话
                      itemCount: msgs.length +
                          (_sending && _streamConvId == chat.id ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i >= msgs.length) {
                          // 流式临时气泡（未落库）
                          return _bubble(<String, Object?>{
                            'role': 'agent',
                            'text': _streamingText.isEmpty
                                ? '正在思考…'
                                : '$_streamingText▌',
                            'refs': const <String>[],
                          });
                        }
                        return _bubble(msgs[i]);
                      },
                    ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Column(
            children: [
              // 推荐问题：靠右对齐，点一下就直接发问
              if (sugg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final q in sugg) _suggChip(q),
                      ],
                    ),
                  ),
                ),
              // 本对话引用的内容：只在还没发送消息时显示（发出后链接已在气泡里）
              if (chat != null && refs.isNotEmpty && msgs.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final id in refs) _refChip(chat, id, refs),
                      ],
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 9),
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
                          hintText: '继续问点什么…（Enter 发送，Shift+Enter 换行）',
                          hintStyle:
                              TextStyle(fontSize: 13.5, color: Palette.muted2),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DialogBtn(
                      label: _sending ? '停止' : '发送',
                      primary: true,
                      danger: _sending,
                      height: 34,
                      icon: _sending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                      onTap: _sending ? _stop : _send,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 推荐问题胶囊：点一下就把问题填进输入框并发送
  Widget _suggChip(String q) {
    return QualityButton(
      label: q,
      icon: Icons.auto_awesome,
      height: 31,
      hPad: 13,
      fontSize: 12,
      radius: 16,
      onTap: () {
        if (_sending) return;
        _input.text = q;
        _send();
      },
    );
  }

  /// 引用条：链接样式，点标题跳回时间流，点 × 取消引用
  Widget _refChip(_Chat chat, String id, List<String> refs) {
    final it = Db.instance.byId(id);
    final label = it?.title ?? '（已删除）';
    final tail = it == null
        ? ''
        : (it.isAudio ? fmtDurMs(it.durationMs) : '${it.charCount ?? 0} 字');
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: 9, right: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HoverBox(
            onTap: () {
              final st = AppScope.read(context);
              st.setKeyword('');
              st.select(id);
              st.setTab(0);
            },
            builder: (hover) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link, size: 12, color: Palette.blue),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 210),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hover ? Palette.blue : const Color(0xFF4B6166),
                      decoration: hover
                          ? TextDecoration.underline
                          : TextDecoration.none,
                    ),
                  ),
                ),
                if (tail.isNotEmpty) ...[
                  const SizedBox(width: 5),
                  Text(tail,
                      style: const TextStyle(
                          fontSize: 11, color: Palette.muted2)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 4),
          HoverBox(
            onTap: () {
              final next = refs.where((e) => e != id).toList();
              Db.instance.setConvRefs(chat.id, next);
              setState(() {});
            },
            builder: (h) => Icon(Icons.close,
                size: 12, color: h ? Palette.red : Palette.muted2),
          ),
        ],
      ),
    );
  }

  /// 空对话时提示：这次要分析哪些内容
  String _refHint(_Chat? chat) {
    if (chat == null) return '在下方输入问题开始对话';
    final refs = Db.instance.convRefs(chat.id);
    if (refs.isEmpty) return '在下方输入问题开始对话';
    final names = refs
        .map((id) => Db.instance.byId(id)?.title ?? '（已删除）')
        .take(3)
        .join('、');
    final more = refs.length > 3 ? ' 等 ${refs.length} 条' : '';
    return '将围绕「$names」$more 分析，输入问题后发送';
  }

  /// 气泡里的引用链接：点击跳回时间流对应条目
  Widget _refLink(String id, bool onDark) {
    final it = Db.instance.byId(id);
    final label = it?.title ?? '（已删除）';
    final tail = it == null
        ? ''
        : (it.isAudio ? fmtDurMs(it.durationMs) : '${it.charCount ?? 0} 字');
    final color = onDark ? Palette.goldSoft : Palette.blue;
    return HoverBox(
      onTap: () {
        final st = AppScope.read(context);
        st.setKeyword('');
        st.select(id);
        st.setTab(0);
      },
      builder: (hover) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link, size: 12, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              tail.isEmpty ? label : '$label · $tail',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: color,
                decoration: TextDecoration.underline,
                decorationColor: color.withOpacity(hover ? 1 : 0.55),
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
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient:
                    const LinearGradient(colors: [Palette.inkHover, Palette.ink]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text('雁',
                    style: TextStyle(
                      fontSize: 12,
                      color: Palette.goldSoft,
                      fontFamily: Palette.serifFamily,
                    )),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 720),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
              decoration: BoxDecoration(
                color: isUser ? Palette.ink : Colors.white,
                border: isUser ? null : Border.all(color: Palette.line),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(isUser ? 14 : 5),
                  bottomRight: Radius.circular(isUser ? 5 : 14),
                ),
                boxShadow: isUser
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 12,
                          offset: const Offset(0, 2),
                        )
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (m['text'] as String?) ?? '',
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.78,
                      color: isUser ? const Color(0xFFF0EBE1) : Palette.text,
                    ),
                  ),
                  if (refs.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
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
          if (isUser) ...[
            const SizedBox(width: 10),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFFEFEAE1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text('我',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6D7B7E))),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
