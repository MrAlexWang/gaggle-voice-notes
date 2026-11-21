import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// 一条内容：录音或速记。
class Item {
  Item({
    required this.id,
    required this.type,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.sourceDevice,
    required this.transcriptStatus,
    this.durationMs,
    this.charCount,
    this.audioPath,
    this.body,
    this.deletedAt,
    this.uploadedAt,
    this.dupOf,
    this.audioHash,
  });

  final String id;
  final String type; // audio | text
  final String title;
  final int createdAt;
  final int updatedAt;
  final String sourceDevice; // pc | phone | watch
  final String transcriptStatus; // none | queued | running | done | failed
  final int? durationMs;
  final int? charCount;
  final String? audioPath;
  final String? body;
  final int? deletedAt;

  /// 手机端：这条录音最后一次上传到电脑的时间（null = 没传过）
  final int? uploadedAt;

  /// 电脑端：内容与该 id 的录音重复（null = 不重复）
  final String? dupOf;

  /// 音频内容哈希，用于判重
  final String? audioHash;

  bool get isAudio => type == 'audio';
  bool get inTrash => deletedAt != null;
  bool get uploaded => uploadedAt != null;
  bool get isDuplicate => dupOf != null;

  factory Item.fromRow(Row r) => Item(
        id: r['id'] as String,
        type: r['type'] as String,
        title: r['title'] as String,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        sourceDevice: (r['source_device'] as String?) ?? 'pc',
        transcriptStatus: (r['transcript_status'] as String?) ?? 'none',
        durationMs: r['duration_ms'] as int?,
        charCount: r['char_count'] as int?,
        audioPath: r['audio_path'] as String?,
        body: r['body'] as String?,
        deletedAt: r['deleted_at'] as int?,
        uploadedAt: r['uploaded_at'] as int?,
        dupOf: r['dup_of'] as String?,
        audioHash: r['audio_hash'] as String?,
      );
}

/// 本地 SQLite 存储层。全部数据在本机，不上传。
class Db {
  Db._(this._db, this.rootPath);

  final Database _db;
  final String rootPath;

  static Db? _instance;
  static Db get instance => _instance!;

  static Future<Db> open(String rootPath) async {
    if (_instance != null) return _instance!;
    final dir = Directory(rootPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    Directory(p.join(rootPath, 'audio')).createSync(recursive: true);
    Directory(p.join(rootPath, 'logs')).createSync(recursive: true);
    Directory(p.join(rootPath, 'tmp')).createSync(recursive: true);

    final dbPath = p.join(rootPath, 'gaggle.db');
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA foreign_keys=ON;');

    final self = Db._(db, rootPath);
    self._migrate();
    _instance = self;
    return self;
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS item(
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        source_device TEXT NOT NULL DEFAULT 'pc',
        duration_ms INTEGER,
        char_count INTEGER,
        transcript_status TEXT NOT NULL DEFAULT 'none',
        audio_path TEXT,
        body TEXT,
        deleted_at INTEGER
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_item ON item(deleted_at, created_at DESC);');
    // v2.1：手机上传状态 / 重复录音标识
    _addColumn('item', 'uploaded_at', 'INTEGER');
    _addColumn('item', 'dup_of', 'TEXT');
    _addColumn('item', 'audio_hash', 'TEXT');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS transcript_segment(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        text TEXT NOT NULL,
        speaker_id TEXT
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_seg ON transcript_segment(item_id, start_ms);');

    // AI 会话（持久化，关掉程序也能继续）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS ai_conversation(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        meta TEXT,
        context_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS ai_message(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_msg ON ai_message(conversation_id, id);');
    // 每条消息引用了哪些条目（气泡里显示成链接，随消息一起发出去）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS ai_message_ref(
        message_id INTEGER NOT NULL,
        item_id TEXT NOT NULL
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_msg_ref ON ai_message_ref(message_id);');

    // 通用键值配置（模型档位、自定义 Agent 等）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS setting(
        key TEXT PRIMARY KEY,
        value TEXT
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS ai_conv_ref(
        conversation_id TEXT NOT NULL,
        item_id TEXT NOT NULL
      );
    ''');

    // 标签：source = manual（手动添加）/ ai（模型自动生成）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS item_tag(
        item_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual',
        created_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(item_id, tag)
      );
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tag ON item_tag(tag);');

    // FTS5：优先 trigram（中文子串检索），不支持时退化为默认分词
    try {
      _db.execute(
          "CREATE VIRTUAL TABLE IF NOT EXISTS search_idx USING fts5(content, item_id UNINDEXED, tokenize='trigram');");
    } catch (_) {
      _db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS search_idx USING fts5(content, item_id UNINDEXED);');
    }
  }

  /// 老库升级：缺哪列补哪列（SQLite 的 ADD COLUMN 不支持 IF NOT EXISTS）
  void _addColumn(String table, String column, String type) {
    try {
      final rows = _db.select('PRAGMA table_info($table)');
      for (final r in rows) {
        if (r['name'] == column) return;
      }
      _db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    } catch (_) {}
  }

  /// 列表查询；kw 非空时走检索。
  List<Item> items({String? kw, bool trash = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (kw != null && kw.trim().isNotEmpty) {
      final like = '%${kw.trim()}%';
      final rows = _db.select(
        'SELECT item_id FROM search_idx WHERE content LIKE ? LIMIT 300',
        [like],
      );
      final ids = <String>[];
      for (final r in rows) {
        final id = r['item_id'] as String?;
        if (id != null && !ids.contains(id)) ids.add(id);
      }
      if (ids.isEmpty) return [];
      final ph = List.filled(ids.length, '?').join(',');
      final rs = _db.select(
        'SELECT * FROM item WHERE id IN ($ph) AND deleted_at IS NULL ORDER BY created_at DESC',
        ids,
      );
      return rs.map(Item.fromRow).toList();
    }
    final rs = trash
        ? _db.select(
            'SELECT * FROM item WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC LIMIT 500')
        : _db.select(
            'SELECT * FROM item WHERE deleted_at IS NULL ORDER BY created_at DESC LIMIT 500');
    // 触发一次过期回收站清理（30 天）
    if (!trash) _purgeExpired(now);
    return rs.map(Item.fromRow).toList();
  }

  void _purgeExpired(int now) {
    const keepMs = 30 * 24 * 3600 * 1000;
    try {
      _db.execute('DELETE FROM item WHERE deleted_at IS NOT NULL AND deleted_at < ?', [now - keepMs]);
    } catch (_) {}
  }

  Item? byId(String id) {
    final rs = _db.select('SELECT * FROM item WHERE id = ?', [id]);
    if (rs.isEmpty) return null;
    return Item.fromRow(rs.first);
  }

  String insertItem({
    required String type,
    required String title,
    String sourceDevice = 'pc',
    int? durationMs,
    int? charCount,
    String? audioPath,
    String? body,
    String transcriptStatus = 'none',
    String? audioHash,
    String? dupOf,
    int? uploadedAt,
  }) {
    final id = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO item(id,type,title,created_at,updated_at,source_device,duration_ms,char_count,transcript_status,audio_path,body,audio_hash,dup_of,uploaded_at) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        id, type, title, now, now, sourceDevice, durationMs, charCount,
        transcriptStatus, audioPath, body, audioHash, dupOf, uploadedAt,
      ],
    );
    rebuildIndex(id);
    return id;
  }

  /// 标记「已上传到电脑」；uploaded=false 可撤销标记
  void markUploaded(String id, {bool uploaded = true}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('UPDATE item SET uploaded_at=?, updated_at=? WHERE id=?',
        [uploaded ? now : null, now, id]);
  }

  void setAudioHash(String id, String hash) {
    _db.execute('UPDATE item SET audio_hash=? WHERE id=?', [hash, id]);
  }

  /// 换掉条目的音频文件（停录后 WAV → m4a 转码归档时用）
  void setAudioPath(String id, String path) {
    _db.execute('UPDATE item SET audio_path=?, updated_at=? WHERE id=?',
        [path, DateTime.now().millisecondsSinceEpoch, id]);
  }

  /// 还没有内容哈希的录音（启动后后台补齐，用于判重）
  List<Item> itemsMissingHash({int limit = 200}) {
    final rs = _db.select(
      'SELECT * FROM item WHERE audio_path IS NOT NULL AND deleted_at IS NULL '
      'AND (audio_hash IS NULL OR audio_hash = \'\') '
      'ORDER BY created_at DESC LIMIT ?',
      [limit],
    );
    return rs.map(Item.fromRow).toList();
  }

  /// 按音频哈希找已有条目（判重用）
  Item? findByAudioHash(String hash) {
    if (hash.isEmpty) return null;
    final rs = _db.select(
      'SELECT * FROM item WHERE audio_hash=? AND deleted_at IS NULL '
      'ORDER BY created_at ASC LIMIT 1',
      [hash],
    );
    if (rs.isEmpty) return null;
    return Item.fromRow(rs.first);
  }

  void rename(String id, String title) {
    _db.execute('UPDATE item SET title=?, updated_at=? WHERE id=?',
        [title, DateTime.now().millisecondsSinceEpoch, id]);
    rebuildIndex(id);
  }

  void setDuration(String id, int ms) {
    _db.execute('UPDATE item SET duration_ms=?, updated_at=? WHERE id=?',
        [ms, DateTime.now().millisecondsSinceEpoch, id]);
  }

  void setStatus(String id, String status) {
    _db.execute('UPDATE item SET transcript_status=?, updated_at=? WHERE id=?',
        [status, DateTime.now().millisecondsSinceEpoch, id]);
  }

  /// 软删除 → 回收站
  void moveToTrash(String id) {
    _db.execute('UPDATE item SET deleted_at=? WHERE id=?',
        [DateTime.now().millisecondsSinceEpoch, id]);
    rebuildIndex(id);
  }

  void restore(String id) {
    _db.execute('UPDATE item SET deleted_at=NULL WHERE id=?', [id]);
    rebuildIndex(id);
  }

  /// 彻底删除：先删文件再删记录
  void purge(String id) {
    final it = byId(id);
    if (it?.audioPath != null) {
      final f = File(it!.audioPath!);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    _db.execute('DELETE FROM transcript_segment WHERE item_id=?', [id]);
    _db.execute('DELETE FROM search_idx WHERE item_id=?', [id]);
    _db.execute('DELETE FROM item_tag WHERE item_id=?', [id]);
    _db.execute('DELETE FROM item WHERE id=?', [id]);
  }

  /// 重建单个条目的检索索引（编辑后必须调用）
  void rebuildIndex(String id) {
    final it = byId(id);
    if (it == null) return;
    _db.execute('DELETE FROM search_idx WHERE item_id=?', [id]);
    if (it.deletedAt != null) return;
    final buf = StringBuffer();
    buf.writeln(it.title);
    if (it.body != null) buf.writeln(it.body);
    final segs = _db.select(
        'SELECT text FROM transcript_segment WHERE item_id=? ORDER BY start_ms', [id]);
    for (final s in segs) {
      buf.writeln(s['text'] as String);
    }
    // 标签也进索引：搜「会议」能搜到打了该标签的条目
    for (final t in tags(id)) {
      buf.writeln(t);
    }
    _db.execute('INSERT INTO search_idx(content, item_id) VALUES(?,?)', [buf.toString(), id]);
  }

  // ================= 标签 =================

  /// 某个条目的标签（手动 + AI）
  List<String> tags(String itemId) {
    final rs = _db.select(
      'SELECT tag FROM item_tag WHERE item_id=? ORDER BY created_at, tag',
      [itemId],
    );
    return rs.map((r) => r['tag'] as String).toList();
  }

  /// 手动添加标签
  bool addTag(String itemId, String tag, {String source = 'manual'}) {
    final t = tag.trim().replaceAll('#', '');
    if (t.isEmpty || t.length > 20) return false;
    _db.execute(
      'INSERT INTO item_tag(item_id,tag,source,created_at) VALUES(?,?,?,?) '
      'ON CONFLICT(item_id,tag) DO UPDATE SET source=excluded.source',
      [itemId, t, source, DateTime.now().millisecondsSinceEpoch],
    );
    rebuildIndex(itemId);
    return true;
  }

  void removeTag(String itemId, String tag) {
    _db.execute('DELETE FROM item_tag WHERE item_id=? AND tag=?', [itemId, tag]);
    rebuildIndex(itemId);
  }

  /// AI 重新打标签：只替换 ai 来源的标签，手动加的保留
  void setAiTags(String itemId, List<String> tags) {
    _db.execute(
      "DELETE FROM item_tag WHERE item_id=? AND source='ai'",
      [itemId],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final raw in tags) {
      final t = raw.trim().replaceAll('#', '');
      if (t.isEmpty || t.length > 20) continue;
      _db.execute(
        'INSERT INTO item_tag(item_id,tag,source,created_at) VALUES(?,?,?,?) '
        'ON CONFLICT(item_id,tag) DO UPDATE SET source=excluded.source',
        [itemId, t, 'ai', now],
      );
    }
    rebuildIndex(itemId);
  }

  /// 所有用过的标签（手动输入时提示用）
  List<String> allTags() {
    final rs = _db.select(
      'SELECT tag, COUNT(*) AS c FROM item_tag GROUP BY tag ORDER BY c DESC, tag LIMIT 60',
    );
    return rs.map((r) => r['tag'] as String).toList();
  }

  // ================= 键值配置 =================

  String? getSetting(String key) {
    final rs = _db.select('SELECT value FROM setting WHERE key=?', [key]);
    if (rs.isEmpty) return null;
    return rs.first['value'] as String?;
  }

  void setSetting(String key, String value) {
    _db.execute(
      'INSERT INTO setting(key,value) VALUES(?,?) '
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [key, value],
    );
  }

  /// 修改某个段落的文字（转写后人工校正），并重建索引
  void updateSegmentText(String itemId, int startMs, String text) {
    _db.execute(
      'UPDATE transcript_segment SET text=? WHERE item_id=? AND start_ms=?',
      [text, itemId, startMs],
    );
    rebuildIndex(itemId);
  }

  /// 修改纯文字条目（速记）正文
  void updateBodyText(String itemId, String text) {
    _db.execute(
      'UPDATE item SET body=?, title=?, char_count=?, updated_at=? WHERE id=?',
      [
        text,
        text.length > 18 ? '${text.substring(0, 18)}…' : text,
        text.length,
        DateTime.now().millisecondsSinceEpoch,
        itemId,
      ],
    );
    rebuildIndex(itemId);
  }

  /// 删除某条目的转写结果（重新转写前调用）
  void clearSegments(String itemId) {
    _db.execute('DELETE FROM transcript_segment WHERE item_id=?', [itemId]);
    _db.execute(
      'UPDATE item SET transcript_status=?, updated_at=? WHERE id=?',
      ['none', DateTime.now().millisecondsSinceEpoch, itemId],
    );
    rebuildIndex(itemId);
  }

  // ================= AI 会话持久化 =================

  /// 会话列表；kw 非空时按「标题 + 消息内容」模糊匹配
  List<Map<String, Object?>> conversations({String? kw}) {
    final k = kw?.trim() ?? '';
    final rs = k.isEmpty
        ? _db.select('SELECT * FROM ai_conversation ORDER BY updated_at DESC')
        : _db.select(
            'SELECT DISTINCT c.* FROM ai_conversation c '
            'LEFT JOIN ai_message m ON m.conversation_id = c.id '
            'WHERE c.title LIKE ? OR m.content LIKE ? '
            'ORDER BY c.updated_at DESC',
            ['%$k%', '%$k%'],
          );
    return rs
        .map((r) => <String, Object?>{
              'id': r['id'],
              'title': r['title'],
              'meta': r['meta'],
              'contextId': r['context_id'],
              'createdAt': r['created_at'],
            })
        .toList();
  }

  /// 命中关键词的消息片段（搜索会话时显示，便于确认为什么命中）
  String? hitSnippet(String convId, String kw) {
    final k = kw.trim();
    if (k.isEmpty) return null;
    final rs = _db.select(
      'SELECT content FROM ai_message WHERE conversation_id=? AND content LIKE ? ORDER BY id DESC LIMIT 1',
      [convId, '%$k%'],
    );
    if (rs.isEmpty) return null;
    final text = (rs.first['content'] as String).replaceAll(RegExp(r'\s+'), ' ');
    final i = text.toLowerCase().indexOf(k.toLowerCase());
    if (i < 0) return text.length > 40 ? '${text.substring(0, 40)}…' : text;
    final start = i - 10 < 0 ? 0 : i - 10;
    final end = start + 46 > text.length ? text.length : start + 46;
    final seg = text.substring(start, end);
    return '${start > 0 ? '…' : ''}$seg${end < text.length ? '…' : ''}';
  }

  void upsertConversation({
    required String id,
    required String title,
    String? meta,
    String? contextId,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute(
      'INSERT INTO ai_conversation(id,title,meta,context_id,created_at,updated_at) '
      'VALUES(?,?,?,?,?,?) '
      'ON CONFLICT(id) DO UPDATE SET title=excluded.title, meta=excluded.meta, updated_at=excluded.updated_at',
      [id, title, meta, contextId, now, now],
    );
  }

  void touchConversation(String id, {String? title, String? meta}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (title != null) {
      _db.execute('UPDATE ai_conversation SET title=?, meta=?, updated_at=? WHERE id=?',
          [title, meta, now, id]);
    } else if (meta != null) {
      _db.execute('UPDATE ai_conversation SET meta=?, updated_at=? WHERE id=?',
          [meta, now, id]);
    } else {
      _db.execute('UPDATE ai_conversation SET updated_at=? WHERE id=?', [now, id]);
    }
  }

  /// 只改会话标题（重命名，不影响引用与其他元信息）
  void renameConversation(String id, String title) {
    _db.execute(
      'UPDATE ai_conversation SET title=?, updated_at=? WHERE id=?',
      [title, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  void deleteConversations(Iterable<String> ids) {
    for (final id in ids) {
      _db.execute(
        'DELETE FROM ai_message_ref WHERE message_id IN '
        '(SELECT id FROM ai_message WHERE conversation_id=?)',
        [id],
      );
      _db.execute('DELETE FROM ai_conversation WHERE id=?', [id]);
      _db.execute('DELETE FROM ai_message WHERE conversation_id=?', [id]);
      _db.execute('DELETE FROM ai_conv_ref WHERE conversation_id=?', [id]);
    }
  }

  List<Map<String, Object?>> messages(String convId) {
    final rs = _db.select(
      'SELECT id, role, content FROM ai_message WHERE conversation_id=? ORDER BY id',
      [convId],
    );
    final out = <Map<String, Object?>>[];
    for (final r in rs) {
      final id = r['id'] as int;
      out.add(<String, Object?>{
        'id': id,
        'role': r['role'] as String,
        'text': r['content'] as String,
        'refs': messageRefs(id),
      });
    }
    return out;
  }

  /// 插入消息，返回消息 id（用于挂引用链接）
  int addMessage(String convId, String role, String text) {
    _db.execute(
      'INSERT INTO ai_message(conversation_id,role,content,created_at) VALUES(?,?,?,?)',
      [convId, role, text, DateTime.now().millisecondsSinceEpoch],
    );
    touchConversation(convId);
    return _db.lastInsertRowId;
  }

  /// 消息引用的条目（气泡里显示成链接）
  List<String> messageRefs(int messageId) {
    final rs = _db.select(
      'SELECT item_id FROM ai_message_ref WHERE message_id=?',
      [messageId],
    );
    return rs.map((r) => r['item_id'] as String).toList();
  }

  void setMessageRefs(int messageId, List<String> itemIds) {
    _db.execute('DELETE FROM ai_message_ref WHERE message_id=?', [messageId]);
    for (final id in itemIds) {
      _db.execute(
        'INSERT INTO ai_message_ref(message_id,item_id) VALUES(?,?)',
        [messageId, id],
      );
    }
  }

  List<String> convRefs(String convId) {
    final rs = _db.select(
      'SELECT item_id FROM ai_conv_ref WHERE conversation_id=?',
      [convId],
    );
    return rs.map((r) => r['item_id'] as String).toList();
  }

  void setConvRefs(String convId, List<String> itemIds) {
    _db.execute('DELETE FROM ai_conv_ref WHERE conversation_id=?', [convId]);
    for (final id in itemIds) {
      _db.execute('INSERT INTO ai_conv_ref(conversation_id,item_id) VALUES(?,?)',
          [convId, id]);
    }
  }

  /// 说话人改名：把某条目下所有该说话人的分段改成新名字
  void renameSpeaker(String itemId, String from, String to) {
    _db.execute(
      'UPDATE transcript_segment SET speaker_id=? WHERE item_id=? AND speaker_id=?',
      [to, itemId, from],
    );
    rebuildIndex(itemId);
  }

  /// 保存转写分段（覆盖旧结果），并重建索引
  void saveSegments(String itemId, List<Map<String, Object?>> segs) {
    _db.execute('DELETE FROM transcript_segment WHERE item_id=?', [itemId]);
    final stmt = _db.prepare(
      'INSERT INTO transcript_segment(item_id,seq,start_ms,end_ms,text,speaker_id) VALUES(?,?,?,?,?,?)',
    );
    for (var i = 0; i < segs.length; i++) {
      final s = segs[i];
      stmt.execute([
        itemId,
        i,
        s['start'] ?? 0,
        s['end'] ?? 0,
        s['text'] ?? '',
        s['speaker'],
      ]);
    }
    stmt.dispose();
    final it = byId(itemId);
    if (it != null) {
      _db.execute(
        'UPDATE item SET transcript_status=?, updated_at=? WHERE id=?',
        ['done', DateTime.now().millisecondsSinceEpoch, itemId],
      );
    }
    rebuildIndex(itemId);
  }

  /// 可供转写使用的模型（按优先级：medium > small > large > base）
  String? findModel() {
    final dir = Directory(p.join(rootPath, 'models'));
    if (!dir.existsSync()) return null;
    // 顺序即默认档位优先级。实测（i5-13500H 无独显，44s 音频）：
    // base 4.7s 但错字多；small 23.8s 可用；medium 32.2s 准确率与 small 接近
    // → 无独显默认 small（速度优先），medium 作为可选档由设置页切换
    const prefer = [
      'ggml-small-q5_1.bin',
      'ggml-medium-q5_1.bin',
      'ggml-medium-q5_0.bin',
      'ggml-large-v3-q5_0.bin',
      'ggml-base-q5_1.bin',
    ];
    for (final name in prefer) {
      final f = File(p.join(dir.path, name));
      if (f.existsSync() && f.lengthSync() > 10 * 1024 * 1024) return f.path;
    }
    return null;
  }

  List<Map<String, Object?>> segments(String itemId) {
    final rs = _db.select(
        'SELECT start_ms, end_ms, text, speaker_id FROM transcript_segment WHERE item_id=? ORDER BY start_ms',
        [itemId]);
    return rs
        .map((r) => <String, Object?>{
              'start': r['start_ms'],
              'end': r['end_ms'],
              'text': r['text'],
              'speaker': r['speaker_id'],
            })
        .toList();
  }

  int audioCount() {
    final r = _db.select('SELECT COUNT(*) AS c FROM item WHERE type=? AND deleted_at IS NULL', ['audio']);
    return (r.first['c'] as int?) ?? 0;
  }

  int textCount() {
    final r = _db.select('SELECT COUNT(*) AS c FROM item WHERE type=? AND deleted_at IS NULL', ['text']);
    return (r.first['c'] as int?) ?? 0;
  }

  void close() {
    _db.dispose();
    _instance = null;
  }

  static String _newId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rnd = List.generate(6, (_) => (DateTime.now().microsecondsSinceEpoch + ts) % 36)
        .map((v) => v.toRadixString(36))
        .join();
    return 'it_${ts}_${rnd}';
  }

  /// 供调试导出：当前库路径
  String get dbPath => p.join(rootPath, 'gaggle.db');

  String dumpMeta() => jsonEncode({
        'root': rootPath,
        'db': dbPath,
        'audio': audioCount(),
        'text': textCount(),
      });
}
