import 'db.dart';
import 'lan.dart';
import 'sense_voice.dart';

/// 手机端转写路由：
/// - `phone`：本机小模型（SenseVoice-Small）离线转写
/// - `pc`：录音上传电脑，用电脑的大模型转写
///
/// 本机模型没装好时，`phone` 会安全回退到电脑，保证录音不会因为选了手机转写而丢结果。
class TranscribeRoute {
  TranscribeRoute._();

  static const String settingKey = 'transcribe_on';
  static const String phone = 'phone';
  static const String pc = 'pc';

  /// 当前选择的转写位置（没设置过时：模型就绪就用手机，否则走电脑）
  static String get mode {
    final v = Db.instance.getSetting(settingKey);
    if (v == phone) return phone;
    if (v == pc) return pc;
    return SenseVoice.instance.ready ? phone : pc;
  }

  static bool get usesPhone => mode == phone;

  static void setMode(String v) =>
      Db.instance.setSetting(settingKey, v == phone ? phone : pc);

  /// 本机 SenseVoice-Small 模型是否就绪
  static bool get localReady => SenseVoice.instance.ready;

  static String get localEngineName => SenseVoice.instance.current.name;

  /// 录音结束后的实际执行路径
  static bool get willRunLocally => usesPhone && localReady;
}

/// 批量上传的结果
class UploadOutcome {
  UploadOutcome({
    this.ok = 0,
    this.skipped = 0,
    this.failed = 0,
    this.noPc = false,
  });

  /// 成功上传条数
  final int ok;

  /// 因为「已经传过」被跳过的条数
  final int skipped;

  /// 上传失败的条数
  final int failed;

  /// 没找到电脑（此时不改动任何条目状态）
  final bool noPc;
}

/// 把选中的内容（录音 + 文字速记）同步到电脑。
/// 默认跳过已经上传过的；`includeUploaded: true` 才会重复上传。
Future<UploadOutcome> uploadItemsToPc(
  List<String> ids, {
  bool includeUploaded = false,
  void Function(int done, int total)? onProgress,
}) async {
  final mappable = <Item>[];
  for (final id in ids) {
    final it = Db.instance.byId(id);
    if (it == null) continue;
    if (it.isAudio && it.audioPath != null) {
      mappable.add(it);
    } else if (!it.isAudio && (it.body ?? '').trim().isNotEmpty) {
      mappable.add(it);
    }
  }
  final todo =
      mappable.where((e) => includeUploaded || !e.uploaded).toList(growable: false);
  final skipped = mappable.length - todo.length;
  if (todo.isEmpty) return UploadOutcome(skipped: skipped);

  // 先确认电脑在线，避免一次把整批内容都标成失败
  final addr = await LanClient.instance.discover();
  if (addr == null) return UploadOutcome(skipped: skipped, noPc: true);

  var ok = 0;
  var failed = 0;
  for (var i = 0; i < todo.length; i++) {
    final it = todo[i];
    onProgress?.call(i + 1, todo.length);
    if (!it.isAudio) {
      // 文字速记：直接建一条笔记
      final sent = await LanClient.instance.uploadNote(
        title: it.title,
        body: it.body ?? '',
        createdAt: it.createdAt,
      );
      if (sent) {
        Db.instance.markUploaded(it.id);
        ok++;
      } else {
        failed++;
      }
      continue;
    }
    Db.instance.setStatus(it.id, 'running');
    final segs = await LanClient.instance.uploadTranscribe(
      it.audioPath!,
      durationMs: it.durationMs,
    );
    if (segs == null || segs.isEmpty) {
      Db.instance.setStatus(it.id, 'failed');
      failed++;
    } else {
      Db.instance.saveSegments(it.id, segs);
      Db.instance.markUploaded(it.id);
      ok++;
    }
  }
  return UploadOutcome(ok: ok, skipped: skipped, failed: failed);
}

/// 还没同步到电脑的内容（录音 + 文字速记），一键同步 / 设置页用
List<String> pendingSyncIds() => Db.instance.items().where((e) {
      if (e.uploaded) return false;
      if (e.isAudio) return e.audioPath != null;
      return (e.body ?? '').trim().isNotEmpty;
    }).map((e) => e.id).toList();

/// 兼容旧调用：只取录音
List<String> pendingAudioIds() => pendingSyncIds()
    .where((id) => Db.instance.byId(id)?.isAudio ?? false)
    .toList();

/// 选中的录音里已经传过的那些
List<Item> uploadedAmong(List<String> ids) => ids
    .map((id) => Db.instance.byId(id))
    .whereType<Item>()
    .where((e) => e.isAudio && e.uploaded)
    .toList();
