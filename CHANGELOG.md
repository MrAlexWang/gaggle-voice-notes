# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-21

首个公开版本。主链路可用：录 → 存 → 转 → 查 → 问。

### Added

- **录音与速记**：全局快捷键快录；纯文字速记全屏面板（`Ctrl+Shift+N`），与录音在时间流中并列。
- **本地转写**：桌面端 whisper.cpp（`ggml-small/medium/large-q5` 多档，按硬件推荐），中英混说。
- **全文检索**：SQLite FTS5（trigram）索引，命中一句即可跳转到对应时间点播放。
- **说话人分离**：单麦声纹聚类，支持重命名说话人、按说话人筛选。
- **导入音视频**：自动提取音轨并排队转写；同内容音频按哈希判重。
- **AI 能力**：Ollama / DeepSeek / 千问 / Kimi / OpenAI / 任意 OpenAI 兼容端点 / A2A Agent 七种来源；多选条目做跨条总结；AI 自动标题与自动标签。
- **局域网同步**：手机与电脑在同一 Wi-Fi 下发现、配对、互传，无中转服务器。
- **手机端离线转写**：SenseVoice-Small（int8）本地推理，模型可下载或本地导入，失败自动回退电脑转写。
- **数据管理**：标签体系、30 天回收站 + 10 秒撤销、多选批量操作、数据目录可迁移。

### Known limitations

- 仅提供 Windows 安装包与 Android APK；macOS / Linux 在路线图中，无时间承诺。
- 首次转写前需手动下载模型（约 190MB 起）。
- 系统声音与麦克风双轨录音尚未实现（P1）。

[Unreleased]: https://github.com/OWNER/REPO/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/OWNER/REPO/releases/tag/v0.1.0
