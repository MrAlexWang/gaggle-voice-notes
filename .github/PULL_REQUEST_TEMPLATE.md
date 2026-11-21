## 这个 PR 做了什么

<!-- 一两句话说清。 -->

## 关联 issue

<!-- Closes #12 -->

## 类型

- [ ] feat 新功能
- [ ] fix 修 bug
- [ ] perf 性能
- [ ] refactor 重构（不改行为）
- [ ] docs 文档
- [ ] build / ci

## 怎么验证的

<!-- 必填。CI 只跑得到静态分析与纯逻辑测试，涉及 UI/音频/FFI 的改动请在本地手动验证并写下来。 -->

- [ ] `flutter analyze` 无 error / warning
- [ ] `flutter test` 全绿
- [ ] 手动验证（写清步骤与结果）：

## 检查清单

- [ ] 没有提交 `dist/`、`workspace/`、`app/windows/engine/`、模型、音频、数据库
- [ ] 没有提交任何 API Key（`tools/agent_config.json` 已被忽略）
- [ ] 行为有变化时同步更新了 `docs/PRD.md`
- [ ] 架构有变化时同步更新了 `docs/TECH_DESIGN.md`
- [ ] UI 改动附了截图或 GIF
