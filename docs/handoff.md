# memfuse 维护者交接（handoff）

> 分工：**README = 用户向**（定位 / 决策机制 / 快速开始 / 战报 / 局限）；**本文 = 维护者向**（发版流程 / 部署状态 / 修改红线 / 回滚）。
> 最近更新：2026-10-09

## 1. 发版流程与节奏

- 仓库：`https://github.com/joker1point/memfuse`；本地 checkout `trae_projects\memfuse\`（当前在 `main`）。
- **push 通道**（本机 hosts 钉 `github.com`、HTTPS 不稳）：`ssh://git@ssh.github.com:443/joker1point/memfuse.git`。
- 流程：feature 分支 PR → merge → tag `vX.Y.Z` → push tag 触发 `release.yml`。
  - **产物由 runner 构建**（本机传不了 `uploads.github.com`）；给老 tag 补挂资产 = `POST /actions/workflows/release.yml/dispatches`。
- **对外更新渠道 = Release 说明 + README**（2026-10-08 用户决定：v1.2.0 更新视频已出片但不发，「没必要发视频，在 github 上说了就好」——**别再催投稿**）。
- B 站节奏（若恢复）：每攒够 3 个用户可见更新发一支更新视频。**当前批次计数 = 1/3**（自 v1.2.1 发布起算）。
- 版本历史速览：
  - `v1.0.0`（原版，tag → `fd507f3`）
  - PR #1 merged（`c567750`：窗口宽限/白名单热加载/`memfuse.cmd`）
  - `v1.2.0`（PR #2 + #3 merged，main = `0e05c8f`：白名单小白化 / 数字菜单 / `-PreferIdle`）
  - PR #4 merged（main = `e79399a`）+ `v1.2.1`：桌面快捷方式（装守护现建、卸载删）
  - **PR #5 open**（`feature/tray`）：托盘模式（`-Tray` / `tray.cmd` / 菜单第 6 项；`tests/tray-mode.ps1` 9/9 ✓）

## 2. 开发机生产守护状态与回滚

- 已于 2026-09-27 **切到新版**：计划任务 args 指向 `trae_projects\memfuse\memory-guard.ps1`，白名单 `trae_projects\memfuse\protect-list.txt`（含 `codebuddy cn`）。
- **回滚路径**：用原版 `frontend-works\tools\memory-guard\memory-guard.ps1`（sha `2140873372AA4A00…`，未改动）→ 跑 `-InstallTask` → 停新实例 → 拉起。
- 2026-10-14 20:19：守护已重启加载 `-ShowProcMem` / `-KillProc` 新版（新 pid 58084，启动时间晚于脚本 mtime，日志有新 `started` 行）；同时清掉一个 10-08 遗留的旧菜单壳（否则在里面按 7/8 不识别）。**该版本尚未提交/发版**——git 工作区有未提交改动（`memory-guard.ps1`、`README.md`、两个新测试），发版前先提交。

## 3. 修改红线

- **守护不会自动更新代码**：脚本在进程启动时读入内存，心跳只在它死后重拉 —— **改完守护代码必须手动重启一次，并用日志证明**（找只存在于新提交的行，如 `close-to-background: armed`）。
- **中文界面的前提 = `.ps1` 带 UTF-8 BOM**（PS 5.1 才正确读中文）；**日志保持英文关键词**（测试套件按英文断言）。
- 测试套件（`tests\`）按英文断言、纯 ASCII 约束运行环境，改文案别动断言依赖的关键词。
- **脚本化数字菜单**：必须 `-Menu` 与 `-MenuInput "2,1,0"` **一起给**（给 `-Menu` 才进菜单分支）；**只给 `-MenuInput` 不带 `-Menu` 会落入真守护分支**。
- **跑 `tests\tray-mode.ps1` 前确认没有用户自己的托盘在跑**：托盘状态文件是固定路径 `%TEMP%\mf-tray-status.txt`，多实例会互相覆盖心跳、无法区分归属。该测试 2026-10-14 已修复为「检测到外来 `-Tray` 进程即干净 SKIP + 收尾只杀自己起的 pid」——旧版收尾会**无差别 KillTree 所有 -Tray 进程**，实测杀掉过用户的托盘。**别改回无差别清扫**。

## 4. 素材与演示 / 对外口径

- **演示素材在 `trae_projects\memfuse-demo\`**：`capture.ps1` + `shot-window.ps1`（真实截图工具）、`视频脚本.md`、`飞书文档.md`、`shots\`、`draft-silent.mp4`；v1.2.0 成片 `final-v12.mp4`（两幕版 45.2s）/ 三幕版备份 `final-v12-3scenes.mp4` —— 均**决定不发**（2026-10-08）；**配音需用户在 mossland 网页自行生成**（无法访问其登录态）。
- 对外口径 =「**内存临界前的最后防线**」；**禁用「永不死机」**。
- README 战报数字（5 天 64 次终止 / 最低 1.2% / 单次释放 9.3GB）随 README 走，更新时同步口径说明。
