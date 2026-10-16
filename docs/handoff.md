# memfuse 维护者交接（handoff）

> 分工：**README = 用户向**（定位 / 决策机制 / 快速开始 / 战报 / 局限）；**本文 = 维护者向**（发版流程 / 部署状态 / 修改红线 / 回滚）。
> 最近更新：2026-10-16

## 1. 发版流程与节奏

- 仓库：`https://github.com/joker1point/memfuse`；本地 checkout `trae_projects\memfuse\`（当前在 `main`）。
- **push 通道**：2026-10-15 实测 **HTTPS 通道恢复正常**（`git fetch/push`、`gh` 全部走 `https://github.com/...` 正常，`origin` 保持 HTTPS 不动）；ssh 443 通道 `ssh://git@ssh.github.com:443/joker1point/memfuse.git` 留作备用。
- 流程：feature 分支 PR → merge → tag `vX.Y.Z` → push tag 触发 `release.yml`。
  - **产物由 runner 构建**（本机传不了 `uploads.github.com`）；给老 tag 补挂资产 = `POST /actions/workflows/release.yml/dispatches`（或 `gh workflow run release.yml -f tag=vX.Y.Z`）。
  - 2026-10-15 起 `release.yml` 多了**一道验收闸**：构建后逐个检查 zip 内 `.ps1/.cmd/.bat` 是否 CRLF、含非 ASCII 的 `.ps1` 是否带 UTF-8 BOM，不过关直接失败不发布。
- **发版后必须验收交付物本体**：`gh release download v1.3.0 --dir <tmp>` → 解包 → 查行尾/BOM → **从解包出来的目录里真跑一条只读命令**（`memfuse.cmd -ShowProcMem explorer`）。2026-10-15 靠这一步抓到 `.cmd` 在 zip 里是纯 LF（见 §5）。
- **对外更新渠道 = Release 说明 + README**（2026-10-08 用户决定：v1.2.0 更新视频已出片但不发，「没必要发视频，在 github 上说了就好」——**别再催投稿**）。注意 `release.yml` 会先用占位说明（`See the assets below.`）自动建 release，**发版后要 `gh release edit <tag> --notes-file …` 换成正式说明**。
- B 站节奏（若恢复）：每攒够 3 个用户可见更新发一支更新视频。**当前批次计数 = 4**（自 v1.2.1 起算：v1.2.1 / v1.3.0 / v1.4.0 / v1.4.1）——**已超阈值**，但按 2026-10-08 的决定（「没必要发视频，在 github 上说了就好」）**不主动推视频**。
- 版本历史速览：
  - `v1.0.0`（原版，tag → `fd507f3`）
  - PR #1 merged（`c567750`：窗口宽限/白名单热加载/`memfuse.cmd`）
  - `v1.2.0`（PR #2 + #3 merged，main = `0e05c8f`：白名单小白化 / 数字菜单 / `-PreferIdle`）
  - PR #4 merged（main = `e79399a`）+ `v1.2.1`：桌面快捷方式（装守护现建、卸载删）
  - PR #5 merged（`a61b596`：托盘模式 + 手动干预 `-ShowProcMem` / `-KillProc` / 托盘双击开菜单 / 菜单 6-8 项）+ **`v1.3.0`**；随后两个发版修复：`7170e28`（`.gitattributes` 补 `*.cmd` CRLF + zip 验收闸门）、`864a980`（闸门判据改为「含非 ASCII 才要求 BOM」，本地预演抓到的过严条件）
  - **`v1.4.0`**（`ed3f732` + `47d6b37`，main = `47d6b37`）：**降级档**（不杀只让路：警告线以下把最大的非前台进程降到 `BelowNormal` + 回收工作集，内存恢复或 `-DemoteHoldSec`(600s) 后还原，`-NoDemote` 可关）/ 菜单瘦身 5 项（`0`/`6` 下架，`0` 留作隐藏退出键；2+4、3+5 合并）/ 紧急档松绑（`< 3.5%` 时 `-EmergencyCooldownSec` 3s、上限 ×3）/ **降级状态落盘**（`<LogDir>\demote-state.txt` + 启动 `Restore-StrandedDemotes` 接手还原）；配套 `tests/kill-brake.ps1`、`tests/demote.ps1`（13 项）
    - 发版执行（2026-10-16）：tag `d30670f`（附注）→ run `38876610246` **success**（验收闸门通过）→ 资产 `memfuse-1.4.0.zip` **74175B** + `gh release edit` 换正式说明（1371 字符）。**本体验收通过**：zip 内 19 个文件逐个查行尾/BOM（三个 `.cmd` 32/18/28 全 CRLF、`memory-guard.ps1` 与 `kill-proc.ps1` BOM=True、纯 ASCII 的 `.ps1` 无 BOM 正确）+ 从解包目录实跑 `memfuse.cmd -ShowProcMem explorer` 中文输出正常。开发机守护/托盘无需重启（运行中代码 = 标签内脚本，`git diff v1.4.0 HEAD -- memory-guard.ps1` 为空）。
  - **`v1.4.1`**（`400bd97`）：**前台应用全家豁免**——候选进程名 == 前台窗口所属进程名 → 跳过（**不杀也不降级**；切到后台即恢复为候选）。动机：浏览器 renderer 没有窗口，pid 判定救不了"正在读的那一页"（当天实测 `Tabbit Browser` renderer 16:50 被杀、16:38 被降级；用户报"正在阅读的页面总是被杀"）。实现点：`Get-Candidates` 里一处过滤（击杀 `Invoke-Relief` / 降级 `Invoke-Demote` / 演练预览三处都经它）+ 纯函数 `Remove-ForegroundApp` / `Get-ForegroundName`；配套 `tests/foreground-app.ps1`（AST 抽函数 + 接线断言）。**实测探针**：池 = 前台族 + 对照组 → 候选行只有对照组，前台族（CodeBuddy CN 族 22 进程 3916MB）缺席 ✓。注意：`tests/demote.ps1` 在内存高压下偶发假红（首轮 3 项失败、复跑 13/13），属时序抖动、非本改动引入。
- **2026-10-16 起另有 CI**（`f51c331`）：push / PR 自动跑 `.github/workflows/ci.yml` —— 全仓 `.ps1` 语法解析 + README 素材规范（报告用，`continue-on-error`）+ 对外材料红线（硬门）；脚本在 `tools/`。本次发版前已本地预演三项 ✓（语法过、红线 PASS、素材规范 FAIL 但非硬门）。**维护者注意**：`ci.yml` 与 `tools/` 由另一条工作线在改（本次发版时工作区仍留着它们的未提交改动）——提交只 `git add` 自己的路径，别顺手带上。

## 2. 开发机生产守护状态与回滚

- 已于 2026-09-27 **切到新版**：计划任务 args 指向 `trae_projects\memfuse\memory-guard.ps1`，白名单 `trae_projects\memfuse\protect-list.txt`（含 `codebuddy cn`）。
- **回滚路径**：用原版 `frontend-works\tools\memory-guard\memory-guard.ps1`（sha `2140873372AA4A00…`，未改动）→ 跑 `-InstallTask` → 停新实例 → 拉起。
- 2026-10-14 20:19：守护重启加载 `-ShowProcMem` / `-KillProc` 新版（pid 58084，启动时间晚于脚本 mtime，日志有新 `started` 行）；同时清掉一个 10-08 遗留的旧菜单壳（否则在里面按 7/8 不识别）。
- 2026-10-15：pid 58084 于 15:07–15:19 间死亡（机器未重启、uptime 23 天，死因未查明）；**15:19:10 被 5 分钟心跳（计划任务 `MemoryGuard` 重复触发）自动拉起为 pid 72460，日志有新 `started` 行**——自愈机制首次在真实故障中生效。运行中 72460 的守护代码与 main HEAD 逐字节一致（`git diff 2441397 HEAD -- memory-guard.ps1` 为空）→ 无需再次重启。
- 2026-10-15：托盘**不在自愈范围内**（用户托盘 88868 同晚消失也没回来）——需手动双击 `tray.cmd`；当日维护会话已重新拉起（pid 29632）。
- 2026-10-16：守护/托盘各重启两轮（14:16 守护 pid 22248 加载紧急档 → 15:21 **守护 pid 24360 + 托盘 pid 3524** 加载降级档 + 落盘修复；两轮都以"启动时间晚于脚本 mtime + 日志新 `started` 行"验证）。降级档已在本机真实触发（`Tabbit Browser` / `SogouCloud` / `WorkBuddy`）；**降级状态写 `<LogDir>\demote-state.txt`**（守护重启后由新实例接手还原，已实测生成与清理）。仍在的旧包袱：`C:\Users\biren\Desktop\.git` 本地化石仓库（1 文件、无 remote）未处置。

## 3. 修改红线

- **守护不会自动更新代码**：脚本在进程启动时读入内存，心跳只在它死后重拉 —— **改完守护代码必须手动重启一次，并用日志证明**（找只存在于新提交的行，如 `close-to-background: armed`）。
- **中文界面的前提 = `.ps1` 带 UTF-8 BOM**（PS 5.1 才正确读中文）；**日志保持英文关键词**（测试套件按英文断言）。
- 测试套件（`tests\`）按英文断言、纯 ASCII 约束运行环境，改文案别动断言依赖的关键词。
- **菜单结构（2026-10-16 精简后）**：`1` 演练 / `2` 保护名单（= `whitelist.cmd` 界面，头部含"没在运行"诊断）/ `3` 守护开关（装·卸合一，动作随任务状态取反）/ `4` 查内存 / `5` 强杀；**托盘入口不在菜单里**（只有 `tray.cmd`）；退出 = 关闭窗口。
- **脚本化数字菜单**：必须 `-Menu` 与 `-MenuInput "2,1,0"` **一起给**（给 `-Menu` 才进菜单分支）；**只给 `-MenuInput` 不带 `-Menu` 会落入真守护分支**。`0` 已不在菜单文案里显示，但仍是合法的隐藏退出键（脚本化依赖它，别删）。
- **跑 `tests\tray-mode.ps1` 前确认没有用户自己的托盘在跑**：托盘状态文件是固定路径 `%TEMP%\mf-tray-status.txt`，多实例会互相覆盖心跳、无法区分归属。该测试 2026-10-14 已修复为「检测到外来 `-Tray` 进程即干净 SKIP + 收尾只杀自己起的 pid」——旧版收尾会**无差别 KillTree 所有 -Tray 进程**，实测杀掉过用户的托盘。**别改回无差别清扫**。

## 4. 素材与演示 / 对外口径

- **演示素材在 `trae_projects\memfuse-demo\`**：`capture.ps1` + `shot-window.ps1`（真实截图工具）、`视频脚本.md`、`飞书文档.md`、`shots\`、`draft-silent.mp4`；v1.2.0 成片 `final-v12.mp4`（两幕版 45.2s）/ 三幕版备份 `final-v12-3scenes.mp4` —— 均**决定不发**（2026-10-08）；**配音需用户在 mossland 网页自行生成**（无法访问其登录态）。
- 对外口径 =「**内存临界前的最后防线**」；**禁用「永不死机」**。
- README 战报数字（5 天 64 次终止 / 最低 1.2% / 单次释放 9.3GB）随 README 走，更新时同步口径说明。

## 5. 交付物缺陷记录：v1.3.0 的 `.cmd` 行尾（2026-10-15）

- **现象**：按 §1「发版后必须验收交付物本体」下载 v1.3.0 资产解包——`memory-guard.ps1` 的 CRLF/BOM 都对，但**三个启动器 `memfuse.cmd` / `tray.cmd` / `whitelist.cmd` 在 zip 里是纯 LF**（bare LF = 32 / 18 / 28）。
- **根因**：`.gitattributes` 当时只有 `*.ps1 text eol=crlf`；zip 由 Linux runner 的 `git archive` 构建，`*.cmd` 落回 `* text=auto` 的 LF。`release.yml` 里「.cmd stays a valid batch file」是错误断言（已随修复改写）。
- **危害**：`.cmd` 遇 bare LF 会破坏 label/goto 跳转（dev-lessons E-20）。本机实测 v1.3.0 的 LF 版**侥幸能跑**（label 跳转成功）——属「这次没炸」，不是「没问题」。
- **修复（在 main，不在 v1.3.0 标签里）**：`7170e28` = `.gitattributes` 补 `*.cmd/*.bat eol=crlf` + `release.yml` 新增「zip 验收闸门」（逐文件查 CRLF；含非 ASCII 的 `.ps1` 查 UTF-8 BOM，不过关即失败、不发布）；`864a980` = 闸门判据改精确（只有「含非 ASCII 却无 BOM」才算失效——本地预演抓到的过严条件）。
- **处置（2026-10-15 16:38，按 A 执行）**：`git tag -f -a v1.3.0 864a980 -F <原消息>`（附注标签）+ `git push -f origin v1.3.0` → `release.yml` 重建两次均 success（run `38706964305` / `38707104918`）→ `gh release upload --clobber` 覆盖资产（`memfuse-1.3.0.zip` 61223B；Release 说明未动，仍 1269 字符）。**验收**：新资产三个 `.cmd` 全 CRLF、`.ps1` 行尾/BOM 全过关；从解包目录实跑 `memfuse.cmd -ShowProcMem explorer` 输出正常（中文/口径/保护状态都对）。
- **踩坑备忘**：`git tag -f <tag> <commit>` 默认产出**轻量**标签——本仓库 v1.x 全是附注标签，移标签要用 `git tag -f -a`（本次先移错、已返工；返工推送多触发一次工作流，`--clobber` 幂等无副作用）。
