# Contributing to Gaggle

Thanks for taking the time to contribute. This file covers the practical bits: how to build, how to test, and what a good pull request looks like.

中文贡献者可以直接用中文提 issue / PR —— 仓库文档以中文为主，不必先翻译成英文。

---

## 1. Before you start

| 你想做的事 | 该怎么做 |
|---|---|
| 报告 bug | 用 [Bug report](.github/ISSUE_TEMPLATE/bug_report.yml) 模板，附版本号、系统、复现步骤、日志 |
| 提功能建议 | 用 [Feature request](.github/ISSUE_TEMPLATE/feature_request.yml) 模板，先说"解决什么场景" |
| 改代码 | 先在 issue 里说一句你要动哪块，避免撞车 |
| 移植到 macOS / Linux | 先开 issue 认领，音频层和 A2A 层已经是抽象过的 |
| 翻译 / 文档 | 最欢迎，直接提 PR |

**不要**在 issue 里贴完整的 API Key、真实录音、`gaggle.db`。

## 2. Development setup

```powershell
git clone https://github.com/MrAlexWang/gaggle-voice-notes.git
cd REPO\app
flutter pub get
flutter run -d windows
```

必要环境：

- Flutter 3.50+ / Dart 3.14+
- Windows：Visual Studio 2022 + "Desktop development with C++"
- Android：Android SDK + NDK（只在构建 APK 时需要）
- Python 3.10+（只在跑 `tools/` 下的 A2A 示例服务时需要）

运行时引擎（ffmpeg / whisper-cli / diarizer）和 ASR 模型都不在仓库里：

```powershell
powershell -ExecutionPolicy Bypass -File tools\fetch_engine.ps1
```

模型在应用内「设置 → 模型」下载，或手动放进 `<数据目录>\models`。

## 3. Code layout

```
app/lib/            Flutter 源码（Windows + Android 共用一套）
  main.dart         桌面主界面与入口
  mobile_*.dart     手机端界面
  db.dart           SQLite + FTS5 索引
  recorder.dart     录音
  transcriber.dart  whisper.cpp 调度
  sense_voice.dart  手机端 SenseVoice 转写
  diarize.py 相关   见 tools/
  a2a.dart          A2A 客户端（出站）
  ai_client.dart    各 AI Provider 适配
  lan.dart          局域网发现与传输
tools/              Python：A2A 示例服务、声纹分离、引擎拉取
docs/               PRD、技术方案、发布清单
prototype/          界面原型（HTML，仅作视觉依据）
```

分层规则见 `docs/TECH_DESIGN.md` 第 4 节：**UI 层不直接调 FFI，服务层不直接碰 Widget**。改架构先改文档。

## 4. Code style

- `flutter analyze` 必须没有 **error / warning**（info 级别不拦）。提交前本地跑一次。
- 格式化按仓库自带的 `analysis_options.yaml`，不额外引入新的 lint 规则。
- 注释写"为什么"，不写"是什么"；中文注释可以保留。
- 新增第三方依赖前请先开 issue 说明理由 —— 桌面端每加一个插件都要面对 Windows 构建风险。

## 5. Tests

```powershell
cd app
flutter test
```

现有测试覆盖纯逻辑（时间格式化、AI 标题/标签解析等）。涉及 UI 与 FFI 的部分请在 PR 描述里写清**你手动验证了什么**，例如：

> 手动验证：Windows 11 / 录音 3 分钟 → 转写 → 搜"预算" → 点击命中项从 01:12 开始播放 ✅

## 6. Pull requests

1. 一个 PR 只做一件事，标题用 Conventional Commits：`feat: …` `fix: …` `docs: …` `refactor: …` `perf: …`
2. 说明「问题 → 方案 → 验证方式」，UI 改动附截图或 GIF。
3. 改了行为就同步改 `docs/PRD.md` 的决策记录；改了架构就同步改 `docs/TECH_DESIGN.md`。**只改代码不改文档的 PR 会被要求补上。**
4. 不要提交：`dist/`、`workspace/`、`app/windows/engine/`、`*.db`、`*.wav`、`tools/agent_config.json`、任何 Key。`scripts/push-to-github.ps1` 里有对应检查。
5. CI 通过后再请求 review。

## 7. Commit message

```
feat(transcribe): 支持 large-v3 模型自动降级
fix(lan): 修复同一 Wi-Fi 下手机重复上传被判为不重复
docs(readme): 补充首次使用需要先下模型
```

## 8. Reporting security issues

不要开公开 issue，走 [SECURITY.md](SECURITY.md) 里的私下渠道。

## 9. License

提交 PR 即表示你同意以 [MIT](LICENSE) 协议授权你的贡献。
