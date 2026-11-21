# 发布清单 · Release Checklist

> 每次发布前从头过一遍。打勾的项才算完成，不要靠记忆。
> 首次开源请先完成「0. 首次发布一次性事项」。

---

## 0. 首次发布一次性事项

### 0.1 占位符必须全部替换

仓库里有几处故意留了占位符，推上去之后会变成坏链接，请逐个替换：

| 占位符 | 出现位置 | 替换成 |
|---|---|---|
| `OWNER/REPO` | `README.md`、`CHANGELOG.md`、`SECURITY.md`、`.github/ISSUE_TEMPLATE/config.yml` | `你的用户名/仓库名` |
| `MAINTAINER_EMAIL` | `CODE_OF_CONDUCT.md`、`SECURITY.md` | 你的联系邮箱 |
| `OWNER` / `REPO` 单独出现 | `CONTRIBUTING.md` 的 clone 命令 | 同上 |

> `scripts/push-to-github.ps1` 会自动把 `OWNER/REPO` 换成真实值并补一次提交，其余两个需要手动改。

### 0.2 仓库设置

- [ ] Description：`Local-first voice & note vault: record, transcribe offline, search any sentence, ask your own AI agent. No account, no cloud.`
- [ ] Topics：`local-first` `privacy` `speech-to-text` `whisper` `voice-notes` `meeting-notes` `offline` `self-hosted` `a2a` `flutter` `desktop` `android` `sqlite` `ollama`
- [ ] Settings → Social preview 上传 `1280x640` 封面图
- [ ] Settings → Features：开 Discussions（issue 模板里已指向它）
- [ ] Settings → Security：开 Private vulnerability reporting（`SECURITY.md` 依赖它）
- [ ] Branch protection：`main` 要求 CI 通过
- [ ] License 选择确认：MIT（`LICENSE` 已就位）

### 0.3 必备素材

- [ ] `docs/images/demo.gif`：20–30 秒，**录音 → 转写 → 搜到一句话 → 点开听原声**（README 首屏只认这一块）
- [ ] `docs/images/`：3 张截图（桌面时间流、检索命中、AI 对话面板），宽度 ≥ 1200px
- [ ] 2 分钟演示视频（可选，发社区时用）
- [ ] 商标与域名核查：WIPO + 中国商标网查 `Gaggle`；`gaggle.app` / `getgaggle.com` 是否可注册

---

## 1. 代码与版本

- [ ] `app/pubspec.yaml` 的 `version:` 已升级（`0.1.0+1` → `0.2.0+2` 形式，`+` 后是构建号）
- [ ] `CHANGELOG.md` 增加了本次版本段落，日期与 tag 一致
- [ ] `docs/PRD.md` 的决策记录与本次行为一致（新增/废止的决策要写进去）
- [ ] `docs/TECH_DESIGN.md` 与实现一致（分层、接口、选型有变动时）
- [ ] `flutter analyze` 无 error / warning
- [ ] `flutter test` 全绿
- [ ] 工作区没有未提交改动（`git status` 干净）

## 2. 安全与体积

- [ ] `scripts/push-to-github.ps1 -DryRun` 跑一遍，确认没有任何大文件/敏感路径被加入
- [ ] `git ls-files | Select-String "agent_config|\.db$|\.wav$|\.bin$"` 结果为空
- [ ] 仓库体积：`git count-objects -vH`，`size-pack` 应远小于 100MB
- [ ] 依赖没有新增 AGPL / 商用受限协议

## 3. 构建产物

- [ ] Windows 安装包：`flutter build windows --release` → Inno Setup 编译 `app/installer.iss`，产物放 `dist\`
- [ ] 确认 `app\windows\engine\` 已打进安装包（ffmpeg / whisper-cli / diarizer 缺一不可）
- [ ] Android APK：`flutter build apk --release --target-platform android-arm64`，产物放 `dist\`
- [ ] **在干净机器上装一遍**：能录 → 能下模型 → 能转 → 能搜 → 能播
- [ ] 版本号出现在关于页/安装包里，与实际 tag 一致

## 4. 发布

- [ ] 打 tag：`git tag v0.2.0 && git push origin v0.2.0`
- [ ] GitHub → Releases → Draft a new release，选 tag
- [ ] 上传附件：`Gaggle-0.2.0-Setup.exe`、`Gaggle-0.2.0-android.apk`（**不要**把安装包提交进仓库）
- [ ] Release notes 用「用户看得懂的变化」写，不要贴 commit 列表
- [ ] 校验哈希：把 `SHA256` 写进 release notes

## 5. 发布后 7 天

- [ ] 一天只发一个渠道，顺序见 `docs/OPEN_SOURCE_GTM.md` 第 3 节
- [ ] 提 awesome 清单 PR（`awesome-selfhosted`、`awesome-local-first`、`awesome-privacy`、`awesome-whisper`）
- [ ] 登记 AlternativeTo / opensourcealternative.to（以 Otter.ai 替代品身份）
- [ ] 首发周结束写一篇复盘（"发布一周我踩的坑"），比广告更容易被接受
- [ ] 把反馈最多的 3 个问题变成 issue 并排进下一个版本

---

## 6. 常见翻车点

| 现象 | 原因 | 处理 |
|---|---|---|
| 别人 clone 后 `flutter run` 报找不到 ffmpeg | 没跑 `tools/fetch_engine.ps1` | README 已写，回答时直接给命令 |
| 装完能录不能转 | 没下模型 | 回复：设置 → 模型 → small |
| 仓库 1GB+、clone 极慢 | 模型/引擎/安装包被提交了 | `git rm --cached` + 补 `.gitignore` + 必要时 `filter-repo` 重写历史 |
| Release 下载 404 | 附件没上传，或 tag 与文件名版本号不一致 | 重新上传，保持 `Gaggle-x.y.z-*` 命名 |
| 被 issue 问"为什么只有 Windows" | 没读 README 的 Platform support | 直接引用该段，别重复解释 |
