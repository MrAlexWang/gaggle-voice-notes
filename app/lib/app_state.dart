import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'android_foreground.dart';
import 'audio_convert.dart';
import 'db.dart';
import 'lan.dart';
import 'mobile_transcribe.dart';
import 'recorder.dart';
import 'sense_voice.dart';
import 'theme.dart';
import 'transcriber.dart';

/// 全局状态：当前页签、搜索词、选中条目、录音状态、数据版本号
class AppState extends ChangeNotifier {
  AppState() {
    // 通知上的「停止」→ 正常走一遍 stopRecord，保证录音收尾落盘
    AndroidForeground.listen();
    AndroidForeground.onStopFromNotification = () {
      if (recording) unawaited(stopRecord());
    };
  }

  final RecorderService rec = RecorderService();

  int tab = 0; // 0 时间流 / 1 AI 对话 / 2 设置
  String keyword = '';

  /// 顶栏搜索框的控制器：全站共用一个搜索（时间流 + 会话）
  final TextEditingController keywordCtrl = TextEditingController();
  String? selectedId;

  bool recording = false;
  bool paused = false;
  Duration elapsed = Duration.zero;
  double level = 0;

  /// 从列表多选「发给 AI」带过来的条目 ID
  List<String> pendingRefs = [];

  /// 数据变化版本号，列表监听它来刷新
  int dataVersion = 0;

  Timer? _ticker;
  StreamSubscription<double>? _levelSub;

  /// 本次录音是否已直出 AAC/m4a（false 表示录的是需要转码的 WAV）
  bool _recAac = false;

  void setTab(int v) {
    if (tab == v) return;
    tab = v;
    notifyListeners();
  }

  void setKeyword(String v) {
    keyword = v;
    notifyListeners();
  }

  /// 清空搜索（新建会话等场景）
  void clearKeyword() {
    if (keywordCtrl.text.isNotEmpty) keywordCtrl.clear();
    keyword = '';
    notifyListeners();
  }

  void select(String id) {
    selectedId = id;
    notifyListeners();
  }

  void bumpData() {
    dataVersion++;
    notifyListeners();
  }

  /// 保证有选中项：如果为空或已失效，自动选第一条
  void ensureSelection(List<Item> items) {
    if (items.isEmpty) {
      selectedId = null;
      return;
    }
    final exists = items.any((e) => e.id == selectedId);
    if (!exists) selectedId = items.first.id;
  }

  Future<void> toggleRecord() async {
    if (recording) {
      await stopRecord();
    } else {
      await startRecord();
    }
  }

  Future<void> startRecord() async {
    final dir = Directory(p.join(Db.instance.rootPath, 'audio'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final base = p.join(dir.path, 'rec_${DateTime.now().millisecondsSinceEpoch}');

    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    // 是否优先直出 AAC（D14）。三条硬约束：
    // 1. 桌面端转写 m4a 依赖 ffmpeg（whisper 只吃 wav），没装 ffmpeg 就录 WAV，
    //    否则会出现「能录但转写不了」的坏状态
    // 2. 手机端选「本机转写」时必须录 wav：SenseVoice 只解析 wav，端上又无解码器
    // 3. 手机走「电脑转写」时要先确认那台电脑能解码 m4a（/ping 回报的 pc_ffmpeg），
    //    没确认过就保守录 WAV
    final preferAac = isDesktop
        ? AudioConvert.canTranscode
        : (!TranscribeRoute.willRunLocally &&
            Db.instance.getSetting('pc_ffmpeg') == '1');

    final started = await rec.start(base, preferAac: preferAac);
    if (started == null) {
      throw '无法开始录音，请检查麦克风权限';
    }
    _recAac = started.aac;
    // Android：起前台服务 + 常驻通知，锁屏/后台时保住进程（PRD 6.11 / D35）
    unawaited(AndroidForeground.start());
    recording = true;
    paused = false;
    elapsed = Duration.zero;
    level = 0;
    notifyListeners();

    _levelSub = rec.levels.listen((v) {
      level = v;
      notifyListeners();
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      elapsed = rec.elapsed;
      notifyListeners();
    });
  }

  Future<String?> stopRecord() async {
    final path = await rec.stop();
    unawaited(AndroidForeground.stop());
    await _levelSub?.cancel();
    _levelSub = null;
    _ticker?.cancel();
    _ticker = null;
    final durMs = rec.elapsed.inMilliseconds;

    recording = false;
    paused = false;
    level = 0;
    notifyListeners();

    if (path == null) return null;

    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final now = DateTime.now();
    // 先给个带年月日时分秒的临时名，转写完成后由 AI 换成「AI 标题 · 年月日时分秒」
    final title = '录音 · ${fmtStamp(now.millisecondsSinceEpoch)}';
    final id = Db.instance.insertItem(
      type: 'audio',
      title: title,
      sourceDevice: isDesktop ? 'pc' : 'phone',
      durationMs: durMs,
      audioPath: path,
      transcriptStatus: 'queued',
    );
    selectedId = id;
    bumpData();

    // 归档 + 派发转写。两步串行：先把 WAV 转成 m4a，再开始转写，
    // 避免转写读到已被转码删除的 wav 文件。
    unawaited(_finalizeAudio(id, path, isDesktop: isDesktop));
    return id;
  }

  /// 停录收尾：① 需要时把 WAV 归档为 AAC/m4a（D14）② 派发转写
  Future<void> _finalizeAudio(
    String itemId,
    String path, {
    required bool isDesktop,
  }) async {
    var finalPath = path;

    // 只在这轮确实录的是 WAV 时才转码；直出 AAC 的情况无需处理
    if (!_recAac && isDesktop && AudioConvert.canTranscode) {
      final m4a = await AudioConvert.toM4a(path);
      if (m4a != null && m4a != path) {
        Db.instance.setAudioPath(itemId, m4a);
        try {
          File(path).deleteSync();
        } catch (_) {}
        finalPath = m4a;
        bumpData();
      }
    }

    await _dispatchTranscribe(itemId, finalPath, isDesktop: isDesktop);
  }

  /// 按当前设置派发转写：本机 SenseVoice → 电脑 whisper → 上传电脑
  Future<void> _dispatchTranscribe(
    String itemId,
    String path, {
    required bool isDesktop,
  }) async {
    if (TranscribeRoute.willRunLocally) {
      // 设置里选了「手机转写」且模型就绪：本机离线转写
      await _localTranscribe(itemId, path, desktop: isDesktop);
    } else if (isDesktop) {
      // 电脑端：本机 whisper 队列转写
      Transcriber.instance.enqueue(itemId);
    } else {
      // 手机端交给电脑转写（局域网），失败则标记
      await _remoteTranscribe(itemId, path);
    }
  }

  /// 本机 SenseVoice 转写；失败时按端类型退回 whisper / 电脑
  Future<void> _localTranscribe(
    String itemId,
    String audioPath, {
    required bool desktop,
  }) async {
    // 逐段出结果就刷新界面，不用等整条转完
    final err = await SenseVoice.instance.transcribeItem(
      itemId,
      onPartial: bumpData,
    );
    if (err == null) {
      bumpData();
      return;
    }
    if (desktop) {
      Transcriber.instance.enqueue(itemId);
    } else {
      await _remoteTranscribe(itemId, audioPath);
    }
    bumpData();
  }

  /// 手机端：把录音上传给电脑转写，结果写回本地
  Future<void> _remoteTranscribe(String itemId, String audioPath) async {
    Db.instance.setStatus(itemId, 'running');
    notifyListeners();
    final segs = await LanClient.instance.uploadTranscribe(
      audioPath,
      durationMs: Db.instance.byId(itemId)?.durationMs,
    );
    if (segs == null || segs.isEmpty) {
      Db.instance.setStatus(itemId, 'failed');
    } else {
      Db.instance.saveSegments(itemId, segs);
      Db.instance.markUploaded(itemId);
    }
    bumpData();
  }

  /// 放弃本次录音：停止并删除临时文件，不落库
  Future<void> discardRecord() async {
    final path = await rec.stop();
    unawaited(AndroidForeground.stop());
    await _levelSub?.cancel();
    _levelSub = null;
    _ticker?.cancel();
    _ticker = null;
    recording = false;
    paused = false;
    level = 0;
    elapsed = Duration.zero;
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _recAac = false;
    notifyListeners();
  }

  Future<void> togglePause() async {
    if (paused) {
      await rec.resume();
    } else {
      await rec.pause();
    }
    paused = !paused;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _levelSub?.cancel();
    keywordCtrl.dispose();
    rec.dispose();
    super.dispose();
  }
}

/// 通过 InheritedNotifier 下发，子组件用 AppScope.of(context) 取
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未找到');
    return scope!.notifier!;
  }

  /// 只读取、不订阅变化
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未找到');
    return scope!.notifier!;
  }
}
