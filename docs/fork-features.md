# Tinycast Fork 功能记录

本仓库是 [tinycast](https://github.com/abue-ammar/tinycast) 的公开 fork：在保留上游启动器能力的基础上，加入京ME（JoyDay）日历与会议能力，并做了一组构建与交互修复。

这份文件记录 fork 后新增/修改的功能及其涉及文件，便于上游更新时判断冲突范围。由 `.claude/skills/fork-sync` 维护。

- Fork 基线：`37e6043`（上游 `v0.12.3-beta.127`，2026-10-27）
- 上游：`upstream` / `main` — <https://github.com/abue-ammar/tinycast>（只读）
- Fork 仓库：`origin` — <https://github.com/imshenshen/tinycast>（推送目标）
- 当前分支：`feat/jd-calendar`（已推送到 `origin`）；`main` 保持与上游一致
- 最后更新：2026-11-12
- 最近上游检查：2026-11-10T21:24:01+08:00（上游 `58168bf7`，发现 48 个提交；其中 8 个已按选择移植非 AI 部分，全套测试仍有基线失败，暂留 pending 并附 implementation 记录）
- 上游检查时间与待处理清单：见 `.claude/skills/fork-sync/state.json`
- 刷新命令：
  - 上游检查：`python3 -I .claude/skills/fork-sync/scripts/fork_sync.py check`
  - 本地盘点：`python3 -I .claude/skills/fork-sync/scripts/fork_sync.py diff`

## 下次同步从哪里继续

入口在根目录 `AGENTS.md` 的 Fork and upstream sync 节，完整流程见
[fork-sync](../.claude/skills/fork-sync/SKILL.md)。先运行 `status` 读取交接，不必先联网：

```bash
python3 -I .claude/skills/fork-sync/scripts/fork_sync.py status
```

当前下次增量起点为 `58168bf7e0b721f7c5fbfc7f4e8a068a48cff446`，由
`state.json.lastCheckedUpstream` 记录；`check` 获取上游后只扫描该点之后的新增提交。
`baseCommit` 仍为 fork 原始基线 `37e6043`，用于盘点本地差异，不表示要重新选择或移植所有历史。

当前分为待选择 40 项、已实施待验证 8 项、已验证引用 0 项。8 个已实施项仍在 pending，各项的
`implementation` 保存了实施范围、验证结果和本地提交 `7af66734`；请继续验证，不要重复移植，
也不要扩大此前选定的非 AI 范围。`status` 和 `check` 都会单独显示这些项。

通过 `mark-applied` 记录已实施待验证的工作，通过 `mark-ported` 记录验证通过的引用。
下次检查会保留现有待办；检查点失效而回到基线重扫时，也会保留实施记录和首次发现时间。
2026-11-12 只完善了交接工具，没有重新获取上游，检查时间和增量检查点保持 2026-11-10 的记录。

## 功能记录

### 1. 京ME（JoyDay）日历合并

- 日期：2026-10-29
- 内容：在 EventKit 之外新增 JoyDay 日历源。通过京ME 已打开的 JoyDay 标签页读取：Tinycast 在本地完成请求签名，`fetch` 在京ME 页面内执行，页面自带登录态，cookie/会话不离开京ME；按 JoyDay Web 端的规则展开重复日程及移动/删除的实例。两个来源合并成一个事件列表；设置 › 日历提供开关、状态、刷新与「在京ME 中打开」；JoyDay 每 5 分钟轮询，时间范围变化时重新拉取。
- 签名配置：`webAppID` / `webSecret` 不随仓库提交，放在 `~/.config/tinycast-dev/joyday-signing.json`（权限 600）；缺失时设置页提示 "JoyDay signing is not configured"。更换机器或重装后需要重新放一份。
- 新增文件：
  - `Tinycast/Features/Calendar/Service/JoyDayClient.swift` — 京ME AppleScript JS 桥、签名与 JoyDay 接口调用
  - `Tinycast/Features/Calendar/Service/JoyDayEvents.swift` — JoyDay 行 → `MeetingEvent` 的展开规则
- 修改文件：`CalendarStore.swift`、`MeetingEvent.swift`、`CalendarSettingsView.swift`、`MenuBarSummary.swift`、`UpcomingWindow.swift`、`Tinycast.xcodeproj/project.pbxproj`、`Resources/Localizable.xcstrings`、`Tests/calendar-test.swift`
- 与上游的关系：上游若重构 `CalendarStore` / `MeetingEvent`，这里是最大冲突面；「不读取、不导出 cookie」的桥接约束不能丢。

### 2. 京ME 会议：详情、电脑入会、复制链接

- 日期：2026-10-29
- 内容：新增 `.jdMeeting` provider（`jdme://`、joymeeting.jd.com、meeting.jd.com、jdmeeting.com）。JoyDay 列表行可以先声明「有线上会议」而不带链接，入会/复制时按 occurrence 调用详情接口取链接；详情页异步加载，带加载中/失败/已失效状态；菜单栏、⌘K 操作菜单、日程 pill 都能入会；非会议的 JoyDay 行回车进入详情，EventKit 行仍打开 Calendar。日程行的回车行为统一走 `activate`；详情页在列表里找不到事件时仍用打开时的快照渲染。
- 修改文件：`MeetingLink.swift`、`MeetingLauncher.swift`、`CalendarCoordinator.swift`、`CalendarMenuBarItem.swift`、`MeetingCardView.swift`、`MeetingDetailsScreen.swift`、`MeetingDetailsView.swift`、`ScheduleScreen.swift`、`ScheduleView.swift`、`LauncherScreen.swift`、`CalendarStore.swift`、`MeetingEvent.swift`、`Resources/Localizable.xcstrings`、`Tests/calendar-test.swift`
- 与上游的关系：上游的会议详情/入会是同一片区域；冲突时保留 fork 的 JoyDay 数据源与 `.jdMeeting` 分支。

### 3. 面板钉住（Pin the launcher）

- 日期：2026-10-29
- 内容：设置 › 通用 › 外观新增「钉住启动器」；展开面板底部动作组右侧有图钉按钮。钉住后切到别的 App 面板保持可见，⌘K 菜单失焦只收起菜单；未钉住保持原有的失焦隐藏。钉住状态写入设置文件 `appearance.pinPalette`，但刻意排除在备份导入之外。
- 修改文件：`AppSettingsKey.swift`、`AppSettings.swift`、`SettingsFileKey.swift`、`SettingsFileSchema.swift`、`SettingsBackupCoverage.swift`、`GeneralSettingsView.swift`、`PaletteWindowController.swift`、`MenuPanel.swift`、`RootPaletteView.swift`、`Resources/Localizable.xcstrings`、`docs/features/palette.md`
- 与上游的关系：`RootPaletteView` / `PaletteWindowController` 上游改动频繁；钉住逻辑只在失焦隐藏的守卫处早退，冲突时保留 `pinPalette` 判断。

### 4. 辅助功能授权引导修复

- 日期：2026-10-29
- 内容：设置里点「授予访问权限」时，未授权则先触发系统 TCC 提示（`Permissions.ensureAccessibility()`），再打开辅助功能设置页，使 Tinycast Dev 真正出现在系统列表中。
- 修改文件：`PermissionsSettingsView.swift`
- 与上游的关系：上游若重做权限页，保留「先请求、再打开设置」的顺序。

### 5. Swift 6.2 / Xcode 27 编译兼容

- 日期：2026-10-29
- 内容：任务具链的机械调整：`HyperKeyEngine` 显式 memberwise init、`OverflowFade` 的 CGFloat→Double 显式转换、`RootPaletteView` 的观察链拆成 `queryObservers` / `modeObservers` 并抽出 `queryChanged` / `modeChanged`（避免类型检查超时）。
- 修改文件：`HyperKeyEngine.swift`、`OverflowFade.swift`、`RootPaletteView.swift`
- 与上游的关系：纯编译修复，上游跟进后可以直接对齐。

### 6. 剪贴板快捷键调整

- 日期：2026-11-10（提交 `4ac45195`）
- 内容：默认 ↵ 粘贴、⌘↵ 粘贴为纯文本、⌃⌘↵ 复制；修改默认动作时，粘贴接管该动作原来的快捷键。删除改为 ⌘D，保留 ⌘⌫；菜单、测试和两处快捷键文档同步。
- 修改文件：`ClipboardStore.swift`、`ClipboardScreen.swift`、`PaletteShortcut.swift`、`Tests/clipboard-test.swift` 及剪贴板文档。
- 与上游的关系：`3879ba7` 修改同一个 store 的异步图片采集，位置与快捷键映射不同；移植时保留本地映射。上游剪贴板文档仍需按本地快捷键适配。

### 7. 临近会议倒计时强调

- 日期：2026-11-10（提交 `4ac45195`）
- 内容：临近会议倒计时使用红色粗体，隐藏占位按粗体宽度预留，避免倒计时列变宽。
- 修改文件：`Theme.swift`、`MeetingRowParts.swift`。
- 与上游的关系：上游最终状态相对基线没有 Calendar 文件差异，JoyDay 数据源、会议详情与入会流程不受直接影响；玻璃外观更新会修改 `Theme.swift`，需保留 `imminent` 色值。

### 8. 提升启动器窗口层级

- 日期：2026-11-10（提交 `4ac45195`）
- 内容：面板层级从 `.modalPanel + 1` 提升到 `.mainMenu - 1`，避免被其他应用的置顶窗口遮挡；拖拽引导和对话框继续按面板层级派生。
- 修改文件：`Platform/WindowLevel.swift`、`docs/ui.md`。
- 与上游的关系：本轮上游未修改 `WindowLevel.swift`；全屏菜单修复 `7655641` 改的是窗口创建前的激活策略，可独立评估。
- 2026-11-10 运行验证：被 iTerm2 热键窗口遮挡时，进程实际运行 `/Applications/Tinycast Dev.app` 的 10 月 30 日旧程序，窗口层级仍为 9；源码中的层级 23 未回退。正常退出后，用本次签名构建替换并重启该路径，主程序和调试库哈希与构建产物一致；系统窗口列表确认 Tinycast 层级 23，排在 iTerm2 热键窗口层级 22 之前。无需继续提高层级。

### 9. 吸收上游非 AI 稳定性修复

- 日期：2026-11-10
- 用户选择：首次筛选的 1–4 组，排除 AI 相关改动。
- 移植：`e22d381` 输入法导航键；`3879ba7` 的非 AI 数据安全、生命周期和测试运行器修复；`c6da716` 文本域无限宽探测；`7655641` 普通窗口全屏菜单；`3c0073f` Notes 标题栏拖动；`4cd6ef9` 搜索范围文件夹；`18c0f16` 外观提示；`7588828` HTML/RTF 剪贴板采集。
- `3879ba7` 保留：剪贴板图片采集代次、Quicklink 导入事务、备份逐行惰性读取、相机异步结果身份检查、扩展安装输出排空、文件预览取消检查、设置符号链接重试、更新替换前取消检查、测试套件互斥和结果计数、FileIndexHelper 发布检查。
- `3879ba7` 未取：AI/Codex/Claude/翻译代码及相应测试文档、上游自动关闭未关联 issue 的 PR 工作流与贡献说明、未使用的窗口布局方法清理。没有修改 `Features/AI`、`Features/MCP`、`Features/QuickActions`。
- 保留 fork 的 JoyDay 日历/会议、钉住、观察链拆分、剪贴板快捷键、倒计时色值与面板层级。
- 维护：拉取稳定版标签后，lint 要求删除已发布的 `CompactFavoritesMigration`。按 `docs/migrations.md` 清除其代码、启动调用、专用测试和文档行；由 XcodeGen 重新生成项目，JoyDay 两个文件仍保留。
- 验证：Debug 构建成功、签名验证通过、lint 通过、Model 无 UI 导入；新增无限宽探测回归，`form-input-test --text-area` 通过。全套 110 个 harness 中 106 通过；`app-installation-test`、`form-input-test`、`callout-test` 保留上次已复现的失败，`onboarding-test` 的焦点失败也由提交前编译的测试程序在当前桌面复现。全套未通过，不调用 `mark-ported`；8 个候选在 pending 内附实施范围与验证记录。

## 变更文件索引

| 文件 | 类型 | 功能 |
| --- | --- | --- |
| `Tinycast/Features/Calendar/Service/JoyDayClient.swift` | 新增 | 1 |
| `Tinycast/Features/Calendar/Service/JoyDayEvents.swift` | 新增 | 1 |
| `Tinycast/Features/Calendar/Service/CalendarStore.swift` | 修改 | 1, 2 |
| `Tinycast/Features/Calendar/Model/MeetingEvent.swift` | 修改 | 1, 2 |
| `Tinycast/Features/Calendar/Model/MeetingLink.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/Model/MenuBarSummary.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/Model/UpcomingWindow.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/Service/MeetingLauncher.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/Settings/CalendarSettingsView.swift` | 修改 | 1 |
| `Tinycast/Features/Calendar/UI/CalendarCoordinator.swift` | 修改 | 1, 2 |
| `Tinycast/Features/Calendar/UI/CalendarMenuBarItem.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/UI/MeetingCardView.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/UI/MeetingDetailsScreen.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/UI/MeetingDetailsView.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/UI/ScheduleScreen.swift` | 修改 | 2 |
| `Tinycast/Features/Calendar/UI/ScheduleView.swift` | 修改 | 2 |
| `Tinycast/Features/Launcher/UI/LauncherScreen.swift` | 修改 | 2 |
| `Tinycast/Features/Settings/AppSettings.swift` | 修改 | 3 |
| `Tinycast/Features/Settings/AppSettingsKey.swift` | 修改 | 3 |
| `Tinycast/Features/Settings/Model/SettingsFileKey.swift` | 修改 | 3 |
| `Tinycast/Features/Settings/SettingsFileSchema.swift` | 修改 | 3 |
| `Tinycast/Features/Settings/Panes/GeneralSettingsView.swift` | 修改 | 3 |
| `Tinycast/Features/Settings/Panes/PermissionsSettingsView.swift` | 修改 | 4 |
| `Tinycast/Features/Backup/Model/SettingsBackupCoverage.swift` | 修改 | 3 |
| `Tinycast/Palette/MenuPanel.swift` | 修改 | 3 |
| `Tinycast/Palette/PaletteWindowController.swift` | 修改 | 3 |
| `Tinycast/Palette/RootPaletteView.swift` | 修改 | 3, 5, 9 |
| `Tinycast/Features/HotKeys/Model/HyperKeyEngine.swift` | 修改 | 5 |
| `Tinycast/DesignSystem/Scrolling/OverflowFade.swift` | 修改 | 5 |
| `Tinycast/Resources/Localizable.xcstrings` | 修改 | 1, 2, 3 |
| `Tinycast.xcodeproj/project.pbxproj` | 修改 | 1, 9 |
| `Tests/calendar-test.swift` | 修改 | 1, 2 |
| `docs/features/palette.md` | 修改 | 3, 9 |
| `Tinycast/Features/Clipboard/Model/ClipboardStore.swift` | 修改 | 6, 9 |
| `Tinycast/Features/Clipboard/UI/ClipboardScreen.swift` | 修改 | 6 |
| `Tinycast/Palette/PaletteShortcut.swift` | 修改 | 6 |
| `Tests/clipboard-test.swift` | 修改 | 6, 9 |
| `Tinycast/DesignSystem/Theme.swift` | 修改 | 7 |
| `Tinycast/Features/Calendar/UI/MeetingRowParts.swift` | 修改 | 7 |
| `Tinycast/Platform/WindowLevel.swift` | 修改 | 8 |
| `Tinycast/DesignSystem/FormTextArea.swift` | 修改 | 9 |
| `Tinycast/Features/Backup/Model/BackupBundle.swift` | 修改 | 9 |
| `Tinycast/Features/Camera/UI/CameraCoordinator.swift` | 修改 | 9 |
| `Tinycast/Features/Clipboard/Service/ClipboardManager.swift` | 修改 | 9 |
| `Tinycast/Features/Extensions/Service/ExtensionInstaller.swift` | 修改 | 9 |
| `Tinycast/Features/FileSearch/UI/FileSearchPreview.swift` | 修改 | 9 |
| `Tinycast/Features/Launcher/Settings/SearchScopesSection.swift` | 修改 | 9 |
| `Tinycast/Features/Notes/UI/NotesPanel.swift`、`NotesView.swift` | 修改 | 9 |
| `Tinycast/Features/Quicklinks/Model/QuicklinkStore.swift` | 修改 | 9 |
| `Tinycast/Features/Settings/Service/SettingsFileMonitor.swift` | 修改 | 9 |
| `Tinycast/Features/SystemActions/Service/SystemActionRunner.swift` | 修改 | 9 |
| `Tinycast/Features/Updates/Service/UpdateInstaller.swift` | 修改 | 9 |
| `Tinycast/Platform/ActivationPolicy.swift`、`Tinycast/Windows/AppWindowController.swift` | 修改 | 9 |
| `Tinycast/App/AppCore.swift` | 修改 | 9 |
| `Tinycast/Migrations/CompactFavoritesMigration.swift`、`Tests/compact-favorites-migration-test.swift` | 删除 | 9 |
| `Tests/form-input-test.swift`、`Tests/pasteboard-test.swift`、`Tests/quicklink-test.swift` | 修改 | 9 |
| `Scripts/run-tests.sh`、`Scripts/verify-signature.sh`、`.github/workflows/release.yml` | 修改 | 9 |

## 上游同步状态

- 每次检查的时间、检查到的上游 SHA、待处理/已引用的提交，都记录在 `.claude/skills/fork-sync/state.json`。
- 引用上游改动的默认做法是手工移植；移植后运行构建与相关测试，再用 `fork_sync.py mark-ported <sha>` 记账。
- 上游自基线以后若改到上表这些文件，`fork_sync.py check` 会在对应提交下标注「⚠ 与本地改动重叠」。

### 2026-11-10 首次筛选结论

上游从基线新增 48 个提交，涉及 335 个文件。以下是首次筛选分组；1–4 组后续已按用户选择移植非 AI 部分，进展见功能 9，其他候选未选择。pending 中已移植项附有 implementation 记录。

| 顺序 | 候选 | 收益与适配点 |
| --- | --- | --- |
| 1 | `e22d381` | 输入法组词期间将方向键、Tab、Esc 留给候选窗。与本地 `RootPaletteView` 重叠，保留观察链拆分和钉住相关逻辑。 |
| 2 | `3879ba7` | 数据安全与生命周期修复：清空后不再插入迟到的剪贴板图片、Quicklink 批量写事务、Codex 管道离开主线程、扩展安装输出持续排空等。覆盖 27 个文件，按功能核对；保留本地剪贴板快捷键。 |
| 3 | `c6da716`、`7655641`、`3c0073f`、`4cd6ef9`、`18c0f16` | 独立修复：文本域无限宽探测崩溃、全屏 Space 的普通窗口菜单、Notes 标题栏拖动、搜索范围选择文件夹、切换外观后的提示。当前没有 fork 源文件重叠。 |
| 4 | `7588828` | 捕获只有 HTML/RTF 的复制内容，转为纯文本；HTML 限制 256 KB。依赖前面的剪贴板采集接口变更，文档需保留本地快捷键。 |
| 5 | `25d86bf`、`de115d8`、`5fab5cb`、`6ac7216`、`7031f8a`、`42cc467`、`f52b964`、`10421dd` | Raycast 扩展兼容：登录取消完成、uid/gid、SharedArrayBuffer、网卡、AES-GCM、stdio 文件描述符、表单值恢复、缺失配置引导。生成 runtime 必须通过构建脚本更新。 |
| 6 | `9a09762`、`a9eb610`、`9df9375`、`95ecb01`、`ff4fa05` | AI/MCP：OpenAI Responses 工具调用、OpenCode v2 使用 Tinycast 的 MCP、推理强度、思考展开、聊天预设。按使用需求选择；新文件通过 project.yml/XcodeGen 接入，保留 fork 设置和备份排除项。 |
| 7 | `2008ba9`、`6bf543f`、`16e64fb`、`1b238e1`、`c538633`、`3be769d`、`bd0cbf9`、`788237c` | 功能扩展：自然语言计算、货币对查询与汇率源、双语词典排版、窗口贴边/跨屏、内置命令 deeplink。词典更新碰到 `RootPaletteView`；deeplink 涉及较多设置、入口和权限边界。 |

- 玻璃外观链 `e3f813c` → `14f3ceb` → `da105e4` → `c1a838a` 应按最终状态整体审查；`7f3e5b4` 已被 `58168bf` 完整回滚，不单独吸收。外观改动与 `Theme`、`RootPaletteView`、`PaletteWindowController`、`MenuPanel` 重叠，保留钉住和本地窗口层级。
- `1a2c80a` 的 AppSSO 修复使用私有 `_preventsAppSSO` 属性；仅在确实遇到企业 SSO 请求失败时再评估。
- 签名/公证/退出时更新及更新提示重构（`dc265b2`、`d129c17`、`57111cf`）涉及发布身份和更新信任。上游 `ReleaseFeed.repository` 仍指向 `abue-ammar/tinycast`；fork 应先确定自己的发布与更新源再吸收。
- 网站审校和文案提交可后续同步，需保留 JoyDay、钉住、剪贴板快捷键等 fork 差异。

首次提交验证：Debug 构建成功、lint 通过、Model 无 UI 导入。全套 111 个 harness 首跑 106 通过；`ext-test` 和 `icon-cache-test` 单独复跑通过。剩余 `app-installation-test`、`form-input-test`、`callout-test` 的相同失败在提交前基线 `a8cb9ad5` 上均复现，尚未修复；不能视为全套测试通过。后续移植验证见功能 9。
