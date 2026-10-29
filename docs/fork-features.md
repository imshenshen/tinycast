# Tinycast Fork 功能记录

本仓库是 [tinycast](https://github.com/abue-ammar/tinycast) 的私有 fork：在保留上游启动器能力的基础上，加入京ME（JoyDay）日历与会议能力，并做了一组构建与交互修复。

这份文件记录 fork 后新增/修改的功能及其涉及文件，便于上游更新时判断冲突范围。由 `.claude/skills/fork-sync` 维护。

- Fork 基线：`37e6043`（上游 `v0.12.3-beta.127`，2026-10-27）
- 上游：`upstream` / `main` — <https://github.com/abue-ammar/tinycast>（只读）
- Fork 仓库：`origin` — <https://github.com/imshenshen/tinycast>（推送目标）
- 当前分支：`feat/jd-calendar`；fork 改动目前尚未提交（都在工作区）
- 最后更新：2026-10-29
- 最近上游检查：2026-10-29T18:09:13+08:00（上游仍为基线，无新提交；以 state.json 为准）
- 上游检查时间与待处理清单：见 `.claude/skills/fork-sync/state.json`
- 刷新命令：
  - 上游检查：`python3 -I .claude/skills/fork-sync/scripts/fork_sync.py check`
  - 本地盘点：`python3 -I .claude/skills/fork-sync/scripts/fork_sync.py diff`

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
| `Tinycast/Palette/RootPaletteView.swift` | 修改 | 3, 5 |
| `Tinycast/Features/HotKeys/Model/HyperKeyEngine.swift` | 修改 | 5 |
| `Tinycast/DesignSystem/Scrolling/OverflowFade.swift` | 修改 | 5 |
| `Tinycast/Resources/Localizable.xcstrings` | 修改 | 1, 2, 3 |
| `Tinycast.xcodeproj/project.pbxproj` | 修改 | 1 |
| `Tests/calendar-test.swift` | 修改 | 1, 2 |
| `docs/features/palette.md` | 修改 | 3 |

## 上游同步状态

- 每次检查的时间、检查到的上游 SHA、待处理/已引用的提交，都记录在 `.claude/skills/fork-sync/state.json`。
- 引用上游改动的默认做法是手工移植；移植后运行构建与相关测试，再用 `fork_sync.py mark-ported <sha>` 记账。
- 上游自基线以后若改到上表这些文件，`fork_sync.py check` 会在对应提交下标注「⚠ 与本地改动重叠」。
