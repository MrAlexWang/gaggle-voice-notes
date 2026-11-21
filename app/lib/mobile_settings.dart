import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'android_foreground.dart';
import 'app_state.dart';
import 'config.dart';
import 'db.dart';
import 'lan.dart';
import 'mobile_common.dart';
import 'mobile_transcribe.dart';
import 'sense_voice.dart';
import 'theme.dart';

// ============================================================
// 手机端设置
// ============================================================
class MobileSettingsPage extends StatefulWidget {
  const MobileSettingsPage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<MobileSettingsPage> createState() => _MobileSettingsPageState();
}

class _MobileSettingsPageState extends State<MobileSettingsPage> {
  final _pcCtrl = TextEditingController();
  bool _testing = false;
  String _testResult = '';
  String? _pcAddr;
  int _size = 0;

  /// 转写位置：手机 (phone) / 电脑 (pc)
  String _mode = TranscribeRoute.mode;
  bool _uploading = false;
  String _uploadMsg = '';
  bool _svDownloading = false;
  String _svMsg = '';

  /// 正在下载哪个档位
  String _svTarget = '';

  /// 后台保活状态
  bool _batteryOk = false;

  @override
  void initState() {
    super.initState();
    _pcAddr = Db.instance.getSetting('lan_pc');
    _pcCtrl.text = _pcAddr ?? '';
    // 下载可能在别的页面时就已开始，这里同步一下状态
    _svDownloading = SenseVoice.instance.downloading;
    _refreshBattery();
    // 目录可能有几百 MB，放到后台算，避免进页面卡一下
    Future(() => DataLocation.sizeOf(Db.instance.rootPath)).then((v) {
      if (mounted) setState(() => _size = v);
    });
  }

  @override
  void dispose() {
    _pcCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshBattery() async {
    final ok = await AndroidForeground.isIgnoringBatteryOptimizations();
    if (mounted) setState(() => _batteryOk = ok);
  }

  Future<void> _askBattery() async {
    await AndroidForeground.requestIgnoreBatteryOptimizations();
    // 系统弹窗关闭后回来刷新一次状态
    await Future.delayed(const Duration(milliseconds: 600));
    await _refreshBattery();
  }

  Future<void> _askNotif() async {
    await AndroidForeground.requestNotificationPermission();
  }

  Future<void> _autoDiscover() async {
    setState(() {
      _testing = true;
      _testResult = '正在搜索局域网中的电脑…';
    });
    final addr = await LanClient.instance.discover();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = addr == null
          ? '没找到电脑。请确认电脑端雁书在运行且在同一 Wi-Fi'
          : '已连接 $addr';
      if (addr != null) {
        _pcCtrl.text = addr;
        _pcAddr = addr;
      }
    });
  }

  Future<void> _testManual() async {
    final v = _pcCtrl.text.trim();
    if (v.isEmpty) return;
    setState(() {
      _testing = true;
      _testResult = '';
    });
    Db.instance.setSetting('lan_pc', v);
    final ok = await LanClient.instance.ping(v);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _pcAddr = ok ? v : null;
      _testResult = ok ? '连接成功：$v' : '连不上 $v，请检查 IP 与电脑端状态';
    });
  }

  Future<void> _openTrash() async {
    await showMobileTrash(context);
    if (!mounted) return;
    setState(() => _size = DataLocation.sizeOf(Db.instance.rootPath));
  }

  void _setMode(String v) {
    TranscribeRoute.setMode(v);
    setState(() {
      _mode = TranscribeRoute.mode;
      _uploadMsg = '';
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

  /// 一键把还没转写的录音全部上传给电脑
  Future<void> _uploadPending() async {
    if (_uploading) return;
    final ids = pendingSyncIds();
    if (ids.isEmpty) {
      _toast('没有待同步的内容');
      return;
    }
    setState(() {
      _uploading = true;
      _uploadMsg = '正在上传 0/${ids.length} 条…';
    });
    final r = await uploadItemsToPc(ids, onProgress: (done, total) {
      if (mounted) setState(() => _uploadMsg = '正在上传 $done/$total 条…');
    });
    if (!mounted) return;
    setState(() {
      _uploading = false;
      if (r.noPc) {
        _uploadMsg = '没找到电脑：请先在上面连接电脑，或确认与电脑在同一 Wi-Fi';
      } else {
        final parts = <String>[
          if (r.ok > 0) '已上传 ${r.ok} 条',
          if (r.skipped > 0) '跳过 ${r.skipped} 条（已传过）',
          if (r.failed > 0) '失败 ${r.failed} 条',
        ];
        _uploadMsg = parts.isEmpty ? '没有需要上传的录音' : parts.join(' · ');
      }
    });
    AppScope.read(context).bumpData();
  }

  /// 下载指定档位的模型
  Future<void> _downloadModel(AsrModel m) async {
    if (_svDownloading) return;
    setState(() {
      _svDownloading = true;
      _svTarget = m.id;
      _svMsg = '';
    });
    try {
      await SenseVoice.instance.download(m);
      if (!mounted) return;
      setState(() {
        _svDownloading = false;
        _svTarget = '';
        _svMsg = '${m.name} 已就绪，可以用了';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _svDownloading = false;
        _svTarget = '';
        _svMsg = '$e';
      });
    }
  }

  void _useModel(AsrModel m) {
    SenseVoice.instance.select(m);
    setState(() {
      _mode = TranscribeRoute.mode;
      _svMsg = '已切换到 ${m.name}';
    });
  }

  /// 从本地文件导入到当前档位（同时选中 .onnx 与 tokens.txt）
  Future<void> _importModel(AsrModel m) async {
    const group = XTypeGroup(
      label: '转写模型',
      extensions: ['onnx', 'txt'],
    );
    List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: const [group]);
    } catch (_) {
      return;
    }
    if (files.isEmpty) return;
    String? model;
    String? tokens;
    for (final f in files) {
      final name = f.name.toLowerCase();
      if (name.endsWith('.onnx')) model = f.path;
      if (name.endsWith('.txt')) tokens = f.path;
    }
    if (model == null || tokens == null) {
      _toast('请同时选中 .onnx 模型和 tokens.txt');
      return;
    }
    try {
      await SenseVoice.instance.installFiles(
        modelSrc: model,
        tokensSrc: tokens,
        target: m,
      );
      if (!mounted) return;
      setState(() => _svMsg = '${m.name} 导入完成，可以用了');
      _toast('模型已就绪');
    } catch (e) {
      if (!mounted) return;
      setState(() => _svMsg = '导入失败：$e');
    }
  }

  Future<void> _removeModel(AsrModel m) async {
    final ok = await showMobileConfirm(
      context,
      title: '删除 ${m.name}？',
      desc: '删除后要重新下载或导入，才能继续用它转写。',
    );
    if (!ok) return;
    await SenseVoice.instance.remove(m);
    if (!mounted) return;
    setState(() => _svMsg = '已删除 ${m.name}');
  }

  @override
  Widget build(BuildContext context) {
    final audio = Db.instance.audioCount();
    final text = Db.instance.textCount();
    final trash = Db.instance.items(trash: true).length;
    final connected = _pcAddr != null;

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
                    onTap: widget.onClose,
                  ),
                  const SizedBox(width: 2),
                  const Text('设置',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
                children: [
                  _card('与电脑连接', [
                    _row(
                      '当前状态',
                      connected ? '已连接 $_pcAddr' : '未连接',
                      trailing: Text(
                        connected ? '已就绪' : '未连接',
                        style: TextStyle(
                          fontSize: 12,
                          color: connected ? Palette.green : Palette.muted2,
                        ),
                      ),
                    ),
                    _row('电脑端需同时运行「雁书」', '录音转写、AI 对话都借用电脑的算力'),
                    _row(
                      '电脑端智能体',
                      LanClient.instance.agentIssue ??
                          (connected ? '已就绪，可在 AI 对话里调用' : '连上电脑后显示状态'),
                      trailing: Text(
                        LanClient.instance.agentIssue == null && connected
                            ? '就绪'
                            : '未就绪',
                        style: TextStyle(
                          fontSize: 12,
                          color: LanClient.instance.agentIssue == null &&
                                  connected
                              ? Palette.green
                              : Palette.muted2,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  height: 40,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 11),
                                  decoration: BoxDecoration(
                                    color: Palette.paper,
                                    border: Border.all(color: Palette.line),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Center(
                                    child: TextField(
                                      controller: _pcCtrl,
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          fontFamily: Palette.monoFamily,
                                          fontFamilyFallback:
                                              Palette.monoFallback),
                                      cursorColor: Palette.gold,
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        hintText: '192.168.1.10:47825',
                                        hintStyle: TextStyle(
                                            fontSize: 12.5,
                                            color: Palette.muted2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              MobileBtn(
                                label: _testing ? '连接中…' : '连接',
                                height: 40,
                                onTap: _testing ? () {} : _testManual,
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: MobileBtn(
                              label: '自动搜索电脑',
                              height: 34,
                              icon: Icons.wifi_find,
                              onTap: _testing ? () {} : _autoDiscover,
                            ),
                          ),
                          if (_testResult.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 9),
                              child: Text(
                                _testResult,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.6,
                                  color: _testResult.startsWith('已连接') ||
                                          _testResult.startsWith('连接成功')
                                      ? Palette.green
                                      : Palette.red,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ]),
                  _card('转写', [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('转写位置',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Palette.text)),
                          const SizedBox(height: 3),
                          const Text('录音结束后用哪一端来转写',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Palette.muted2,
                                  height: 1.5)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _modeTile(
                                  title: '手机转写',
                                  desc: TranscribeRoute.localReady
                                      ? '本机 ${TranscribeRoute.localEngineName} · 离线不联网'
                                      : '需内置 ${TranscribeRoute.localEngineName} 模型',
                                  selected: _mode == TranscribeRoute.phone,
                                  onTap: () =>
                                      _setMode(TranscribeRoute.phone),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _modeTile(
                                  title: '电脑转写',
                                  desc: '录音上传电脑，用大模型更准',
                                  selected: _mode == TranscribeRoute.pc,
                                  onTap: () => _setMode(TranscribeRoute.pc),
                                ),
                              ),
                            ],
                          ),
                          if (_mode == TranscribeRoute.phone &&
                              !TranscribeRoute.localReady)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                '本机引擎还没内置：当前会自动回退电脑转写，录音不会丢。',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Palette.goldDeep,
                                    height: 1.6),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      key: const ValueKey('sv-model'),
                      padding: const EdgeInsets.fromLTRB(14, 13, 14, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('手机端小模型',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: Palette.text)),
                              const Spacer(),
                              Text(
                                TranscribeRoute.localReady
                                    ? '使用中 · ${SenseVoice.instance.current.name}'
                                    : '未安装',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: TranscribeRoute.localReady
                                      ? Palette.green
                                      : Palette.muted2,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          const Text(
                            '离线不联网，装在手机上直接转写；不同模型的语种、速度和准确率不同',
                            style: TextStyle(
                                fontSize: 11,
                                color: Palette.muted2,
                                height: 1.5),
                          ),
                          const SizedBox(height: 9),
                          for (final m in kAsrModels) _asrTile(m),
                          ValueListenableBuilder<double>(
                            valueListenable: SenseVoice.instance.prepareProgress,
                            builder: (_, p, __) {
                              if (p < 0) return const SizedBox.shrink();
                              final hint =
                                  SenseVoice.instance.prepareHint.value;
                              return Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(3),
                                      child: LinearProgressIndicator(
                                        value: p <= 0 ? null : p,
                                        minHeight: 4,
                                        backgroundColor: Palette.line2,
                                        valueColor:
                                            const AlwaysStoppedAnimation(
                                                Palette.gold),
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      '${hint.isEmpty ? '准备中…' : hint}'
                                      '${p > 0 ? ' ${(p * 100).round()}%' : ''}',
                                      style: const TextStyle(
                                          fontSize: 10.5,
                                          color: Palette.muted2),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          if (_svMsg.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _svMsg,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.6,
                                  color: _svMsg.contains('已就绪') ||
                                          _svMsg.contains('导入完成') ||
                                          _svMsg.contains('已切换')
                                      ? Palette.green
                                      : Palette.muted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _row(
                      '电脑端',
                      connected
                          ? '已连接，可随时把录音传过去转写'
                          : '未连接：打开电脑端雁书并在同一 Wi-Fi',
                      trailing: Text(
                        connected ? '已连接' : '未连接',
                        style: TextStyle(
                          fontSize: 12,
                          color: connected ? Palette.green : Palette.muted2,
                        ),
                      ),
                    ),
                    _row('说话人区分', '由电脑端模型完成，详情页点标签可改名'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MobileBtn(
                            label: _uploading ? '正在上传…' : '同步录音与速记到电脑',
                            height: 38,
                            icon: Icons.cloud_upload_outlined,
                            onTap: _uploading ? () {} : _uploadPending,
                          ),
                          if (_uploadMsg.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _uploadMsg,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.6,
                                  color: _uploadMsg.startsWith('已上传')
                                      ? Palette.green
                                      : Palette.muted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ]),
                  _card('后台保活', [
                    _row(
                      '电池优化白名单',
                      _batteryOk
                          ? '已加入白名单，息屏后录音不会被系统回收'
                          : '未加入，长时间录音可能被系统中断',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _batteryOk ? '已忽略' : '未设置',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: _batteryOk
                                  ? Palette.green
                                  : const Color(0xFF4B6166),
                            ),
                          ),
                          const SizedBox(width: 8),
                          MobileBtn(
                            label: _batteryOk ? '已就绪' : '去设置',
                            height: 28,
                            onTap: _batteryOk ? () {} : _askBattery,
                          ),
                        ],
                      ),
                    ),
                    _row(
                      '通知权限',
                      '录音时在通知栏显示计时与「停止」，锁屏也能看到状态',
                      trailing: MobileBtn(
                          label: '授权', height: 28, onTap: _askNotif),
                    ),
                    _row(
                      '厂商限制',
                      '小米 / 华为 / OPPO / vivo 还需在系统设置里允许「自启动」与「后台运行」',
                    ),
                  ]),
                  _card('存储', [
                    _row(
                      '已占用',
                      '录音 $audio 条 · 笔记 $text 条',
                      trailing: Text(
                        DataLocation.human(_size),
                        style: const TextStyle(
                            fontSize: 12.5, color: Color(0xFF4B6166)),
                      ),
                    ),
                    _row(
                      '回收站',
                      '已删除的条目保留 30 天，到期自动清除',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$trash 条',
                              style: const TextStyle(
                                  fontSize: 12.5, color: Color(0xFF4B6166))),
                          const SizedBox(width: 8),
                          MobileBtn(
                              label: '查看', height: 28, onTap: _openTrash),
                        ],
                      ),
                    ),
                  ]),
                  _card('关于', [
                    _row('雁书 Gaggle', '把念头，寄给未来的自己'),
                    _row('版本', '0.1.0 (Android)'),
                    _row('数据', '全部存在手机本地，不上传服务器'),
                  ]),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.folder_outlined,
                          size: 13, color: Palette.muted2),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '数据目录：${Db.instance.rootPath}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Palette.muted2,
                            fontFamily: Palette.monoFamily,
                            fontFamilyFallback: Palette.monoFallback,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Palette.line2)),
            ),
            child: Text(title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Palette.muted,
                  letterSpacing: 0.8,
                )),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _row(String title, String desc, {Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Palette.text)),
                const SizedBox(height: 3),
                Text(desc,
                    style: const TextStyle(
                        fontSize: 11, color: Palette.muted2, height: 1.5)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing],
        ],
      ),
    );
  }

  /// 一个转写模型档位
  Widget _asrTile(AsrModel m) {
    final downloaded = SenseVoice.instance.isDownloaded(m);
    final active = SenseVoice.instance.current.id == m.id;
    final downloading = _svDownloading && _svTarget == m.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: active ? Palette.goldBg : Colors.white,
        border: Border.all(color: active ? Palette.gold : Palette.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Palette.text,
                  ),
                ),
              ),
              Text(
                downloaded
                    ? (active ? '使用中' : '已下载')
                    : '${m.sizeMB} MB',
                style: TextStyle(
                  fontSize: 11.5,
                  color: active
                      ? Palette.goldDeep
                      : (downloaded ? Palette.green : Palette.muted2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            m.desc,
            style: const TextStyle(
                fontSize: 11, color: Palette.muted2, height: 1.5),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (!downloaded)
                MobileBtn(
                  label: downloading ? '下载中…' : '下载',
                  height: 28,
                  icon: Icons.cloud_download_outlined,
                  onTap: _svDownloading ? () {} : () => _downloadModel(m),
                ),
              if (downloaded && !active)
                MobileBtn(
                  label: '使用',
                  height: 28,
                  solid: true,
                  onTap: () => _useModel(m),
                ),
              if (!downloaded) ...[
                const SizedBox(width: 8),
                MobileBtn(
                  label: '导入文件',
                  height: 28,
                  icon: Icons.folder_open,
                  onTap: _svDownloading ? () {} : () => _importModel(m),
                ),
              ],
              if (downloaded) ...[
                const SizedBox(width: 8),
                MobileBtn(
                  label: '删除',
                  height: 28,
                  danger: true,
                  onTap: () => _removeModel(m),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 转写位置二选一卡片
  Widget _modeTile({
    required String title,
    required String desc,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
        decoration: BoxDecoration(
          color: selected ? Palette.goldBg : Colors.white,
          border: Border.all(color: selected ? Palette.gold : Palette.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 14,
                  color:
                      selected ? Palette.goldDeep : const Color(0xFFB4BFBF),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: selected ? Palette.text : Palette.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              desc,
              style: const TextStyle(
                  fontSize: 10.5, color: Palette.muted2, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 回收站（底部抽屉）
// ============================================================
Future<void> showMobileTrash(BuildContext context) async {
  final st = AppScope.read(context);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x660B2226),
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final rows = Db.instance.items(trash: true);
        void refresh() {
          st.bumpData();
          setSheet(() {});
        }

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.72,
          ),
          decoration: mobileSheetDecoration,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabber(),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 14, 10),
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline,
                        size: 16, color: Palette.muted),
                    const SizedBox(width: 8),
                    const Text('回收站',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    const Text('保留 30 天',
                        style: TextStyle(
                            fontSize: 11.5, color: Palette.muted2)),
                  ],
                ),
              ),
              const Divider(height: 1, color: Palette.line2),
              Flexible(
                child: rows.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Text('回收站是空的',
                            style: TextStyle(
                                fontSize: 12.5, color: Palette.muted2)),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: rows.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: Palette.line2),
                        itemBuilder: (_, i) {
                          final it = rows[i];
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
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
                                    it.isAudio
                                        ? Icons.mic_none
                                        : Icons.edit_outlined,
                                    size: 15,
                                    color: Palette.textIc,
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(it.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500)),
                                      const SizedBox(height: 4),
                                      Text(
                                        '删除于 ${fmtClock(it.deletedAt ?? it.createdAt)}',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Palette.muted2),
                                      ),
                                    ],
                                  ),
                                ),
                                MobileBtn(
                                  label: '恢复',
                                  height: 28,
                                  onTap: () {
                                    Db.instance.restore(it.id);
                                    refresh();
                                  },
                                ),
                                const SizedBox(width: 6),
                                MobileBtn(
                                  label: '彻底删除',
                                  height: 28,
                                  danger: true,
                                  onTap: () {
                                    Db.instance.purge(it.id);
                                    refresh();
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              Container(
                padding: EdgeInsets.fromLTRB(
                    14, 10, 14, 12 + MediaQuery.of(ctx).padding.bottom),
                decoration: const BoxDecoration(
                  color: Color(0xFFFBF9F5),
                  border: Border(top: BorderSide(color: Palette.line2)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('共 ${rows.length} 条',
                          style: const TextStyle(
                              fontSize: 11.5, color: Palette.muted)),
                    ),
                    MobileBtn(
                      label: '清空回收站',
                      height: 30,
                      danger: true,
                      onTap: rows.isEmpty
                          ? () {}
                          : () async {
                              final ok = await showMobileConfirm(
                                ctx,
                                title: '清空回收站？',
                                desc: '将彻底删除 ${rows.length} 条内容，无法恢复。',
                                okLabel: '清空',
                              );
                              if (!ok) return;
                              for (final r
                                  in Db.instance.items(trash: true)) {
                                Db.instance.purge(r.id);
                              }
                              refresh();
                            },
                    ),
                    const SizedBox(width: 8),
                    MobileBtn(
                      label: '关闭',
                      height: 30,
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
