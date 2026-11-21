# 雁书 Gaggle · 技术方案 v2.1

> 对应 PRD：`docs/PRD.md` **v2.6**（MVP 需求定稿 + 实现审计）
> 对应原型：`prototype/index.html` v0.3（界面与交互的唯一视觉依据）
> 状态：**选型已确认** · M1~M4 主链路已落地 · 待补清单见 PRD 第 15 章
> 标记：`[已定]` 本方案选定；`[待验证]` 需先做技术验证（Spike）；`[备选]` 有退化方案

---

## 0. 文档定位：这份文件用来干什么

三份文档各管一段，不要混用：

| 文档 | 回答的问题 | 读者 | 变更频率 |
|---|---|---|---|
| `PRD.md` | **做什么、为什么做、怎样算做完**（场景、范围、验收、风险） | 你（产品决策）、我（理解需求） | 高，随对话改 |
| `TECH_DESIGN.md`（本文） | **怎么做**（选型、分层、DDL、接口、性能预算、Spike、任务拆解） | 我（写代码时唯一实现依据） | 中，选型或结构变化时改 |
| `prototype/index.html` | **长什么样、怎么点**（布局、状态、交互反馈） | 你（验收界面）、我（对齐 UI 细节） | 高，评审时改 |

**它在 vibe coding 里的实际作用**

1. **防止架构漂移**：Flutter ↔ Electron、mDNS ↔ UDP、FTS5 ↔ 分词倒排，这些选择一旦写死就不在每轮对话里重新纠结。
2. **给 AI 一个稳定的施工图**：写代码时按第 4 节的模块边界和第 7 节的接口落地，避免"越写越随手"。
3. **把风险提前变成任务**：第 9 节 Spike 就是"先试再写"，第 12 节风险表对应到具体的应对动作。
4. **三个月后能解释清楚"当初为什么这么选"**：选型对比表与变更记录就是决策日志。

**维护规则**：PRD 新增决策 → 本文档同步受影响章节 → 变更记录里写一行。**只改 PRD 不改这里，等于没定。**

---

## 1. 结论摘要

| 项 | 结论 |
|---|---|
| 桌面 + 移动端 | **Flutter（Dart）单代码库**，Windows + Android 一套 UI 与业务逻辑 |
| 数据库 | **SQLite + Drift + FTS5(trigram 分词)** |
| 音频采集 | `record` 插件（WASAPI / MediaFoundation），**AAC-LC 直出 m4a** `[待验证]` |
| 本地 ASR | **whisper.cpp（GGML/GGUF 量化模型）via FFI**，按硬件自动选档 |
| 任务队列 | SQLite 持久化队列 + 后台 Isolate 串行消费 |
| 局域网传输 | **UDP 广播发现 + HTTP 传输**，配对码确认，绑定私网 |
| A2A | 自研适配层，**同时支持 v1.0（PascalCase）与 0.3（`message/send`）** |
| 波形渲染 | 自绘 CustomPainter + 预计算峰值包络（不引第三方波形库） |
| 打包 | Windows：Inno Setup 安装包 + 便携 zip；Android：arm64 APK |

**一句话架构**：Flutter UI 层 → Dart 服务层（录音/队列/检索/A2A/传输）→ FFI 与插件层（whisper.cpp、音频、窗口、快捷键）→ 本地 SQLite + 文件系统。

---

## 2. 技术选型

### 2.1 客户端框架对比

| 方案 | Windows | Android | 代码复用 | 包体 | 关键风险 |
|---|---|---|---|---|---|
| **Flutter `[已定]`** | 良好 | 优秀 | **一套代码** | 30~60MB | 桌面端部分插件为社区维护 |
| Electron + TS | 优秀 | 需另做 RN/原生 | 低（双代码库） | 150MB+ | 双端两套实现，工期翻倍 |
| Tauri 2 + React | 优秀（Rust） | 早期支持 | 中 | 10~20MB | 移动端成熟度不足，音频/FFI 生态弱 |
| .NET WPF | 优秀 | 不可用 | 无 | 小 | 无法覆盖 Android |

**选择 Flutter 的决定性理由**：MVP 要求 Windows 与 Android **同时首发**，且两端都要跑本地 ASR、共用同一套数据模型与 A2A 协议。只有单代码库方案能避免"同一功能写两遍"。相比包体与桌面精致度，工期与一致性优先。

### 2.2 本地 ASR 引擎对比

| 方案 | 跨端 | 量化 | GPU | 说明 |
|---|---|---|---|---|
| **whisper.cpp (GGML) `[已定]`** | 优秀（含 Android ARM） | q4/q5/q8 | CUDA / Vulkan / Metal | FFI 直调，无运行时依赖 |
| faster-whisper (CTranslate2) | 仅桌面 | 支持 | CUDA | CPU 最快，但需 Python 运行时，打包困难 |
| sherpa-onnx | 优秀 | 支持 | CUDA EP | 生态好，但 whisper 支持不如原版完整 |
| 云 API | — | — | — | MVP 不做（仅预留开关） |

### 2.3 关键技术依赖

| 用途 | 依赖 | 状态 |
|---|---|---|
| 录音 | `record` | `[待验证]` Windows 是否支持 aacLc 直出 |
| 数据库 | `drift` + `sqlite3_flutter_libs` | `[待验证]` FTS5 trigram 是否可用 |
| ASR FFI | `whisper.cpp` 编译产物 + `ffi` | `[待验证]` 见第 9 节 Spike |
| 全局快捷键 | `hotkey_manager` | `[待验证]` 冲突检测能力 |
| 托盘 | `tray_manager` | `[待验证]` |
| 无边框/置顶悬浮窗 | `window_manager` | `[待验证]` 多显示器适配 |
| HTTP 服务 | `shelf` | 已定 |
| 局域网发现 | UDP 广播（自实现，`dart:io` RawDatagramSocket） | 已定，避免 mDNS 插件跨端差异 |
| HTTP 客户端 / SSE | `http` + 自实现 SSE 解析 | 已定 |
| 路径/文件 | `path_provider` | 已定 |
| 音频解码 / 抽轨 | **FFmpeg（LGPL 构建）** | 已定（D45），需按 LGPL 合规打包 |
| 文件哈希（判重） | `crypto`（SHA-256） | 已定 |

> 说明：局域网发现**不用 mDNS 插件**，改用 UDP 广播自实现。原因：mDNS 插件在 Windows 与 Android 上行为差异大，且 Agent 侧未必注册 `_a2a._tcp`；UDP 广播两端代码完全一致，可控。

---

## 3. 总体架构

### 3.1 分层

```
┌─────────────────────────────────────────────────────┐
│  UI 层（Flutter Widgets）                            │
│  主窗口 / 详情 / AI 对话 / 设置 / 悬浮录音条 / 速记窗  │
└───────────────────────┬─────────────────────────────┘
                        │ Riverpod 状态
┌───────────────────────▼─────────────────────────────┐
│  服务层（Dart，纯逻辑，可单测）                       │
│  RecordingService  TranscriptQueue  SearchService    │
│  A2aManager        LanTransferService  SettingsService│
└───────────────────────┬─────────────────────────────┘
                        │ Repository 接口
┌───────────────────────▼─────────────────────────────┐
│  数据层                                              │
│  Drift DAO / FTS5 索引 / 文件存储 / 模型仓库          │
└───────────────────────┬─────────────────────────────┘
                        │ FFI / Platform Channel
┌───────────────────────▼─────────────────────────────┐
│  平台能力层                                          │
│  AudioRecorder  WhisperEngine  Hotkey  Tray  Window  │
└─────────────────────────────────────────────────────┘
```

### 3.2 并发模型

| 任务 | 承载 | 说明 |
|---|---|---|
| UI 渲染 | 主 Isolate | 只做绘制与轻计算 |
| 录音写入 | 平台原生线程 + 文件流 | 30s 分段写临时块，避免内存累积 |
| ASR 转写 | **独立 Isolate**，串行 1 任务 | 避免阻塞 UI；一次只跑一个，防止 CPU 打满 |
| 局域网传输 | 独立 Isolate（Socket/HTTP） | 大文件不占主线程 |
| A2A 流式接收 | 主 Isolate（HTTP 流解析轻量） | 逐 token 追加到 UI |

### 3.3 主数据流

**录音链路**
```
快捷键 → RecordingService.start()
      → 生成 item(UUID, status=none) 入 DB
      → AudioRecorder 写入 audio/2026/11/<uuid>.m4a.part（30s 一段）
停止 → 合并为 .m4a → 写 audio_file → enqueue asr_job
      → TranscriptQueue 消费 → WhisperEngine(Isolate) → 写 transcript_segment + search_idx
      → item.title = 首句（前 20 字）→ status=done
```

**检索链路**
```
输入关键词 → SearchService
  ├─ 长度 ≥3 → FTS5 trigram MATCH
  └─ 长度 ≤2 → LIKE '%kw%'（trigram 不支持短查询）
→ 命中 (item_id, seg_id, start_ms) → UI 列表高亮
→ 点击 → 播放器 seek(start_ms) → 播放
```

**问 AI 链路**
```
多选条目 → 拼装语料 → A2aManager.send(conversationId, items, prompt)
→ 发现层选中 Agent → A2aAdapter(version) → SendStreamingMessage
→ SSE 流 → ai_message 增量更新 → UI 逐字渲染
```

---

## 4. 模块设计

### 4.1 录音采集

- **最终格式**：44.1kHz / 单声道 / **AAC-LC 128kbps（m4a）**，约 57MB/小时（D14）
- **实现路径（已落地）**：见 `recorder.dart` + `audio_convert.dart`
  1. `RecorderService.start(basePath)` 优先用 `AudioEncoder.aacLc` 直出 `.m4a`
  2. 直出失败（部分声卡/机型）→ 自动 `cancel()` 后改录 `.wav`，由返回值告诉上层
  3. 停录后若确实是 WAV 且桌面端有 ffmpeg → `AudioConvert.toM4a()` 转码 → `Db.setAudioPath()` 换成 m4a → 删除临时 WAV
  4. 转写再解出 16kHz 单声道 PCM 中间态（`Transcriber` 用 ffmpeg；手机端 SenseVoice 直接读 wav）
- **降级规则（重要）**：能不能录 AAC 取决于**能不能转写 AAC**
  - 桌面：只有检测到 ffmpeg 才录 AAC（whisper 只吃 wav）；找不到 ffmpeg 就录 WAV，避免"能录但转写不了"
  - 手机：Android 无 ffmpeg，无法把 m4a 解给 SenseVoice → 选「本机转写」时录 WAV，其余（走电脑转写）录 AAC
  - 判定集中在 `app_state.startRecord()` 的 `preferAac`
- **打包要求**：`engine/ffmpeg.exe` 必须随包分发，否则干净安装会退回 WAV。当前本机 ffmpeg 为 217MB 完整版，**建议换 LGPL 精简构建（约 20~30MB）**，只保留 aac / wav / pcm 编解码与 resampler
- **手机端能力协商（已实现）**：`/ping` 回报 `ffmpeg` 布尔值，手机侧 `ping()` 成功后写入 `setting.pc_ffmpeg`；`AppState.startRecord()` 据此决定录 AAC 还是 WAV。手机启动时 `MobileShell.initState` 会后台 `discover()` 一次，尽早拿到该能力
- **设置页可见性**：设置 → 转写 → 「音频归档」一行显示 `AAC · 已就绪` 或 `WAV · 缺 ffmpeg`，避免用户不知道为什么文件变大
- **顺序保证**：转码与派发转写串行（`_finalizeAudio` → `_dispatchTranscribe`），避免转写读到已被删除的 wav
- **分段写入**：每 30s 落一个 `.part` 分片，停止时按顺序合并为完整 m4a；崩溃后检测 `*.part` 残留并提示恢复
- **暂停/继续**：暂停仅停止写入，恢复后在文件末尾继续，不产生断裂
- **电平**：`record` 的 `onAmplitudeChanged` 流 → 悬浮条渲染（10Hz 足够，避免耗电）
- **设备切换**：录音中切换耳机时提示"设备已变更，是否重启录音"（MVP 只提示，不热切换）
- **失败恢复**：进程启动时扫描 `audio/**/*.part`，发现残留 → 弹窗「发现未完成录音（12:03，3分12秒），是否恢复？」

### 4.2 存储与检索

**目录**
```
<根目录>/                       # 用户可在设置中修改，默认 %LOCALAPPDATA%\Gaggle
  db/gaggle.db                  # SQLite
  db/backup/                    # 升级前自动备份（保留最近 3 份）
  audio/2026/11/<uuid>.m4a
  models/whisper-large-v3-q5.bin
  logs/gaggle-2026-11-19.log
  tmp/                          # 录音分片、传输临时文件
```

**中文检索方案（关键）**
FTS5 默认 `unicode61` 分词器对中文无效（整句变一个 token）。方案：

1. 建一张统一索引表，`tokenize='trigram'`（SQLite ≥3.34），支持中文子串匹配
2. 查询词长度 ≤2 时 trigram 失效 → 回退 `LIKE '%kw%'`（数据量 <10 万条时性能可接受）
3. 写索引由触发器维护，避免应用层漏更新

**索引重建策略（对应 PRD D31 内容可编辑）**
用户改标题 / 速记正文 / 转写分段后，必须让新词可搜、旧词不可搜：

```
编辑保存 → 事务内：
  1. UPDATE 目标表（text_note / transcript_segment / item.title）
  2. DELETE FROM search_idx WHERE item_id = ?
  3. 重插入该条目所有可索引文本（标题 + 正文 或 分段）
  COMMIT
```
- 按**条目粒度**重建，不重建整库；1 万条库中单条重建 < 20ms
- 触发器只负责"新增"，编辑走应用层显式重建（避免触发器递归与顺序问题）
- 编辑为**段落级**：只改一段时仅重建该段对应行，性能更好

**软删除与回收站（对应 PRD D32）**
- `item.deleted_at` 非空 = 在回收站；所有列表/搜索查询强制 `deleted_at IS NULL`
- 回收站列表：`deleted_at IS NOT NULL ORDER BY deleted_at DESC`
- 恢复：`deleted_at = NULL` 并重建索引；彻底删除：删库行 + 删音频文件（先删文件再删行，失败可重试）
- 定时清理：启动时执行一次 `purgeExpired()`，删除 `deleted_at < now-30d`

**同步策略**：SQLite 开启 WAL；所有写操作走单写连接（Drift 默认），避免 `database is locked`。

### 4.3 ASR 引擎与模型档位

**档位决策表**（启动时探测一次，结果缓存，允许手动覆盖）

| 条件 | Windows 档位 | 模型 | 大小 |
|---|---|---|---|
| 有 GPU（显存 ≥4GB）且内存 ≥16GB | A | large-v3 q5_1 | ~1.1GB |
| 无 GPU，内存 ≥16GB | B | medium q5_1 | ~0.55GB |
| 内存 8~16GB | C | small q5_1 | ~0.19GB |
| 内存 <8GB | D | base q5_1 | ~0.15GB |
| Android（内存 ≥6GB） | E | small q5_1（INT8） | ~0.19GB |
| Android（内存 <6GB） | F | base q5_1（INT8） | ~0.15GB |

- GPU 探测：Windows 通过 `nvidia-smi` 存在性 + 显存读取（失败则视为无 GPU）
- 模型**不打包进安装包**，首次转写时按档位下载（带 SHA256 校验 + 断点续传）
- 用户可手动选更高档，UI 提示"更准但更慢（预计 10 分钟音频约 X 分钟）"

**转写参数**
- `language=zh`，`initial_prompt="以下是普通话与英文技术术语混合的录音内容。"`（提升中英混说表现）
- `n_threads = 物理核心数 - 1`
- VAD 开启：跳过静音段，长录音可提速 20~40%
- 长音频：按 10 分钟切块，块间重叠 5s，`carryInitialPrompt=false`，最后按时间戳拼接去重

**已知代价**：无 GPU 的机器跑 large-v3 会非常慢（10 分钟音频可能 15 分钟以上），必须做进度提示与后台队列。

### 4.4 转写任务队列

- 表 `asr_job(id, item_id, state, progress, model, error, created_at, updated_at)`
- 状态机：`queued → running → done / failed`；`failed` 可重试
- 应用启动时：`running` 状态的任务重置为 `queued`（断点续跑）
- 并发度 1（避免抢占 CPU 影响录音）；用户可在设置中改为 2
- 队列可暂停（录音时自动暂停转写，优先保证录音稳定）

### 4.5 速记与全局快捷键

**面板形态（PRD D52，已实现）**

| 端 | 尺寸 | 布局 |
|---|---|---|
| 桌面 | 窗口四周留 26px 的**近全屏面板**（`width:100%`、`height:100%`） | `Column`：说明头 `flex:0 0 auto` → 输入区 `flex:1` → 底部按钮 `flex:0 0 auto` |
| 手机 | **全屏页**，`top` 让出 46px 状态栏 | 同上三段式；标题下加 `line2` 分隔线 |

- 输入区一律用 `Expanded` / `flex:1` 撑满剩余高度，**不写死像素**，窗口缩放无需再调
- 字号：桌面 16.5px / 手机 15.5px，行高约 1.8
- 纯文字，不得出现任何录音控件（D46）

**快捷键（待补 P0）**

- 默认：录音 `Ctrl+Alt+R`，速记 `Ctrl+Alt+N`（可改）
- **现状**：只有应用内 `CallbackShortcuts`，且键位是 `Ctrl+Shift+N`；系统级热键未接
- 实现要点：引入 `hotkey_manager`（底层 `RegisterHotKey` + `WM_HOTKEY`）；注册失败必须提示并引导改键，不能静默失败
- 单实例锁：避免重复启动抢热键

**保存语义**

- `Esc` 保存并关闭（内容为空则不建条目）；`Ctrl+Enter` 保存并保持打开
- **现状**：只有「取消 / 保存」按钮，`Esc` 未绑定（`showDialog` 默认 Esc 返回 null = 丢弃）

**零等待**：先写内存队列即返回，后台异步落库

### 4.6 局域网传输（实际为「手机推送」模型，已实现）

**端口**：UDP 发现 `47821`，电脑端 HTTP `47825`。

**发现**：电脑端在 UDP 47821 应答广播（含设备名与 HTTP 端口）；手机端 `LanClient.discover()` 广播探测并收集响应。

**接口（电脑端 `LanServer`，注意实际路径没有 `/lan` 前缀）**

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/ping` | 存活探测，回传电脑名、版本、AI 与 Agent 状态，以及 `ffmpeg`（能否解码 m4a） |
| GET | `/agents` | 已发现并启用的 A2A Agent 列表 |
| GET | `/probe` | 逐端口诊断（排障用） |
| POST | `/transcribe` | 上传音频字节（头 `X-Filename`、`X-Duration-Ms`）→ 落盘 → 建条目 → 转写 → 返回分段 |
| POST | `/note` | 上传速记 `{title, body, createdAt}` → 建 text 条目 |
| POST | `/chat` | AI 对话 SSE 中继（手机 → 电脑侧 AI 服务） |
| POST | `/a2a` | A2A Agent SSE 中继（已实现，手机 UI 暂未使用） |

**推送流程**

1. 手机点「上传到电脑」或顶栏「一键同步」→ `LanClient` POST 到电脑
2. 电脑 `/transcribe`：落盘 `audio/up_<ts>.wav` → 算内容哈希 → `insertItem(source_device=phone, status=running)` → `Transcriber.transcribeFile` → `saveSegments`
3. 通过 `LanServer.onItemsChanged` 回调让电脑界面即时刷新（绑在 `AppState.bumpData`）
4. 手机收到分段写本地库，并置 `uploaded_at` → 徽标变「已同步」

**判重（PRD D56）**

- FNV-1a 64 位哈希（最多读前 200MB）→ `item.audio_hash`
- 命中已有哈希 → 新条目写入 `dup_of` → UI 打「重复」标；**不阻断**入库与转写

**与早期设计的偏差（务必知悉）**

- ❌ **配对码 + `trusted` + token 鉴权未实现**：当前 `Access-Control-Allow-Origin: *`，同 Wi-Fi 即可通信 → P0 待补
- ❌ 「电脑端弹出待接收列表 → 确认」**未实现**：改为静默入库（配对信任已承担该职责，多一步确认只会降低同步率）
- ❌ **电脑 → 手机**方向（拉取或推送条目）未实现
- ❌ `transfer_log` 表与断点续传未实现：当前整段 POST，失败即整条重传

### 4.7 A2A 客户端

#### 4.7.1 发现层（三层）

| 层 | 实现 | 触发 |
|---|---|---|
| L1 广播 | UDP 监听 `47822`，等 Agent 自报（若其支持）；同时监听我方应用的 mDNS 不做 | 常驻 |
| L2 端口探测 | 白名单端口 `[8000,8080,8081,8888,5000,3000,7860,9090,10000]` + 端口段 `8000-8100`，TCP connect 超时 200ms；命中后 `GET /.well-known/agent-card.json`（失败再试 `/.well-known/agent.json`） | 启动时 + 手动「重新扫描」 |
| L3 手动 | 用户填 Card URL | 用户操作 |

**Agent 认定条件**：HTTP 200 + JSON 含 `name` 且（`skills` 或 `capabilities`）→ 视为 Agent。
**深度扫描**：单独按钮，扫 `1024-65535`，并发 200，需用户确认（会触发安全软件提示）。

#### 4.7.2 协议适配层

```dart
abstract class A2aAdapter {
  ProtocolVersion get version;               // v1_0 | v0_3
  Future<AgentCard> fetchCard(Uri url);
  Stream<A2aEvent> send(SendRequest req);    // 流式
  Future<void> cancel(String taskId);
  Future<A2aTask> getTask(String taskId);
}
```

**版本判定**：Card 含 `supportedInterfaces` 且 `protocolVersion` 以 `1` 开头 → v1.0；否则含顶层 `url`/`preferredTransport` → v0.3。

| | v1.0 | v0.3 |
|---|---|---|
| 发送 | `SendMessage` / `SendStreamingMessage` | `message/send` / `message/stream` |
| 内容 | `parts:[{text:...}]`（OneOf 单一类型） | `parts:[{kind:"text",text:...}]` |
| 请求头 | `A2A-Version: 1.0`、`Content-Type: application/a2a+json` | `Content-Type: application/json` |
| 流事件 | `StreamResponse` OneOf：`task`/`message`/`statusUpdate`/`artifactUpdate` | `TaskStatusUpdateEvent` / `TaskArtifactUpdateEvent` |

**流式解析**：统一走 SSE（`text/event-stream`），逐 `data:` 帧解析；按事件类型分发：
- `artifactUpdate` → 累积文本（`append=true` 追加，`lastChunk=true` 收尾）
- `statusUpdate` → 更新状态（WORKING / INPUT_REQUIRED / FAILED…）
- 终态读到 `COMPLETED` 即关闭流

#### 4.7.3 对话层

- `conversation ↔ contextId`，首轮 `SendMessage` 拿到 `contextId` 后落库，后续轮次复用以保持多轮上下文
- 语料拼装模板（受上下文长度约束）：
```
[条目 1] 标题 | 2026-11-18 14:30 | 时长 32:15 | 来源：Windows
<转写全文>

[条目 2] ...
---
用户提问：<用户输入>
```
- 长度守卫：粗估 `总字符数 × 1.2` token，超过 `agent.card.limits`（无声明则默认 60k 字符）→ 提示"内容过长，建议减少条目或分批"
- 取消：UI「停止」→ `CancelTask`；同时断开 SSE
- 断线：记录 `taskId`，重开后调 `GetTask` 恢复结果（若 Agent 支持）

#### 4.7.4 手机端经电脑中继（D38）

**问题**：Agent（含 Ollama）默认只监听 `127.0.0.1`，手机在局域网无法直连。

**方案**：电脑端雁书做反向代理，不要求用户改 Agent 配置。

```
手机（Flutter）
  ├─ UDP 47821 发现电脑 → 配对码 → 获得 token
  ├─ GET  /lan/agents        → 电脑端已启用 Agent 列表
  └─ POST /lan/chat  (SSE)   → 电脑端
                                 └─ 转发 127.0.0.1:<agentPort>（A2aManager 同一适配层）
                                     └─ 流式回包透传
```

**电脑端实现要点**
- `shelf` 起局域网服务，绑定 `InternetAddress.anyIPv4`，端口 47823；**可在设置中一键关闭**
- 中间件校验 `Authorization: Bearer <token>`，token 由配对时生成并持久化到 `device` 表
- `/lan/chat` 复用 `A2aManager`：把手机传来的 `items + prompt` 拼成与本地一致的 A2A Message，再走 `A2aAdapter`
- 只做透传：不落盘对话内容（除非用户开启"同步会话"）
- 请求体限制（如 4MB）+ 超时（首字节 60s）+ 并发 1

**手机端要点**
- AI 面板顶部显示「经由 <电脑名>」；未连接显示引导与重试
- 断流时保留已接收内容并标记「连接中断」
- 手机端**不缓存** Agent 凭据，仅持有中继 token

### 4.8 会话管理（对应 PRD 5.7 / 6.13）

- 会话与消息为**本地硬删除**（不进回收站）：`DELETE FROM ai_message WHERE conversation_id=?` → `DELETE FROM ai_conversation WHERE id=?`，同一事务
- **删除会话不影响 `item` 表**：`ai_message.source_item_ids` 只是引用，删除消息后原始录音/笔记仍在
- 重命名：仅 `UPDATE ai_conversation SET title=?, updated_at=?`
- 自动命名：首条用户消息取前 14 字（按 Unicode 字符切，不按字节），空则用"新对话"
- 批量删除：单事务循环删除 N 条，N 上限 50，超限分批

### 4.9 批量操作实现要点（对应 PRD D39）

- 批量删除条目：**单事务**内做软删除 + 索引/回收站状态更新；任一条失败整体回滚
- 批量"发给 AI"：先做**条数与字数预检**（上限 20 条），超限提示分批，不静默截断
- 列表多选状态只存在内存（`Map<String,bool>`），切换标签/视图即清空；**不落库**
- 虚拟列表在多选态下需保持滚动位置稳定（重建行时复用 key）

### 4.10 首次启动（已取消引导，PRD D33 废止）

- **不做 4 步向导**：安装后直接进入主界面，所有配置取默认值
- 默认数据目录：`getApplicationSupportDirectory()/Gaggle`，可在设置页修改并迁移
- 默认模型档位：`small`；未安装模型时 `transcript_status` 保持 `queued`，列表显示「待转写」，点击进设置页「转写」分组下载或导入
- 模型下载为**独立任务**：可后台继续，关闭页面不中断

### 4.11 Android 平台适配（对应 PRD D35 / 6.11）· 已实现

**① 前台服务（`RecordingService.kt`）**

- 录音开始时 `startForegroundService`，`startForeground(NOTIFICATION_ID, notification)`
- 通知：标题「雁书正在录音」、`setUsesChronometer(true)`（系统计时器）、`setOngoing(true)`、`setOnlyAlertOnce(true)`、渠道 `IMPORTANCE_LOW`（常驻不打扰）
- 通知动作「停止」→ `PendingIntent` 拉起 `MainActivity(EXTRA_STOP=true)` → `onNewIntent` → `channel.invokeMethod("stopRecordingFromNotification")` → Dart 侧走正常 `stopRecord()`。
  **不在服务里直接停录音**：录音跑在 Flutter 引擎（同进程），必须回到 Dart 才能收尾落盘、建条目、派发转写
- 服务类型：Manifest 声明 `android:foregroundServiceType="microphone"`，Android 14+ 由系统据此校验 `RECORD_AUDIO` 权限

**② 原生通道（`MainActivity.kt`，channel `gaggle/native`）**

| 方法 | 作用 |
|---|---|
| `startRecordingService` | 起前台服务 |
| `stopRecordingService` | 停服务、撤通知 |
| `requestNotificationPermission` | Android 13+ 请求 `POST_NOTIFICATIONS` |
| `isIgnoringBatteryOptimizations` | 是否已在电池优化白名单 |
| `requestIgnoreBatteryOptimizations` | `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`，失败退应用详情页 |
| `openAppSettings` | 打开应用信息页（厂商自启动设置入口） |

Dart 封装：`lib/android_foreground.dart`，非 Android 平台全部空操作。

**③ UI（手机设置页「后台保活」卡片）**

- 电池优化状态 + 「去设置」按钮（授权后自动回读状态）
- 通知权限「授权」按钮
- 厂商限制说明（小米/华为/OPPO/vivo 需单独允许自启动与后台运行）

**④ 待验证**

- 真机息屏 30 分钟不中断（PRD 6.11 验收项）
- 各厂商 ROM 的白名单弹窗差异（部分 ROM 屏蔽 `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`，已做应用详情页兜底）

**⑤ 尚未实现**

- 来电/`AudioFocus` 自动暂停与恢复提示
- 存储仍为应用私有目录，未接 MediaStore 导出

### 4.12 数据库迁移与备份（对应 PRD D36 / 6.12）

- Drift 使用 `schemaVersion` + `MigrationStrategy`，只前进不回退
- 每次升级前：复制 `db/gaggle.db` → `db/backup/gaggle-<oldVer>-<ts>.db`，保留最近 3 份
- 迁移失败：回滚到备份并把错误写入日志与界面提示，禁止以空库启动
- 未知字段兼容：新增列一律给默认值；读取时忽略多余 JSON 字段
- 模型换代：`item.transcript_model` 记录所用模型；"用新模型重转"覆盖 `transcript_segment` 前先快照到 `transcript_history`

---

### 4.13 说话人分离（声纹 / D43）

**引擎选型**

| 方案 | 跨端 | 体积 | 结论 |
|---|---|---|---|
| **sherpa-onnx 离线 diarization** | Windows + Android | 分割 1.5MB + 声纹 28~40MB | **选它**：同栈已有 ONNX Runtime，内置聚类，中文声纹模型成熟（CAM++ / 3D-Speaker） |
| pyannote.audio | 仅桌面 | 数百 MB（PyTorch） | 效果基准，但打包与启动成本不可接受 |
| 自研（VAD + embedding + 自己写聚类） | 可跨端 | 小 | 灵活但阈值调优耗时，作为退化方案 |

组合：`pyannote-segmentation-3-0.onnx`（语音段切分）+ `3dspeaker_campplus_sv_zh-cn_16k.onnx`（声纹 embedding）+ 内置余弦聚类。

**两条流水线，最后按时间对齐**

```
音频 ─┬─ whisper.cpp ─────────────► segments[(start,end,text)]
      └─ sherpa-onnx diarization ─► turns[(start,end,spk)]
                                     ↓ 按时间重叠率对齐
                       segments[(start,end,text,spk)]
                                     ↓ 合并相邻同 spk（间隔 <0.8s）
                       写入 transcript_segment.speaker_id
```

- 两条流水线**并行**跑（各占一个 Isolate），总耗时 = max(转写, 声纹)，不是相加
- 对齐：取**重叠时长最大**的 turn；重叠 < 50% 记为 `null`，UI 显示「未知」
- 合并只影响**展示**，数据库仍保留细粒度分段，保证跳转精度

**聚类参数**
- 距离用余弦；阈值默认 **0.75**（调大更易合并为同一人），设置中提供「严格 / 标准 / 宽松」
- 人数上限 8；超出时保留 talk_ms 最大的 8 类，其余归入「其他」
- 每个 speaker 统计 `talk_ms`，用于 UI 显示发言占比

**人工校正优先**
- 用户改名/合并/拆出后置 `speaker.corrected_by_user = 1`
- 重转写时**不覆盖**已校正的说话人标签，只更新文本
- 关闭「说话人区分」开关：不跑 diarization，`speaker_id` 置空，UI 隐藏标签

**性能目标（i5-13500H，12 核）**

| 项 | 目标 |
|---|---|
| 10 分钟音频 diarization 耗时 | 60~120s（并行于转写，不额外拉长总时长） |
| 内存峰值增量 | < 200MB |
| 声纹模型体积 | CAM++ 16k ≈ 28MB |

**Android 注意**
- 只内置小体量音纹模型；分割模型共用
- 前台服务期间限制并发：diarization 与转写排队，不同时满速，避免发热降频

**已知失败场景（写进帮助文档）**
- 多人抢话/重叠 → 归属错乱
- 段落 < 1 秒 → embedding 不稳，易误判
- 音色相近（同性同年龄）→ 聚类合并为一人
- 远端电话音（窄带 8kHz）→ 准确率明显下降

---

### 4.14 音频文件导入（D45 / PRD 6.15）

**解码依赖二选一**

| 方案 | 格式覆盖 | 体积 | 结论 |
|---|---|---|---|
| **FFmpeg 预编译（LGPL 构建）** | 全（含 flac/ogg/opus/amr + 视频抽轨） | +20~30MB | **选它**：格式覆盖是这类工具的生命线 |
| 平台解码（MediaFoundation / MediaCodec） | 差（flac/ogg/opus 常失败） | 0 | 退化方案，会把"导入失败"变成常见投诉 |

FFmpeg 需按 **LGPL** 构建（不含 GPL 组件如 x264），否则与项目 MIT 协议冲突；只启用 demuxer / decoder / resampler。

**处理链路**
```
选文件/拖入 → ffprobe 读元数据（时长/编码/声道/码率）→ 校验扩展名 + 大小
           → ffmpeg 解码为 16kHz 单声道 s16le PCM（tmp/import/<uuid>.pcm，60s 分块写）
           → 压缩源同时转存 AAC 存档（audio/yyyy/MM/<uuid>.m4a）
           → 写 item(source_device=win, origin=import) + audio_file(content_hash)
           → 入转写队列 → 跑声纹分离
```

**关键实现点**
- **流式解码**：按块写盘，绝不整文件进内存；1GB 文件峰值内存控制在 300MB 内
- **判重**：对源文件算 SHA-256 存 `audio_file.content_hash`，重复时提示并允许强制导入
- **只取第一条音轨**：视频文件用 `-vn -map 0:a:0`
- **进度拆分**：解码 0~40%，转写 40~100%，两段都上报
- **失败分级**：`不支持的格式` / `解码失败（文件损坏）` / `磁盘空间不足`，三种文案分别处理
- **超长文件**：>2 小时提示"预计转写 X 分钟"，仍允许导入
- **取消**：导入过程中可取消，删掉半成品临时文件

**性能目标**

| 项 | 目标 |
|---|---|
| 30 分钟 m4a 解码 | < 10s |
| 1GB 文件峰值内存 | < 300MB |
| 追加安装包体积 | < 30MB |

---

### 4.15 手机端本地转写（SenseVoice-Small）

**问题**：手机端原先只能录音后把音频传回电脑转写，脱离电脑就等于不能转写。

**方案**：Android 用 **sherpa-onnx（Dart FFI，ffiPlugin）** 跑 **SenseVoice-Small int8**，全程离线。

```
录音(wav 44.1k) → 线性重采样到 16k → 20s 切块 → OfflineRecognizer.decode
                → 按中文标点分句 + 按字数分配时间轴 → transcript_segment
```

**实现要点**
- 依赖 `sherpa_onnx 2.0.2`（含 android_arm64/armeabi/x86/x86_64 与 windows 原生库，`ffiPlugin: true` 自动打进产物）
- 推理在**独立 isolate** 里跑，模型只加载一次，不阻塞 UI；isolate 内必须先 `initBindings()`
- 模型放数据目录 `models/sensevoice/`（`model.int8.onnx` 约 228MB + `tokens.txt`），支持**一键下载（hf-mirror 优先，HF 兜底）** 与**本地文件导入**
- 录音格式是 44.1kHz wav，进模型前下采样到 16k，并先做滑动平均抑制混叠
- 路由：设置 → 转写 →「手机转写 / 电脑转写」；手机转写但模型缺失时**自动回退电脑**，录音不丢
- 单段 20s：SenseVoice 训练时长为 30s 以内，长录音按块识别再拼接

**代价**

| 项 | 数值 |
|---|---|
| 每个 ABI 追加体积 | 约 26MB（onnxruntime 21MB + c-api 5MB） |
| 模型体积（不打包，用户数据目录） | 约 228MB |
| 45s 音频识别耗时（桌面 CPU） | 实测见变更记录 |

---

### 4.16 手机端同步状态与一键同步（PRD D50 / D51 / D56）

**状态模型**

- `Item.uploaded => uploaded_at != null` —— 语义是"**曾成功上传过一次**"，不比对内容版本
- `Item.isDuplicate => dup_of != null`
- 徽标组件：`UploadedBadge` / `UnsyncedBadge` / `DuplicateBadge`（`widgets.dart`）

**展示规则**

| 条件 | 显示 |
|---|---|
| `source_device != 'pc'` | 显示来源端徽标（手机 / 手表） |
| `uploaded == true` | 「已同步」（绿） |
| `source_device == 'phone' && !uploaded` | 「待同步」（金） |
| `dup_of != null` | 「重复」（灰） |
| `source_device == 'pc'` | 不显示任何同步态（本来就在电脑上） |

**一键同步**

- 入口：手机时间流页顶栏胶囊按钮，角标数 = `pendingSyncIds().length`
- `pendingSyncIds()` = `source_device == 'phone' && uploaded_at == null`
- 点击后逐条上传，每条经历「同步中 → 已同步」，结束 toast 汇总
- 批量操作条另提供「重新上传」（`includeUploaded: true`），可对**已同步**条目强制重传（电脑数据丢失时使用）

**已知缺口**

- 编辑标题/正文后不会把状态打回「待同步」——没有 `content_version` 就做不了真正的双向同步，留 P1
- 桌面端**导入**的重复文件不会被标「重复」：导入路径未计算 `audio_hash` / `dup_of`

### 4.17 AI 多 Provider（PRD D55，已实现）

**抽象方式**：两条分支，不是严格意义上的 Provider 接口

- `provider == 'a2a'` → 走 A2A 客户端（JSON-RPC + SSE）
- 其余全部 → **OpenAI 兼容** `POST {base_url}/chat/completions`，`stream: true`，逐帧解析 SSE 的 `delta.content`

**七种预设**

| id | 名称 | base_url | 备注 |
|---|---|---|---|
| `ollama` | Ollama | `http://127.0.0.1:11434/v1` | 本地；自动拉起 `serve`、自动 `pull`、`warmup` 预热 |
| `deepseek` | DeepSeek | `https://api.deepseek.com` | 需 key |
| `qwen` | 千问 | 阿里云兼容端点 | 需 key |
| `kimi` | Kimi | Moonshot 兼容端点 | 需 key |
| `openai` | OpenAI | `https://api.openai.com/v1` | 需 key |
| `custom` | 自定义 | 用户填写 | 任何 OpenAI 兼容服务，含火山方舟（豆包）、腾讯混元（元宝）、中转站 |
| `a2a` | A2A Agent | `/.well-known/agent-card.json` | JSON-RPC，不是 OpenAI 协议 |

**配置存放**：全部在 `setting` 表 —— `ai_provider` / `ai_base_url` / `ai_model` / `ai_api_key` / `ai_auto_name` / `ai_auto_tag` / `a2a_selected` / `a2a_manual`。
不写 `config.dart`（它只负责数据目录 `location.json` 与开机自启注册表）。

**Ollama 生命周期托管**：`ensureRunning()` → `pull()`（解析 `\r` 进度）→ `warmup()`，由 `prepare()` 串起来。

**AI 派生能力**

- **自动标题**：转写成功后调用；仅当标题以「录音」开头才替换为 `AI标题 · 年月日时分秒`（截 16 字），受 `ai_auto_name` 控制
- **自动标签**：与标题并行，写入 `item_tag(source='ai')`；重跑只覆盖 ai 标签，不动手动标签
- **会话标题 / 推荐追问**：见 4.8

**手机端**：不走 Provider，直接 `POST /chat` 中继到电脑侧 AI 服务（SSE 透传），因此手机不持有任何 API Key。

---

## 5. 数据模型（DDL 草案）

> **实现状态**：下列 DDL 中 **只有 `item`、`transcript_segment`、`ai_conversation`、`ai_message` 已建**，另有 `ai_conv_ref`、`ai_message_ref`、`item_tag`、`setting`、`search_idx` 五张代码中的表未写在本草案里（见本节末尾）。`audio_file` / `text_note` / `speaker` / `asr_job` / `device` / `transfer_log` / `agent_config` / `a2a_task` **均未建**，请勿照此开发。

```sql
-- ✅ 实际已建（与 app/lib/db.dart 一致）
CREATE TABLE item (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,                    -- audio | text
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,           -- epoch ms
  updated_at INTEGER NOT NULL,
  source_device TEXT NOT NULL,           -- pc | phone | watch
  duration_ms INTEGER,
  char_count INTEGER,
  transcript_status TEXT NOT NULL DEFAULT 'none',   -- none|queued|running|done|failed
  audio_path TEXT,                       -- 音频路径（已合并原 audio_file）
  body TEXT,                             -- 速记正文（已合并原 text_note）
  audio_hash TEXT,                       -- FNV-1a 64 位，判重用（D56）
  dup_of TEXT,                           -- 非空 = 与哪个条目重复
  uploaded_at INTEGER,                   -- 非空 = 曾成功上传到电脑（D51）
  deleted_at INTEGER                     -- 非空 = 在回收站（软删除）
);
CREATE INDEX idx_item_deleted ON item(deleted_at);
CREATE INDEX idx_item_created ON item(deleted_at, created_at DESC);

-- 重转写历史快照（D36：换模型后可回退）
CREATE TABLE transcript_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id TEXT NOT NULL,
  model TEXT NOT NULL,
  content TEXT NOT NULL,                  -- 整份转写文本（JSON 分段）
  created_at INTEGER NOT NULL
);

CREATE TABLE audio_file (
  item_id TEXT PRIMARY KEY REFERENCES item(id),
  path TEXT NOT NULL, codec TEXT, sample_rate INT, channels INT,
  bitrate INT, size_bytes INT,
  content_hash TEXT,                      -- SHA-256，导入判重用（D45）
  origin TEXT NOT NULL DEFAULT 'record'   -- record | import
);
CREATE INDEX idx_audio_hash ON audio_file(content_hash);

CREATE TABLE text_note (
  item_id TEXT PRIMARY KEY REFERENCES item(id),
  body TEXT NOT NULL
);

CREATE TABLE transcript_segment (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id TEXT NOT NULL,
  seq INT NOT NULL, start_ms INT NOT NULL, end_ms INT NOT NULL,
  text TEXT NOT NULL,
  speaker_id TEXT,                        -- 可空：未识别或重叠 <50% 时为 NULL
  confidence REAL                         -- 说话人归属置信度（0~1），便于提示"可能不准"
);
CREATE INDEX idx_seg_item ON transcript_segment(item_id, start_ms);
CREATE INDEX idx_seg_speaker ON transcript_segment(item_id, speaker_id);

-- 说话人（D43）
CREATE TABLE speaker (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
  label TEXT NOT NULL,                    -- 默认「说话人1」，可改名
  color_idx INTEGER NOT NULL DEFAULT 0,
  order_idx INTEGER NOT NULL DEFAULT 0,   -- 按首次出现排序
  talk_ms INTEGER NOT NULL DEFAULT 0,     -- 发言总时长，用于占比展示
  corrected_by_user INTEGER NOT NULL DEFAULT 0  -- 1 = 人工校正过，重转不覆盖
);
CREATE INDEX idx_speaker_item ON speaker(item_id, order_idx);

-- 统一检索索引（trigram 支持中文子串）
CREATE VIRTUAL TABLE search_idx USING fts5(
  content, item_id UNINDEXED, seg_id UNINDEXED, start_ms UNINDEXED,
  tokenize='trigram'
);

CREATE TABLE asr_job (
  id TEXT PRIMARY KEY, item_id TEXT NOT NULL,
  state TEXT NOT NULL, progress REAL DEFAULT 0,
  model TEXT, error TEXT,
  created_at INTEGER, updated_at INTEGER
);

CREATE TABLE agent_config (
  id TEXT PRIMARY KEY, name TEXT, card_url TEXT,
  protocol_version TEXT, protocol_binding TEXT,
  auth_type TEXT, auth_secret TEXT,
  default_skill_id TEXT, enabled INT DEFAULT 1,
  discovered_by TEXT,                    -- broadcast | probe | manual
  last_seen_at INTEGER
);

CREATE TABLE ai_conversation (
  id TEXT PRIMARY KEY, agent_id TEXT, a2a_context_id TEXT,
  title TEXT, created_at INTEGER, updated_at INTEGER
);

CREATE TABLE ai_message (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL,
  role TEXT NOT NULL, content TEXT,
  source_item_ids TEXT,                  -- JSON array
  a2a_task_id TEXT, state TEXT, created_at INTEGER
);

CREATE TABLE a2a_task (
  id TEXT PRIMARY KEY, a2a_task_id TEXT, conversation_id TEXT,
  state TEXT, error TEXT, started_at INTEGER, finished_at INTEGER
);

CREATE TABLE device (
  id TEXT PRIMARY KEY, name TEXT, endpoint TEXT,
  trusted INT DEFAULT 0, last_seen_at INTEGER
);

CREATE TABLE transfer_log (
  id TEXT PRIMARY KEY, item_id TEXT, from_device TEXT, to_device TEXT,
  state TEXT, bytes_total INT, bytes_done INT, ts INTEGER
);
-- ⚠ transfer_log 与前述 audio_file / text_note / speaker / asr_job /
--    device / agent_config / a2a_task 均未实现

-- ✅ 代码中实际存在、早期草案漏写的表
CREATE TABLE item_tag (
  item_id TEXT NOT NULL,
  tag     TEXT NOT NULL,
  source  TEXT NOT NULL DEFAULT 'manual',   -- manual | ai
  PRIMARY KEY(item_id, tag)
);
CREATE INDEX idx_tag ON item_tag(tag);

CREATE TABLE ai_conv_ref (                  -- 会话 ↔ 条目
  conversation_id TEXT NOT NULL,
  item_id TEXT NOT NULL
);

CREATE TABLE ai_message_ref (               -- 单条回复 ↔ 条目
  message_id TEXT NOT NULL,
  item_id TEXT NOT NULL
);

CREATE TABLE setting (
  key   TEXT PRIMARY KEY,
  value TEXT
);
-- setting 承载全部软配置：ai_provider / ai_base_url / ai_model / ai_api_key /
-- ai_auto_name / ai_auto_tag / a2a_selected / a2a_manual /
-- model_tier / close_action / transcribe_on

-- FTS5 统一索引（trigram 支持中文子串）
-- 注意：表已建且 rebuildIndex 会写入，但检索查询当前仍用 LIKE，未走 MATCH
CREATE VIRTUAL TABLE search_idx USING fts5(
  content, item_id UNINDEXED, tokenize='trigram'
);
```

---

## 6. 目录结构

```
gaggle/
  lib/
    main.dart
    app/                 # 路由、主题、Riverpod Provider 根
    feature/
      timeline/          # 时间流列表
      detail/            # 详情 + 播放器 + 转写
      capture/           # 录音 + 悬浮条
      quicknote/         # 速记窗
      chat/              # AI 对话面板
      settings/          # 设置
      transfer/          # 局域网传输 UI
    core/
      audio/             # AudioRecorder 封装、分片合并、恢复
      asr/               # WhisperEngine FFI、模型管理、档位探测
      db/                # Drift 表定义与 DAO
      search/            # FTS5 查询构建、短词回退
      a2a/               # 发现层、适配层(v1.0/v0.3)、对话编排
      lan/               # UDP 发现、HTTP 服务与客户端
      storage/           # 路径、文件、清理
      platform/          # 快捷键、托盘、窗口、单实例
    ui/                  # 通用组件（波形、卡片、空态）
  native/whisper/        # whisper.cpp 源码/预编译库
  models/                # 开发期本地模型（不进仓库）
  test/
  docs/PRD.md, TECH_DESIGN.md
```

---

## 7. 关键接口

```dart
abstract class AudioRecorder {
  Future<void> start({required String outputPath, RecordConfig? cfg});
  Stream<double> amplitude();          // 0..1
  Future<void> pause();
  Future<void> resume();
  Future<RecordResult> stop();         // durationMs, sizeBytes, path
}

abstract class AsrEngine {
  Future<void> load(ModelSpec spec, {int threads});
  Stream<AsrEvent> transcribe(String audioPath, {AsrOptions? opts});
  Future<void> dispose();
}
// AsrEvent: Segment(startMs,endMs,text) | Progress(0..1) | Done | Failed(msg)

abstract class SearchService {
  Future<List<SearchHit>> search(String query, {int limit = 50});
}
// SearchHit: itemId, segId?, startMs?, snippet, title

abstract class LanDiscovery {
  Stream<Device> devices();
  Future<void> start(); Future<void> stop();
}
```

---

## 8. 性能与容量预算

| 指标 | 目标 |
|---|---|
| 快捷键 → 开始采集 | < 1s |
| 速记窗可输入 | < 300ms |
| 时间流滚动 | 1 万条 60fps（虚拟列表 + 分页 200） |
| 搜到结果 | 10 万条内 < 300ms |
| 转写（large-v3 q5，GPU） | 10min 音频 ≈ 1~2min |
| 转写（large-v3 q5，16 核 CPU） | 10min 音频 ≈ 10~20min |
| 转写（medium q5，16 核 CPU） | 10min 音频 ≈ 3~5min |
| 存储（AAC 128k） | ≈ 57MB / 小时 |
| 冷启动到可操作 | < 2s |
| 编辑保存 + 索引重建 | < 200ms |
| 批量删除 100 条 | < 1s（单事务） |
| 回收站恢复单条 | < 100ms |
| 导入解码（30min m4a） | < 10s |
| 导入 1GB 文件峰值内存 | < 300MB |
| 声纹分离（10min 音频） | 60~120s，且与转写并行 |
| 声纹模型体积 | ≈ 30MB（分割 + CAM++） |
| 说话人改名同步 | < 100ms（只更新 speaker + 重渲染） |

---

## 9. 技术验证清单（M0 必做，按序）

| # | 验证项 | 通过标准 | 失败备选 |
|---|---|---|---|
| S1 | Flutter Windows 上 `record` 直出 AAC/m4a | 录 5 分钟，文件可播、`ffprobe` 显示 aac | 改录 WAV(pcm16) + 停后转码 m4a |
| S2 | whisper.cpp FFI 在 Windows 跑通（含 q5 量化） | 10min 中文音频出带时间戳分段 | 降级 `sherpa-onnx` 或子进程调用 `whisper-cli` |
| S3 | 全局快捷键 + 托盘 + 置顶无边框窗 | 三者在 Win11 正常，无焦点抢占 | Electron 重做壳（仅桌面） |
| S4 | SQLite FTS5 trigram 中文检索 | "预算"、"预算表" 均能命中，10 万条 <300ms | 引入 jieba 分词写倒排表 |
| S5 | mock A2A Server 流式对接 | 桌面端能边收边显示，可取消 | 降级为非流式 `SendMessage` |
| S6 | Android 端 whisper small 真机 | 10min 音频 10min 内出结果，不 OOM | 降到 base/tiny，或强制回传电脑转写 |

> S1~S5 是 M1 的前置门槛，**任何一项失败都先解决再往下写**，避免返工。

---

## 10. M1 开发任务拆解

| # | 任务 | 产出 | 验收 |
|---|---|---|---|
| 1 | 工程骨架 | Flutter 工程、Riverpod、路由、主题、日志 | 双端可跑空壳 |
| 2 | 数据层 | Drift 表 + 迁移 + DAO + FTS5 建表 | 单测通过 |
| 3 | 录音采集 | 分片写入、暂停续录、电平流 | 录 60min 不丢、强杀可恢复 |
| 4 | 时间流列表 | 虚拟滚动、播放、重命名、删除 | 1 万条流畅 |
| 5 | 播放器 | 进度、倍速、波形包络 | 点击跳转准确 |
| 6 | 速记 | 全局快捷键 + 悬浮窗 + 秒存 | 唤起 <300ms |
| 7 | 托盘与悬浮条 | 托盘菜单、录制态悬浮条 | 关闭窗口不退出 |
| 8 | ASR 集成 | 档位探测、模型下载、转写 Isolate | 10min 音频出分段 |
| 9 | 任务队列 | 持久化、断点续跑、失败重试 | 中断后重启自动继续 |
| 10 | 检索跳转 | FTS5 查询、短词回退、高亮定位 | 搜到即听到 |
| 11 | 内容编辑 | 段落级/正文级就地编辑 + **条目级索引重建** | 改错字后原词搜不到、新词能搜到 |
| 12a | 音频导入 | FFmpeg 接入、ffprobe 元数据、流式解码、判重、进度 | 30min m4a 10s 内入列表 |
| 12b | 来源端标识 | `source_device` 贯通 UI（列表/详情/传输） | 手机上传条目一眼可辨 |
| 12 | 回收站 | 软删除、恢复、彻底删除、30 天自动清理 | 误删可恢复，文件一并清理 |
| 13 | 多选与批量 | 选态管理、批量删除（单事务）、批量发给 AI、批量条 UI | 100 条批量删除 < 1s 且全部一致 |
| 14 | 设置页 | 存储目录、档位、快捷键、开机自启、打开目录、日志目录 | 改目录可迁移 |
| 15 | ~~停录转码~~ | ✅ 已完成（v2.3）：AAC 直出优先，失败退回 WAV 再转码 | 1 小时录音约 57MB，可正常回放与转写 |
| 16 | 数据迁移 | schemaVersion + 迁移脚本 + 升级前自动备份 | v1→v2 升级后数据完整可读 |
| 17 | 可靠性收尾 | 崩溃恢复、单实例、磁盘空间校验 | 异常场景不丢数据 |

**M1 出口**：在 Windows 上可以每天真实使用——录音、速记、编辑、转写、搜索定位、回收站全部可用。Android 端在 M5 复制同一套逻辑层，并补 4.11 的平台适配。

### 10.1 M2 追加任务（说话人区分，D43）

| # | 任务 | 产出 | 验收 |
|---|---|---|---|
| 1 | 声纹模型接入 | sherpa-onnx 分割 + CAM++ 模型加载与释放 | 模型加载 < 2s |
| 2 | diarization 流水线 | 独立 Isolate，输出 turns | 10min 音频 60~120s |
| 3 | 与转写对齐 | 重叠率对齐算法 + 相邻合并 | 2 人对话归属准确率 ≥85% |
| 4 | 说话人 UI | 标签着色、说话人条、发言占比 | 3 人样本可视觉区分 |
| 5 | 人工校正 | 改名 / 合并 / 拆出 + `corrected_by_user` | 重转不覆盖人工修正 |
| 6 | 开关与降级 | 设置开关、关闭后隐藏标签 | 关闭时不加载模型 |

> 声纹与转写**并行跑**是性能关键：串行会让 10 分钟音频的总等待从 5 分钟涨到 7 分钟以上。

---

## 11. 打包与分发

| 端 | 方式 | 说明 |
|---|---|---|
| Windows | Inno Setup 安装包 + 便携 zip | 模型不内置，在设置页「转写」分组下载；安装目录 `%LOCALAPPDATA%\Gaggle` |
| Windows 运行时依赖 | `app/windows/engine/` 由 CMake `install(DIRECTORY)` 装到 `<exe>/engine/`，`installer.iss` 递归打包整个 Release 目录 | 内容：`whisper-cli.exe` + `ggml*.dll` + `ffmpeg.exe` + `av*.dll`/`swresample.dll` + `diarizer/`。用 `tools/fetch_engine.ps1` 一次拉齐；**ffmpeg 必须是 LGPL 共享构建**（GPL 构建与本项目 MIT 冲突） |
| Android | arm64 APK | 应用包名 `com.gaggle.app`；首次启动请求麦克风/通知权限；模型按档位下载 |
| 签名 | 自签名（自用）/ 正式证书（分发） | 开源首发可先自签名，README 说明安装方式 |
| 开源协议 | **MIT**（建议） | 仓库根放 `LICENSE`；如需防闭源商用改 AGPL-3.0 |
| 开源配套 | `LICENSE` / `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` / `SECURITY.md` | README 首屏按 `OPEN_SOURCE_GTM.md` 第 5 节结构 |

---

## 12. 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| Flutter 桌面插件碎片化（托盘/快捷键/窗口） | 交互细节做不出来 | S3 先验证；失败则仅桌面端换 Electron |
| AAC 直录在部分声卡异常 | 录音失败 | S1 验证；备选 WAV + 转码 |
| whisper large 在 CPU 上极慢 | 用户等待过久 | 自动降档 + 进度提示 + 手动切换 |
| 模型下载体积大 | 首启体验差 | 断点续传 + 显示预计时间 + 允许先只下 small |
| 中文检索召回不足 | 核心卖点受损 | trigram + 短词 LIKE 回退；预留 jieba 方案 |
| A2A 协议版本分裂 | 对接失败 | 适配层双实现，Card 自动判版本 |
| **声纹分离准确率不足（重叠/短句/音色相近）** | 会议记录不可信 | 预期表前置；存 `confidence` 并对低置信度加提示；支持人工校正 |
| **声纹与转写串行导致总耗时翻倍** | 用户等待过久 | 两条流水线并行，总耗时取 max；关闭开关可省 |
| 声纹模型在 Android 上过重 | 包体与发热 | 只内置 CAM++ 小模型；排队执行不同时满速 |
| 人工校正被重转覆盖 | 用户白改一遍 | `corrected_by_user=1` 时跳过说话人重算 |
| 你的 A2A Server 未就绪 | 「问」无法联调 | 先做 mock Server，按 v1.0 与 0.3 各测一遍 |
| 双端同代码但平台差异（权限/后台/省电） | Android 上录音被系统杀 | 前台服务 + 常驻通知；M5 专项处理 |

---

## 13. 决策确认（已完成）

| # | 事项 | 结论 |
|---|---|---|
| 1 | 技术栈 | **已确认：Flutter 单代码库**（Windows + Android 一套代码） |
| 2 | A2A Server | **先用 mock**（v1.0 与 0.3 各测一遍），真实 Agent 后续接入 |
| 3 | 开工方式 | **已确认：先做 Spike**，S1~S3 通过后进入 M1 |

---

## 14. 变更记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-11-19 | 首版技术方案：Flutter 单代码库 + whisper.cpp FFI + Drift/FTS5 trigram + UDP 局域网 + 自研 A2A 双向版本适配层；含 DDL、目录结构、接口、性能预算、6 项 Spike、M1 任务拆解 |
| v1.1 | 2026-11-19 | 新增 **4.7.4 手机端经电脑中继**（D38）：电脑端以 `shelf` 暴露 `/lan/agents` 与 `/lan/chat`(SSE)，token 鉴权后复用 `A2aManager` 转发到 `127.0.0.1` 的 Agent；含端口、限流、超时与手机端 UI 约定 |
| v1.2 | 2026-11-19 | **与 PRD v2.1 对齐**。新增：① 第 0 节「文档定位」说明三份文档分工与维护规则 ② 4.2 补充**索引重建策略**（条目级/段落级）与**软删除查询约定** ③ 4.8 会话管理（本地硬删除、删除不影响条目、自动命名规则）④ 4.9 批量操作要点（单事务、20 条预检、选态不落库）⑤ 4.10 首次引导（onboarded 标记、下载可跳过）⑥ 4.11 Android 前台服务与保活 ⑦ 4.12 迁移与备份（schemaVersion、备份保留 3 份、重转快照）。DDL 增 `item.updated_at`、两个索引、`transcript_history` 表。M1 任务从 12 项扩到 17 项；性能预算增 3 项指标 |
| v1.3 | 2026-11-19 | **品牌更名与开源配套**（D40/D41/D42）：英文名 Anser → Gaggle；数据库名 `gaggle.db`、日志前缀 `gaggle-`、目录结构补 `db/backup/`；安装目录改为 `%LOCALAPPDATA%\Gaggle`、Android 包名 `com.gaggle.app`；打包章节新增开源协议（建议 MIT）与治理文件清单。平台范围维持 Windows 优先 |
| v1.4 | 2026-11-19 | **说话人区分（D43）落地**。新增 4.13：引擎选型（sherpa-onnx 分割 + CAM++ 声纹 + 余弦聚类）、两条流水线并行与时间重叠对齐、聚类阈值 0.75 与人数上限 8、人工校正优先级、Android 限制、已知失败场景。DDL 增 `transcript_segment.speaker_id / confidence`、`speaker` 表与两个索引。性能预算增 3 项；新增 10.1 节 M2 任务 6 项；风险增 4 项 |
| v1.5 | 2026-11-19 | **音频导入（D45）落地**。新增 4.14：FFmpeg（LGPL 构建）vs 平台解码的取舍、ffprobe 元数据、流式解码 60s 分块、只取首音轨、SHA-256 判重、进度拆分（解码 0~40%）、失败分级、性能目标。DDL 中 `audio_file` 增 `content_hash` / `origin` 与哈希索引。依赖表增 FFmpeg 与 crypto；M1 任务增「音频导入」「来源端标识」两项；性能预算增 2 项。同步 D46（速记纯文字，不涉及技术变更）与 D47（来源端贯通 UI） |
| v1.6 | 2026-11-19 | **M1/M2 关键链路落地，含两处实现调整**。① **ASR 集成方式由 FFI 改为子进程**：调 `whisper-cli.exe` 并用 `-oj` 解析 JSON。原因：whisper.cpp 的 C 结构体字段随版本变化，Dart FFI 内存布局易错位导致崩溃；子进程只解析 JSON，稳定性高一个量级，代价是每次多约 1 秒进程启动。② **中文必须加 `--prompt "以下是普通话的句子，请用简体中文输出。"`**：否则输出繁体（实测 "我們開一個產品會議"）。③ 实测档位（i5-13500H 无独显）：base 44s 音频 4.7s 但错字严重（"入阴功能"）；**small 23.8s、准确率可用**，定为无独显默认档。④ A2A 客户端已实现：`/.well-known/agent-card.json` 发现（兼容 0.3 的 `agent.json`）、JSON-RPC `SendMessage`/`message/send` 双实现、回复文本递归提取；配 `tools/mock_a2a_server.py` 联调用。⑤ 引擎（约 2MB）随安装包分发，模型（181MB+）放用户数据目录由下载获得 |
| v1.7 | 2026-11-20 | **说话人分离落地 + Android 端开工**。① 声纹实现方式：`sherpa-onnx`(2.0.2) + Python，用 **PyInstaller 打包成自包含 `diarizer.exe`（78MB）**，Dart 以子进程调用 —— 与 whisper 同一架构，用户机器无需装 Python。模型：`pyannote-segmentation-3-0`(5.7MB) + `3dspeaker_campplus_sv_zh-cn`(27MB)，放数据目录 `models/diarization`。② **阈值语义修正（重要）**：`FastClusteringConfig.threshold` 是"相似度高于该值判为同一人"，值越小越易分出更多人。实测两音色音频：0.75/0.9 → 合并为 1 人（错）；**0.3 → 正确分 2 人**。默认改 **0.5**。③ 对齐算法：声纹时间片按**最大重叠时长**映射到 whisper 分段，输出"说话人 N"。④ 模型档位优先级改为 **small 优先**（实测 medium 32.2s/44s 音频 vs small 23.8s，准确率接近，无独显场景速度更重要）。⑤ **Android 端**：JDK 17 + cmdline-tools(15859902) + platform-35 + build-tools 35.0.0；Gradle 走腾讯镜像 + 阿里云 Maven；`ShellPage` 按 **760px 断点**自动切换桌面三栏 / 手机单列（`mobile.dart`：底部导航、卡片列表、全屏详情、单会话聊天）；Manifest 补 RECORD_AUDIO / INTERNET / READ_MEDIA_AUDIO / FOREGROUND_SERVICE_MICROPHONE |
| v1.8 | 2026-11-20 | **M2 / M4 功能补齐，Android 首次产出 APK**。① **M2 补 3 项**：`models.dart` 新增模型档位管理（已安装检测、`setting` 表持久化选择、`small>medium>base>large` 推荐序、读 `Win32_VideoController` 判断独显）；设置页做成可选列表（大小/速度描述/推荐标记/单选）；详情页新增「重新转写」（`Db.clearSegments` + 重入队）。② **M4 补 3 项**：`A2aClient.sendStream` 实现 **SSE 流式**（逐行解析 `data:`，兼容"全量快照"与"增量片段"两种 Agent 实现，用 `startsWith` 判 diff）；对话页流式渲染 + `▌` 光标 + 生成中按钮转为**停止**（取消订阅即断开连接，已收内容落库）；设置页支持**手动填 Agent 地址**（`probeUrl`，保存后立即连通性测试）。③ **会话持久化**：新增 `ai_conversation` / `ai_message` / `ai_conv_ref` / `setting` 四表，关掉程序后会话与消息完整保留。④ **APK 构建四个坑及解法**：Gradle 直连 Cloudflare 卡死 → 改 Flutter SDK 的 `flutter_tools/gradle/settings.gradle.kts` 加阿里云镜像（该文件设了 `FAIL_ON_PROJECT_REPOS`，只能在此处改）；缺 cmake/platform-36 → `sdkmanager` 补装；Kotlin 增量缓存损坏（强杀 Gradle 导致）→ 清 `build/*/kotlin` + `kotlin.incremental=false`；Android Lint 自身崩溃 → `lint { checkReleaseBuilds = false }`。产物 `Gaggle-0.1.0-Setup.exe`(31.8MB) 与 `Gaggle-0.1.0-android.apk`(21.6MB) |
| v2.0 | 2026-11-20 | **手机链路两个真机问题定位与修复 + 手机端本地转写**。① **手机调不动电脑智能体**：根因是 `agent_llm.py` 用单线程 `HTTPServer`，一个慢请求（等大模型）会把整个 Agent 卡死，手机侧只看到"处理中"→超时；且 `agent_config.json` 的 `api_key` 为空。改为 `ThreadingHTTPServer` + LLM 超时 300s→90s + SSE 写完即 `close_connection`；`/ping` 增加 `agent{ok,hasKey,model,baseUrl}`；`/a2a` 转发前先健康检查（1.5s 超时，5s 缓存），智能体没起来立刻回错误而不是让手机干等，并对流加 90s 超时；手机端据此在顶部条提示"智能体没启动/没配 Key"并阻止发送。默认后端切到本机 Ollama（`qwen2.5:3b`），无需云 Key。② **手机上传的录音电脑端看不到**：原实现把上传文件放 `tmp/`、转写完就删、从不建条目。改为落盘 `audio/up_*.wav` + `insertItem(source_device=phone, status=running)` → 转写 → `saveSegments`（失败标 failed），并通过新增的 `LanServer.onItemsChanged` 回调（main.dart 里绑到 `AppState.bumpData`）让电脑界面即时刷新。③ **wav 时长**：改为按 RIFF `fmt `/`data` 块解析（原按固定偏移会算出 8 小时），手机上传时同时带 `X-Duration-Ms`。④ **手机端本地转写**：`sherpa_onnx 2.0.2`（ffiPlugin）+ SenseVoice-Small int8，独立 isolate 内推理，44.1k→16k 重采样后按 20s 分块识别、按中文标点分句；模型（约 228MB）放数据目录 `models/sensevoice`，支持一键下载（hf-mirror 优先）与本地导入；设置里可切「手机转写 / 电脑转写」，模型缺失自动回退电脑。 |
| v2.1 | 2026-11-20 | **文档与实现对齐（对应 PRD v2.6）**。① 4.5 速记改为近全屏 / 全屏面板（PRD D52）：桌面四周留 26px、手机让出 46px 状态栏，输入区用 `flex:1` 撑满，并标注「Esc 未绑定、全局热键未接」。② 4.6 重写为**手机推送模型**：实际端口 47821 / 47825，七个真实接口（`/ping` `/agents` `/probe` `/transcribe` `/note` `/chat` `/a2a`），推送四步链路，FNV-1a 判重；明确四项未实现（配对码与 token 鉴权、电脑端确认、反向传输、`transfer_log`）。③ 新增 **4.16 手机端同步状态与一键同步**：`uploaded_at` / `dup_of` 状态模型与展示规则、`pendingSyncIds`、重新上传。④ 新增 **4.17 多 Provider AI**：七种预设、两分支实现（A2A 与 OpenAI 兼容）、Ollama 生命周期托管、AI 自动标题与自动标签。⑤ 第 5 章 DDL 标注实现状态：`item` 补 `audio_path`/`body`/`audio_hash`/`dup_of`/`uploaded_at`，新增 `item_tag`/`ai_conv_ref`/`ai_message_ref`/`setting`，明确 8 张早期表未建 |
| v2.2 | 2026-11-21 | **决策落地（对应 PRD v2.7）**。① **音频编码维持 AAC/m4a**（D14 不变）：4.1 改为「`record` 直录 WAV 临时文件 → 停录后内置 ffmpeg 转 m4a → 删除临时件」，转写再解出 16k PCM 中间态；转码列为 M1 任务 15。② **删除首次启动引导**（D33 废止）：4.10 改写为「不做向导、默认值即用、模型在设置页下载/导入」；DDL 的 `setting` 键移除 `onboarded`；打包章节「首启引导下载」改为「设置页下载」；M1 任务表移除「首次启动引导」 |
| v2.3 | 2026-11-21 | **音频编码落地（D14）+ Android 定为 P0**。① 新增 `audio_convert.dart`（`ffmpegPath` / `toM4a` / `to16kWav`），`Transcriber.ffmpegPath()` 改为委托它，避免两处路径不一致。② `RecorderService.start()` 改为「先试 AAC 直出，失败 `cancel()` 后退回 WAV」，返回 `RecordStart{path, aac}`，调用方据此决定是否转码。③ 停录收尾拆成 `_finalizeAudio`（WAV→m4a 归档、`Db.setAudioPath`、删临时文件）与 `_dispatchTranscribe`（本机 SenseVoice / 电脑 whisper / 上传电脑），两步串行避免读写冲突。④ 手机端选「本机转写」时改录 WAV（`sherpa.readWave` 只解析 wav，Android 无解码器），其余情况录 AAC。⑤ `Db.setAudioPath()` 新增。⑥ 4.1 与 M1 任务 15 同步更新 |
| v2.4 | 2026-11-21 | **能力协商 + 运行时依赖打包**。① `/ping` 增加 `ffmpeg` 布尔值；手机 `ping()` 成功后写入 `setting.pc_ffmpeg`，`AppState.startRecord()` 据此决定录 AAC 还是 WAV；`MobileShell.initState` 后台 `discover()` 一次以尽早获得该能力。② 设置 → 转写 新增「音频归档」状态行（`AAC · 已就绪` / `WAV · 缺 ffmpeg`）。③ `app/windows/engine/` 成为运行时依赖的**源目录**，`windows/CMakeLists.txt` 增加 `install(DIRECTORY)` 规则装到 `<exe>/engine/`；新增 `tools/fetch_engine.ps1` 一键拉取 whisper-cli / ffmpeg（**LGPL 共享构建**，避免 GPL 与 MIT 冲突）/ diarizer；`app/.gitignore` 排除该目录 |
| v2.5 | 2026-11-21 | **Android 前台服务落地（PRD D35 / 6.11，P0）**。① 新增 `RecordingService.kt`：`foregroundServiceType=microphone` 前台服务 + 常驻通知（系统计时器 + 「停止」动作），渠道 `IMPORTANCE_LOW`；通知上的停止通过 `MainActivity.onNewIntent` 回传 Dart，走正常 `stopRecord()` 而非直接杀服务——因为录音在 Flutter 引擎内，必须回到 Dart 才能落盘与派发转写。② `MainActivity.kt` 增加 `gaggle/native` MethodChannel：起停服务、`POST_NOTIFICATIONS` 申请（13+）、`isIgnoringBatteryOptimizations`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 跳转（不支持时退应用详情页）、`openAppSettings`。③ Manifest 增加 `<service>` 与 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`。④ Dart 新增 `android_foreground.dart`（非 Android 空操作），`AppState` 在起录/停录/放弃时自动起停服务，并注册通知停止回调；`mobile_settings.dart` 新增「后台保活」卡片。⑤ `flutter analyze` 0 error，`flutter build apk --release` 产出 137.5MB APK，合并清单已校验含 service 与三项权限。**剩余**：真机息屏 30 分钟验证、`AudioFocus` 自动暂停 |
