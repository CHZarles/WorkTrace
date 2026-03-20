# 发布到 GitHub（每次升级去 Releases 拿 exe）

目标：把 Windows 打包流程放到 GitHub Actions。以后你只需要：
- 合并代码到 `main`
- 打一个 tag（例如 `v0.1.1`）
- 等 Actions 跑完
- 去 GitHub Releases 下载 `WorkTrace-<tag>-windows-setup.exe`（推荐安装版）

> 说明：我无法替你“直接上传到你的 GitHub 账号”，但可以把仓库准备好（工作流/文档/脚本），你按下面命令 push 即可。

---

## 1) 创建 GitHub 仓库并 push

在 GitHub 网页创建一个新仓库（建议先用 Private）。

在本地仓库根目录执行（把 URL 换成你自己的）：

```bash
git remote add origin https://github.com/<you>/WorkTrace.git
git branch -M main
git push -u origin main
```

---

## 2) Windows Release 的 GitHub Actions

仓库已包含工作流：`.github/workflows/release-windows.yml`

触发方式：
- 推送 tag：`v*`（例如 `v0.1.1`）→ 自动打包并发布到 GitHub Releases
- 手动触发：Actions → `Release (Windows)` → Run workflow（会产出 Actions artifact）

产物：
- `WorkTrace-<tag>-windows-setup.exe`（推荐）

校验：
- 安装后的应用目录内包含 `build-info.json`（记录 git commit + core/collector 版本 + sha256）

---

## 3) 怎么发一个新版本（推荐流程）

1)（可选）同步版本号（只是展示用，不做强校验）
- `core/recorder_core/Cargo.toml` 的 `version`
- `collectors/windows_collector/Cargo.toml` 的 `version`
- `ui_flutter/template/pubspec.yaml` 的 `version`

2) 提交：
```bash
git add -A
git commit -m "Release v0.1.1"
git push
```

3) 打 tag 并 push（会触发 Release）：
```bash
git tag v0.1.1
git push origin v0.1.1
```

然后去 GitHub → Releases 下载对应安装包（setup）。

---

## 4) Windows 运行注意事项

- 这是未签名的 exe，Windows SmartScreen 可能会提示风险；通常需要“更多信息 → 仍要运行”。
- 安装版默认安装到：
  - `%LOCALAPPDATA%\\Programs\\WorkTrace`
- 数据默认落在：
  - `%LOCALAPPDATA%\\WorkTrace\\recorder-core.db`
  - `%LOCALAPPDATA%\\WorkTrace\\agent-pids.json`

如果本机已有旧的 `%LOCALAPPDATA%\\RecorderPhone`，应用会继续兼容并在可行时迁移到 `WorkTrace` 目录。
- 托盘右键支持 `Open app folder` / `Open data folder`，可直接定位路径。

---

## 5) 应用内自动更新（Windows 打包版）

打包版（setup）内置一个轻量更新器：
- `Settings → Updates` 可手动 `Check` / `Update & restart`
- 默认开启“每 6 小时自动检查一次”（不会自动安装，避免打断）

限制：
- 基于 GitHub Releases（无 token 仅支持 Public 仓库）
- Private 仓库请继续用“手动下载 setup 覆盖安装”的方式升级

---

## 6) 本地打包（手动）

在 Windows PowerShell：

```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\package-windows.ps1 -Installer -InstallProtocol
```

输出：
- `dist\windows\WorkTrace\`（已组装目录）
- `dist\windows\WorkTrace-Setup.exe`
