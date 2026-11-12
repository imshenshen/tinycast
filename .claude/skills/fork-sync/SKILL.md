---
name: fork-sync
description: 检查 tinycast 上游更新并让用户选择是否引用，同时维护 fork 功能记录（docs/fork-features.md）。Use when the user asks to 检查上游更新 / 上游同步 / 引用上游功能 / 记录 fork 功能 / 和上游对比.
---

# Fork 同步（tinycast）

本仓库是 [tinycast](https://github.com/abue-ammar/tinycast) 的 fork。远程约定：上游 `upstream` = abue-ammar/tinycast（只读），自己的 fork `origin` = imshenshen/tinycast（推送目标）。同步状态在 `.claude/skills/fork-sync/state.json`；fork 功能与选择记录在 `docs/fork-features.md`。

## 接续另一个 agent 的同步

先读 `docs/fork-features.md`，再运行不联网、不写状态的命令：

```bash
python3 -I .claude/skills/fork-sync/scripts/fork_sync.py status
```

- `lastCheckedUpstream` 是下次新增提交的扫描起点；`baseCommit` 是 fork 原始基线，只用于全量盘点与重叠分析。检查过不等于全部吸收，不能用 fork 的 HEAD 替代这两个值。
- 输出区分「待选择」「已实施待验证」「已验证引用」「已放弃」。只有「待选择」需要用户选择是否移植。
- 「已实施待验证」仍在 pending，但有 `implementation`：先查看实施范围、排除项、本地提交和验证结果，接着验证，不要再次移植。上次用户选择的非 AI 范围仍适用，不因更换 agent 而扩大。
- 若检查点不存在或不再是上游祖先，脚本会回到 fork 基线扫描；已有实施记录、首次发现时间和已处理决定会保留。上游不包含 fork 基线时停止检查，人工确认历史关系。

两条流程相互独立，按用户要求执行其中一条：

## A. 检查上游更新，选择是否引用

1. 运行（会联网 `git fetch`；浅克隆首次会自动补全历史，可能下载较多数据，属一次性开销）：

   ```bash
   python3 -I .claude/skills/fork-sync/scripts/fork_sync.py check
   ```

   脚本会把本次检查时间、上游 SHA 写入 state.json，并输出：
   - 上次检查以来新增的上游提交（按提交列出文件与统计）；
   - 每条提交是否改到了本地也改过的文件（`⚠ 与本地改动重叠`，是最可能冲突的地方）；
   - 本次扫描起点、下次增量起点，以及分类后的完整待办（含以前发现但未处理的）；
   - 已实施项的范围、本地提交与验证情况，提示继续验证而非重复移植。

2. 把输出整理给用户：
   - 按「功能 / 优化 / 修复」归类，用一句话说明每条提交改了什么；
   - 对改到 `MeetingEvent`、`CalendarStore`、`JoyDayBridge`、`MeetingLink`、`MeetingDetails*`、`RootPaletteView` 的提交，额外说明和我们 fork 功能的关系；
   - 标出 `⚠` 重叠文件，并说明移植时预计要改哪些本地代码。

3. 让用户明确选择「待选择」中的提交。使用当前环境可用的选择工具，或用编号清单让用户回复编号。**用户没有明确选择，就不要引用上游改动；用户可以全部不选。**不要再次询问是否移植「已实施待验证」中的条目。

4. 对每个选中的提交：
   - 先看改动内容：`git show --first-parent --stat <sha>`、`git show --first-parent <sha> -- <paths>`（合并提交默认的组合 diff 可能是空的，`--first-parent` 才会显示实际改动）；
   - **默认手工移植**，把上游改动适配到本地实现，保留 fork 的独有功能和用户选择的范围；
   - 只有用户明确同意先提交 fork 改动、且工作区干净时，才可以用 `git cherry-pick -x <sha>`；
   - 移植后必须构建并跑相关测试（见下）。构建或测试失败时不得标记完成。

5. 结果记账（state.json 位于仓库内，方便下次检查继续跟踪）：
   - 已移植但验证尚未通过：`python3 -I .claude/skills/fork-sync/scripts/fork_sync.py mark-applied <sha> "实际范围及排除项" --validation "已通过的检查与剩余失败" --commit <本地提交>`。尚未提交时省略 `--commit`，提交后再次执行补齐；该命令保留既有验证明细和首次实施时间。
   - 移植好：`python3 -I .claude/skills/fork-sync/scripts/fork_sync.py mark-ported <sha> "一句话备注"`
   - 决定不要：`python3 -I .claude/skills/fork-sync/scripts/fork_sync.py drop <sha> "原因"`
   - `mark-applied` 留在「已实施待验证」；`mark-ported` / `drop` 才移出 pending。不要为了让计数归零而伪造验证通过，或把部分移植写成完整吸收。

6. 如果移植改变了我们的功能边界（例如上游也做了会议详情），顺手更新 `docs/fork-features.md` 对应条目。

构建与测试（在仓库根目录）：

```bash
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
  -derivedDataPath /tmp/tinycast-dd CODE_SIGNING_ALLOWED=NO build
./Scripts/run-tests.sh calendar-test        # 日历/会议模型
./Scripts/run-tests.sh settings-file-test   # 设置文件 schema
./Scripts/run-tests.sh settings-backup-test # 备份覆盖规则
```

## B. 记录 fork 后的功能

1. 运行（不联网）：

   ```bash
   python3 -I .claude/skills/fork-sync/scripts/fork_sync.py diff
   ```

   输出相对基线的全部本地改动：已跟踪文件（增/删行数）、未跟踪新文件，以及每个文件上游是否已经改过。`.claude/` 和本功能记录本身不计入。

2. 对新增或有实质变化的部分，读 `git diff <base> -- <file>`（未跟踪文件直接读），据此更新 `docs/fork-features.md`：
   - 新增功能条目：名称、日期、做了什么、关键文件、与上游的关系/冲突点；
   - 更新「变更文件索引」表；
   - 更新顶部「最后更新」和「上游检查」状态；
   - 不要删除旧条目；被取代的条目标注「已由 X 取代」。

3. 如果用户只想看看，不改文档，直接总结即可。

## state.json 字段

- `baseCommit` / `baseTag`：fork 基线（37e6043 / v0.12.3-beta.127）；
- `lastCheck`：上次检查时间（ISO 8601，含时区）；
- `lastCheckedUpstream`：上次检查到的上游 SHA；
- `pending`：尚未完成处理的上游提交，不要手工清空；没有 `implementation` 的才是待选择候选；
- `pending[].implementation`：已实施待验证记录，含 `status: applied-awaiting-validation`、`appliedAt`、`note`（实际范围）、可选 `localCommit`（本地提交完整 SHA）、`validation`（检查结果字典）。`mark-applied --validation` 更新其中的 `summary`，保留其他明细；
- `ported` / `dropped`：已验证引用 / 明确不跟踪的提交；部分移植的边界继续保留在 note 和 implementation 中。

修改同步脚本后运行 `python3 -I Scripts/test-fork-sync.py`。测试使用临时 Git 仓库和本地远端，覆盖增量检查、分类、记录更新与回退重扫，不访问真实上游、不修改仓库同步检查点。

## 约束

- 绝不读取、导出或记录京ME/JoyDay 的 cookie、token 或会话；JoyDay 数据只能沿用现有 `JoyDayBridge` 的页面内请求路径。
- 不对工作区做破坏性 git 操作（`reset --hard`、`checkout --`、`stash drop`、删除未跟踪文件）；不要覆盖未提交的改动。
- 未经用户要求不 commit、不 push；`upstream`（上游）只读，绝不向它推送；fork 改动推送到 `origin`（imshenshen/tinycast），推送前需用户明确同意。
- 上游可能改动 JoyDay 依赖的接口（`MeetingEvent`、`CalendarStore`、`JoyDayBridge`）；移植后至少构建一次，按改动范围跑测试。
- 用户面对的是中文界面，汇报用中文；命令、路径、SHA 保持原样。
