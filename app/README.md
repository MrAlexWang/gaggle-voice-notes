# app/

Flutter 前端源码（Windows + Android 共用一套 Dart 代码）。

- 构建、运行、测试说明见仓库根目录的 [README.md](../README.md)。
- 代码结构、分层规则、数据模型见 [docs/TECH_DESIGN.md](../docs/TECH_DESIGN.md)。
- 运行时引擎（ffmpeg / whisper-cli / diarizer）不在仓库里，用 `tools/fetch_engine.ps1` 拉取到 `windows/engine/`。

```powershell
flutter pub get
flutter run -d windows     # 或 flutter run -d <android-device>
flutter test
```
