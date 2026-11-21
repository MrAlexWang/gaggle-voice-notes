# 雁书 Gaggle · 开源发布调研报告

> 目的：如果把这个项目开源，投哪些渠道最有效、名字怎么取更有吸引力
> 版本：v1.1 · 2026-11-19
> 数据来源：2026 年 10–11 月公开资料核查（渠道规则会变，正式发布前需再核对一次）

---

## 0. 结论先行

### 0.1 已决策（2026-11-19 确认）

| # | 事项 | 结论 |
|---|---|---|
| 1 | 是否开源 | **开源** |
| 2 | 英文名 | **Gaggle**（中文仍为雁书）；弃用 Anser |
| 3 | 平台范围 | **维持 Windows 优先不变**，Linux/macOS 只在 README 写 roadmap，不给时间 |
| 4 | 开源协议 | 建议 **MIT**（待最终签字） |
| 5 | 渠道优先级 | GitHub 自身 → awesome 清单 → r/selfhosted → r/LocalLLaMA → Show HN → 中文社区 |

### 0.2 关键判断

| 判断 | 结论 |
|---|---|
| 最容易传播的定位 | **「Otter.ai / 会议纪要工具的本地替代品」**，比"语音笔记库"好卖十倍 |
| 最有价值的渠道 | **GitHub 自身 + awesome 清单 + r/selfhosted**（长尾稳定），不是 Hacker News |
| 对 HN 的预期要压低 | 2025.9–2026.8 共 15,859 条带仓库的 Show HN，**中位数只有 2 分，仅 9.5% 过 10 分** |
| 最大障碍（已接受） | **只支持 Windows**。self-hosted / local-first 圈以 Linux、macOS 用户为主 → 用 README 的 roadmap 段缓解，见 8.1 |
| 开源协议 | 想最大化采用 → MIT / Apache-2.0；想防别人闭源商用 → AGPL-3.0 |

---

## 1. 开源前必须先定的定位

开源圈不看你做了多少功能，只看**一句话能不能说清"它替代了什么"**。

**推荐主张（英文）**
> A local-first voice & note vault. Record, transcribe offline, search any sentence, then ask your own AI agent. No account, no cloud.

**推荐主张（中文）**
> 录音不上传的会议记录工具：本地转写，搜到一句话就能听到原声，还能接你自己的 AI。

**对标与替代对象**（写进 README 第一段，帮助别人 3 秒理解）

| 替代谁 | 你的差异 |
|---|---|
| Otter.ai / 讯飞听见 | 音频与文字都不出本机，无订阅 |
| Granola / Notion AI 会议纪要 | 不需要账号，不锁在 SaaS 里 |
| 系统自带语音备忘录 | 有转写、有全文检索、能跳回原声 |

**三个能打的差异点（按传播力排序）**
1. **不上传**：录音、转写、索引全在本地 → 隐私党 + 企业内网用户
2. **接自己的 Agent（A2A）**：不绑定任何厂商模型 → 本地 LLM 玩家（2026 年这个话题很热）
3. **双轨录音**（P1）：麦克风与系统声音分开存 → 会议场景的真实痛点

> 潜在受众分三圈：`self-hosted 玩家` → `本地 LLM 玩家` → `隐私敏感的知识工作者`。第一圈最容易被激怒也最愿意 star，第二圈最愿意写博客帮传播。

---

## 2. 渠道矩阵

### Tier 1 · 必投（投入产出最高，长期有长尾）

| 渠道 | 规模/性质 | 怎么用 | 注意 |
|---|---|---|---|
| **GitHub 仓库本身** | 最大的实际流量入口 | README 首屏、Topics、Description、Social Preview、Releases 写更新故事 | 大部分人是从搜索/清单进来，先看 README 前 10 行 |
| **r/selfhosted** | 约 70 万成员，规则严格 | 发布后 1–2 周投，标题直接说"自托管/Otter 替代" | **9:1 规则**（10 条内容最多 1 条自推广）；必须 production-ready 且有文档，否则被删 |
| **awesome-\* 清单** | 每条清单自带持续流量 | 提 PR 收录：`awesome-selfhosted`、`awesome-local-first`、`awesome-privacy`、`awesome-flutter`、`awesome-whisper` | 审核慢（几天到几周），要按各清单格式写；这是最稳的长尾来源 |
| **AlternativeTo / opensourcealternative.to** | 搜索"Otter alternative"的人会来 | 以 Otter.ai、Granola、Voice Memos 的替代品身份登记 | 需要真实截图与功能列表 |
| **selfh.st / LibHunt / daily.dev** | 聚合站与开发者信息流 | 提交项目，等收录 | 通常免费，需填表 |

### Tier 2 · 可能爆量，但不保证

| 渠道 | 说明 | 关键动作 |
|---|---|---|
| **Hacker News（Show HN）** | 爆发力最强，命中率最低（中位数 2 分） | 标题写 `Show HN: Local-first voice notes with offline transcription`；美东周二/周三 8–10 点发；**必须自己先顶一条评论讲设计取舍** |
| **r/LocalLLaMA** | A2A + 本地 Agent 在这里最有共鸣 | 讲"如何用 A2A 接 Ollama"，不要只发链接 |
| **r/opensource / r/programming** | 泛开发者，量大但杂 | 讲技术决定（为什么 FTS5 trigram、为什么不上云） |
| **r/privacy / r/PrivacyGuides** | 隐私向，容忍度低 | 必须能自证"零网络请求"，否则被围攻 |
| **Product Hunt** | 适合有视觉的产品 | 需要提前找 hunter，当天配合推特/领英；本地工具在 PH 表现一般 |

### Tier 3 · 中文圈与长尾

| 渠道 | 适合内容 |
|---|---|
| **V2EX「分享创造」** | 中文开发者首发首选，讲清楚技术栈与坑 |
| **少数派** | 面向效率工具用户，需要成体系的体验文，稿费/约稿可谈 |
| **小众软件（appinn）** | 收录即带量，直接投稿 |
| **即刻 / 小红书 / B站** | 需要 30–60 秒演示视频；B站适合"本地 AI 工具"选题 |
| **掘金 / 思否** | 技术长文，SEO 有长尾 |
| **YouTube 技术博主** | self-hosted 类频道转化最高，先送免费授权+素材包 |
| **Newsletter** | Console.dev、TLDR、selfh.st weekly，发邮件自荐 |

---

## 3. 发布节奏（90 天）

**T-30 ~ T-7｜预热（关键，不能空降）**
- 在目标社区先做**真实贡献**：回答别人的录音/转写问题，攒到能发帖的 karma
- 准备物料：README、3 张截图、**一段 20 秒 GIF**（录音→转写→搜到一句话→点击播放）、2 分钟视频
- 建 Discord 或 Telegram，README 里放进去

**T-0 ~ T+6｜发布周（一天一个渠道，连发会被判 spam）**

| 天 | 渠道 |
|---|---|
| D1 | GitHub Release + 个人社交（X/即刻/朋友圈） |
| D2 | 提交 awesome 清单 PR（先排队审核） |
| D3 | r/selfhosted |
| D4 | r/LocalLLaMA（讲 A2A + Ollama 接法） |
| D5 | Show HN（美东周二/周三上午） |
| D6 | Product Hunt（若物料够） |
| D7 | V2EX / 小众软件投稿 |

**T+7｜二次传播**
- 写一篇「发布一周：我踩的 7 个坑」——HN 与 Reddit 对复盘文的接受度高于广告
- 发 v0.1.x，修掉首发被吐槽最多的问题

**T+30｜长线**
- 找 2–3 个 YouTuber / UP 主做实测
- 投稿 newsletter
- 每月一个 Release，README 里挂 Star 曲线

---

## 4. 命名：已定 Gaggle（原 Anser 弃用）

**Anser 作为开源名的三个现实问题**

| 问题 | 具体表现 |
|---|---|
| 检索冲突 | `anser` 是雁属学名（被鸟类数据库占满）、Anserini 是知名 IR 库；搜 "anser ai" 很难稳定命中你 |
| 拼写歧义 | 英文用户第一反应是 answer 拼错，需要每次解释"这是雁属" |
| 传播成本 | 名字本身没有说明用途，必须靠副标补，而副标往往被忽略 |

**命名 6 条硬标准**（参考 Open Source Guides / IEEE 命名指南）
1. 2–3 音节，一次能读对
2. 与用途有隐喻关联，但不必直白
3. GitHub 仓库名、域名、X 账号同时可得
4. 无商标冲突（查 WIPO 全球品牌库 + 各国商标网）
5. 跨文化无负面联想
6. 字母形状适合做 Logo（避免 O/0、I/l 混淆）

**候选对比**

| 名字 | 含义 | 优势 | 风险 |
|---|---|---|---|
| **Gaggle** ★推荐 | 一群鹅（a gaggle of geese）+ 七嘴八舌 | 与 Anser 同源（雁属），又直指"多人对话录音"；词短、好读、好搜 | 曾有一家 Gaggle.Net（学生邮箱服务，2021 关闭），但不在软件工具领域 |
| Murmur | 低语 / 鸟群声 | 气质极准，短 | MurmurHash 太有名，搜索结果会被吃掉 |
| Bowerbird | 园丁鸟收集亮色物件筑巢 | 隐喻"收集灵感"极佳 | 9 个字母偏长，缩写 bower 语义弱 |
| Wren | 鹪鹩，叫声响亮 | 短、好读、好做 logo | 撞名项目较多 |
| Starling | 椋鸟，会模仿人声 | 与"转写人声"呼应 | 略常见，且有一家 Starling Bank 很知名 |
| Lark | 云雀 | 发音最好听 | **飞书英文名就是 Lark**，中文圈必混 |

**最终决定（已确认）**
- **英文名：Gaggle**；中文名保留**雁书**。
- 两者天然对得上：Anser 是"雁属"，gaggle 是"一群雁"。中文"雁书"本来就该对应"一群雁的书信"——**这不是换名，是补上了英文该有的那层意思**。
- 仓库名用 `gaggle-voice-notes`：GitHub 上已有 4 个短名就叫 `gaggle` 的仓库（搜 gaggle 命中 308 个仓库，详见第 11 节），带关键词才搜得到；**不要**用 `gaggle-desktop-flutter` 这类技术堆砌。
- 域名优先级：`gaggle.app` > `getgaggle.com` > `gaggle.cc`。
- 同步改动：应用包名 `com.gaggle.app`、安装目录 `%LOCALAPPDATA%\Gaggle`、数据库 `gaggle.db`。

**发布前必须完成的资产占位**
- [ ] GitHub 组织 `gaggle`（含 `gaggle/` 下的 repo 名）
- [ ] 域名 `gaggle.app` / `getgaggle.com`
- [ ] X / 即刻 / B站 账号同名
- [ ] 商标检索：WIPO 全球品牌库 + 中国商标网（"Gaggle" 在软件类目是否已被注册）

---

## 5. README 首屏公式（决定 10 秒去留）

```
[项目名] — [一句话替代了什么]
[20 秒 GIF：录音 → 转写 → 搜到一句话 → 点开听到原声]

· 录音不出本机（附截图或"零网络请求"说明）
· 离线转写，中英混说（附准确率与速度实测表）
· 搜索任意句子，点击直达原声
· 可选：接你自己的本地 Agent（A2A）

[Windows 安装包下载] · [从源码构建] · [文档]
```

**反例（现在最容易被写成这样）**：开头先讲架构分层、讲 A2A 协议细节、讲为什么用 Flutter。这些放后面的「设计取舍」章节，别放首屏。

---

## 6. GitHub SEO 建议

**Description**（160 字符内）
> Local-first voice & note vault: record, transcribe offline, search any sentence, ask your own AI agent. No account, no cloud.

**Topics**
`local-first` `privacy` `speech-to-text` `whisper` `voice-notes` `meeting-notes` `offline` `self-hosted` `a2a` `flutter` `desktop`

> 搜索命中主要靠 **Topics + Description**，其次才是仓库名。所以名字的独特性没你想象的那么关键，但**口头传播的记忆点**很关键。

---

## 7. 现实预期与指标

| 指标 | 健康值（self-hosted 类新项目） |
|---|---|
| 首月 Star | 300–800 |
| 上 HN 首页概率 | < 10% |
| 首发周 issue 数 | 10–30（有人提 issue 比 star 更值钱） |
| 真正决定留存的 | 从下载到"录完第一条并搜到"的时间 < 5 分钟 |

---

## 8. 发布前必须解决的三件事

| # | 问题 | 为什么致命 | 应对 |
|---|---|---|---|
| 1 | **只支持 Windows**（已决策维持，D42） | self-hosted 受众大量用 Linux/macOS，会直接说"用不了" | 按 8.1 的口径在 README 前置说明，降低期待落差 |
| 2 | **没有演示视频/GIF** | 桌面软件看不到效果就没人下载 | 20 秒 GIF 必须有，重点展示"搜到一句话→听到原声" |
| 3 | **首次 1GB 模型下载** | 劝退率极高 | 提供 small（190MB）一键体验档，让用户在 1 分钟内看到效果 |

### 8.1 Windows-only 的官方口径（照抄进 README）

```markdown
## Platform support

**Windows 10/11 is the primary target** and the only platform with a signed build today.

Why: the recorder needs low-level audio access and the transcriber needs a desktop-class
CPU. Getting that reliably right on one platform first beats shipping three broken ones.

- ✅ Windows 10/11 (x64) — supported
- 🟡 macOS — planned; system-audio capture requires ScreenCaptureKit, tracked in #issue
- ⬜ Linux — planned; no ETA

If you want to help port it, the audio and A2A layers are already platform-abstracted
(see `lib/core/audio` and `lib/core/a2a`). Contributions welcome.
```

**要点**：主动说明"为什么只做一个平台"，比被质问后解释更能赢得好感；同时给出可参与的切入点，把"用不了"转成 PR 机会。

---

## 9. 开源协议与法律

| 选项 | 适合 | 代价 |
|---|---|---|
| MIT / Apache-2.0 | 想要最大采用率、想被集成 | 别人可以闭源商用 |
| AGPL-3.0 | 想防止云厂商白嫖 | 部分公司禁止使用 AGPL，会损失企业用户 |

**必须加的两段免责**
- 录音合法性：不同地区对"录制他人对话"有同意要求，README 需提示用户遵守当地法律
- AI 输出：总结由本地 Agent 生成，可能存在错误，不构成专业建议

**隐私承诺要能自证**：如果 README 写"不上传"，就要真的没有网络请求。建议提供「离线模式」截图或抓包说明，否则在 r/privacy 会被反噬。

---

## 10. 行动清单

- [x] 确认英文名 → **Gaggle**，PRD / 技术方案 / 原型已同步
- [x] 确认平台范围 → **Windows 优先**，README 用 8.1 口径说明
- [ ] 查商标：WIPO + 中国商标网；查域名：`gaggle.app`、GitHub 组织名、X 用户名
- [x] 写 README（按第 5 节结构）→ 已落地，仍缺 20 秒 GIF
- [x] 选协议 → **MIT**（`LICENSE` 已落地）
- [ ] 建 Discord/Telegram，README 挂链接
- [ ] 提前 3–4 周在 r/selfhosted 与 r/LocalLLaMA 做非推广性参与
- [ ] 准备 3 个 awesome 清单的 PR（按各自格式）
- [ ] 发布周按第 3 节日程执行，一天一个渠道
- [ ] T+7 发复盘文

---

## 11. 命名复核与开源材料清单（2026-11-21）

### 11.1 仓库名为什么带关键词

GitHub 仓库搜索 `gaggle` 的实测结果：

| 观察 | 数据 |
|---|---|
| 命中仓库总数 | 308 |
| 首屏 10 个结果中短名就叫 `GAGGLE` 的 | 4 个（不同 owner） |
| 首屏中 `gaggle` 的变体 | `PYGAGGLE`、`GAGGLED`、`JAFFLE_GAGGLE` |
| 用途分布 | 滑翔机 App、Raft 实现、文本排序库、iOS 协作、DuckDB 扩展……语义完全发散 |

**结论**：`gaggle` 是通用英文词，作为短名撞名中高；但 GitHub 的完整仓库名（`owner/repo`）仍然唯一，所以**品牌不用改**，只需把关键词放进仓库名：

- 仓库名 → **`gaggle-voice-notes`**（`gaggle` 已在多个账号下被占用）
- 徽章、clone 命令、issue 链接里的 `OWNER/REPO` 由 `scripts/push-to-github.ps1` 自动替换
- 真正决定搜索命中率的是 **Description + Topics + README 前 10 行**，见第 6 节，别指望仓库名单独扛流量

### 11.2 已补齐的开源材料

| 文件 | 作用 | 状态 |
|---|---|---|
| `README.md` | 首屏定位、替代对象、功能、构建、隐私、免责 | ✅ 新建 |
| `CONTRIBUTING.md` | 构建步骤、代码结构、提交规范、PR 规则 | ✅ 新建 |
| `CODE_OF_CONDUCT.md` | Contributor Covenant 2.1（含中文摘要） | ✅ 新建，待填邮箱 |
| `SECURITY.md` | 漏洞私下上报流程、范围界定 | ✅ 新建 |
| `CHANGELOG.md` | Keep a Changelog 格式，0.1.0 起 | ✅ 新建 |
| `.github/ISSUE_TEMPLATE/*` | bug / feature 模板 + Discussions 与安全入口 | ✅ 新建 |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR 自查清单 | ✅ 新建 |
| `.github/workflows/ci.yml` | analyze + test（Ubuntu）+ Windows 构建冒烟 | ✅ 新建 |
| `docs/RELEASE_CHECKLIST.md` | 占位符、仓库设置、构建、发布、翻车点 | ✅ 新建 |
| `tools/agent_config.example.json` | A2A 示例服务配置模板（key 不入库） | ✅ 新建 |
| `scripts/push-to-github.ps1` | 一键建仓/推送/替换占位符/打 tag | ✅ 重写 |
| `docs/images/` | GIF 与截图的落盘位置说明 | ✅ 新建 |
| `demo.gif` + 3 张截图 | README 首屏转化率的关键 | ⬜ 待补 |
| 商标 / 域名核查 | WIPO、中国商标网、`gaggle.app` | ⬜ 待办 |

### 11.3 首次发布必做的三处替换

1. `OWNER/REPO` → 你的 `用户名/仓库名`（脚本自动处理）
2. `MAINTAINER_EMAIL` → 你的邮箱（`CODE_OF_CONDUCT.md`、`SECURITY.md`，脚本只提醒不猜）
3. `LICENSE` 的版权人：现在是 `Gaggle contributors`，如需改成个人/公司名请自行修改
