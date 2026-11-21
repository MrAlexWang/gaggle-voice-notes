<div align="center">

# 雁书 · Gaggle

**Local-first voice & note vault.**
Record it, transcribe it offline, search any sentence, and jump straight back to that moment in the audio.
No account, no cloud, no subscription — and the AI runs on your own machine.

[![CI](https://github.com/OWNER/REPO/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-2f6f6a.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11%20%7C%20Android-2f6f6a.svg)](#platform-support)
[![Downloads](https://img.shields.io/github/downloads/OWNER/REPO/total.svg)](https://github.com/OWNER/REPO/releases)
[![Stars](https://img.shields.io/github/stars/OWNER/REPO?style=flat)](https://github.com/OWNER/REPO/stargazers)

[Download](#download) · [Build from source](#build-from-source) · [AI setup](#ai-setup-optional) · [Docs](#documentation) · [中文说明](#中文说明)

</div>

<!--
  演示 GIF 放这里，删掉下面的注释标记即可（这是首屏最值钱的一块）：
  docs/images/demo.gif —— 30 秒内讲完：按下快捷键录音 → 自动转写 → 搜一句话 → 点开直接听到原声。
![Gaggle demo](docs/images/demo.gif)
-->

---

## Why another notes app?

Most "AI meeting notes" tools take your audio to someone else's server and charge you monthly for the transcript. Gaggle takes the opposite route: **everything stays on your disk**, and the AI is whatever you already run.

| Instead of | With Gaggle |
|---|---|
| Otter.ai / 讯飞听见 | Audio and transcript never leave the machine; no subscription |
| Granola / Notion AI meeting notes | No account, no SaaS lock-in |
| Built-in voice memos | Full-text searchable transcript that jumps back to the exact second |
| Cloud voice-note apps | PC ↔ phone sync over your own LAN, no relay server |

## Features

- **Offline transcription** — whisper.cpp on desktop (`ggml-small/medium/large-q5`), SenseVoice-Small on Android. Chinese/English mixed speech is the primary target.
- **Search a sentence, hear it** — SQLite FTS5 (trigram) index over the transcript; every hit plays the original audio at that timestamp.
- **Speaker diarization** — embedding + clustering on a single microphone; rename speakers, export the transcript.
- **Fast capture** — global hotkey recording, plus a text-only note panel (`Ctrl+Shift+N`) for when you can't talk.
- **Import media** — drop in audio/video files, extract the track and queue it for transcription. Duplicate audio is detected by content hash.
- **Bring your own AI** — Ollama, DeepSeek, Qwen, Kimi, OpenAI, any OpenAI-compatible endpoint, or an **A2A agent** you host yourself. Multi-select several recordings and ask for a cross-item summary.
- **LAN sync** — phone pushes items to the desktop over Wi-Fi; no cloud account involved.
- **Tags, recycle bin, batch ops** — manual + AI tags, 30-day recycle bin with 10-second undo, Ctrl/Shift multi-select.

## Download

| Platform | File | Notes |
|---|---|---|
| Windows 10/11 (x64) | `Gaggle-x.y.z-Setup.exe` | Inno Setup installer, installs per-user (no admin required) |
| Android 8.0+ (arm64) | `Gaggle-x.y.z-android.apk` | Enable "install unknown apps" for your file manager |

Grab them from the [Releases page](https://github.com/OWNER/REPO/releases).

### First run: two things to know

1. **Download a model before your first transcription.** Settings → 模型 → pick `small` (~190 MB). Recording works without it, transcription doesn't. `medium`/`large` are faster on a GPU and more accurate, but the first download is big.
2. **AI is optional and needs a source.** Add an endpoint in Settings → AI (Ollama locally, or any OpenAI-compatible key). Nothing is sent anywhere until you configure it.

Your data lives in `%LOCALAPPDATA%\Gaggle` (audio, `gaggle.db`, models, engine binaries). Settings can move the whole directory to another drive.

## Platform support

**Windows 10/11 is the primary target**, and the only platform with an installer today.

Why: the recorder needs low-level audio access and the transcriber wants a desktop-class CPU/GPU. Getting that reliably right on one platform beats shipping three broken ones.

- ✅ Windows 10/11 (x64) — supported, installer provided
- ✅ Android 8.0+ (arm64) — same Dart codebase, APK build
- 🟡 macOS — planned; system-audio capture needs ScreenCaptureKit, tracked as an issue
- ⬜ Linux — planned, no ETA

The audio and A2A layers are already platform-abstracted (see `app/lib/recorder.dart`, `app/lib/a2a.dart`). Ports are welcome — open an issue first so we don't duplicate work.

## Build from source

Prerequisites:

- Flutter 3.50+ (Dart 3.14+)
- Windows: Visual Studio 2022 with the **Desktop development with C++** workload
- Android: Android SDK + NDK (only if you build the APK)
- Python 3.10+ (only for the optional A2A server under `tools/`)

```powershell
git clone https://github.com/OWNER/REPO.git
cd REPO\app
flutter pub get
flutter run -d windows          # 或 flutter build windows --release
```

**Runtime engines are not in the repo** — ffmpeg, `whisper-cli` and the `diarizer` bundle are hundreds of megabytes. Fetch or build them into `app\windows\engine\`:

```powershell
powershell -ExecutionPolicy Bypass -File tools\fetch_engine.ps1
```

ASR models are **not** in the repo either: download them from the app (Settings → 模型), or drop `ggml-*.bin` into `<data dir>\models`.

```powershell
flutter build apk --release --target-platform android-arm64   # Android
```

The Windows installer is generated with Inno Setup 6 from `app\installer.iss` after a release build.

## AI setup (optional)

Two independent ways to get an AI, both fully local-friendly:

1. **Direct provider** — Settings → AI → add Ollama (`http://127.0.0.1:11434/v1`) or any OpenAI-compatible endpoint. Keys are stored locally only.
2. **A2A agent** — run the bundled example agent; the app discovers it and treats it as one more provider.

```powershell
copy tools\agent_config.example.json tools\agent_config.json
python tools\agent_llm.py        # 或双击仓库根目录的「启动AI助手.bat」
```

`tools/agent_config.json` is git-ignored on purpose — never commit a real key.

## Data & privacy

- **No account, no telemetry, no backend.** Apart from (a) an AI endpoint you configured yourself and (b) another Gaggle instance on your LAN, the app makes no network requests.
- Audio is stored as AAC/m4a (~30–60 MB per hour); the database is a single SQLite file next to it.
- **Backup = copy the data directory.** Uninstalling the app does not delete it.
- Deleted items stay in a 30-day recycle bin and can be purged manually.

## Documentation

| Document | What's inside |
|---|---|
| [`docs/PRD.md`](docs/PRD.md) | Product decisions, scope, MVP acceptance criteria (中文) |
| [`docs/TECH_DESIGN.md`](docs/TECH_DESIGN.md) | Architecture, module boundaries, data model, ADRs (中文) |
| [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md) | Everything to do before tagging a release |
| [`CHANGELOG.md`](CHANGELOG.md) | Version history |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Build, test, PR rules |

## Roadmap

- [ ] macOS support (ScreenCaptureKit for system audio)
- [ ] Linux support
- [ ] Dual-track recording (microphone + system audio as separate tracks)
- [ ] Encrypted local database
- [ ] Wearable / voice-recorder import

## Contributing

Issues and pull requests are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Good first issues: platform ports, translations, and docs. By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © Gaggle contributors

## Disclaimer

- **Recording law**: recording other people's conversations requires consent in many jurisdictions (some require all-party consent). You are responsible for complying with your local law.
- **AI output**: transcripts and summaries are generated by local models and can be wrong. They are not professional advice.

---

## 中文说明

**雁书 Gaggle** 是一个**不上传云端**的语音 + 笔记库。主链路是 **录 → 存 → 转 → 查 → 问**：

- **录 / 记**：全局快捷键一键录音；不方便说话时用速记（纯文字，`Ctrl+Shift+N`）。
- **转**：本地转写（桌面用 whisper.cpp，手机用 SenseVoice-Small），中英混说，音频与文字都不出本机。
- **查**：搜任意一句话，点一下直接跳到那段音频播放。支持按说话人筛选。
- **问**：把多条录音一起丢给你自己的 AI（Ollama / DeepSeek / 千问 / Kimi / 任意 OpenAI 兼容端点 / 自建 A2A Agent），做跨条目总结。
- **同步**：手机和电脑在同一 Wi-Fi 下一键互传，没有中转服务器。

对标：Otter.ai、讯飞听见、Granola 的本地替代品。

**目前只提供 Windows 安装包与 Android APK**；macOS / Linux 在路线图里，不承诺时间。第一次使用请先到「设置 → 模型」下载一个小模型（约 190MB），否则只能录不能转。

数据目录：`%LOCALAPPDATA%\Gaggle`（可在设置里迁移）。卸载不会删数据，备份就是拷贝这个目录。

产品与技术的完整决策记录见 [`docs/PRD.md`](docs/PRD.md) 与 [`docs/TECH_DESIGN.md`](docs/TECH_DESIGN.md)。
