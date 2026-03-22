# Windows（WinUI 3）项目说明

> ⚠️ 旧原型：当前主路径是 `core/`（Rust 本机服务）+ `ui_flutter/`（Flutter UI）+ `collectors/`（采集器）。  
> 这个 WinUI 3 工程仅作为早期验证保留。

> 构建环境要求：Windows 11 + Visual Studio 2022（含 WinUI 3 / Windows App SDK 组件）。
> 本仓库在 Linux 环境下无法编译 WinUI 3（这里只提供工程骨架与代码结构）。

## 打开与运行
- 打开解决方案：`windows/WorkTrace.Windows.sln`
- 运行项目：`WorkTrace.Windows`

## 常见错误：NETSDK1083（win10-arm）
如果你看到类似错误：`RuntimeIdentifier 'win10-arm' is not recognized`：
- 在 VS 顶部把 Solution Platform 切到 **x64**（Intel/AMD 电脑）或 **ARM64**（Windows on ARM 电脑）
- 本项目默认只提供 `x64/ARM64` 平台（不提供 ARM32）

## 本机事件接收（给浏览器扩展用）
- 应用启动后会尝试监听：`http://127.0.0.1:17600`
- 健康检查：GET `http://127.0.0.1:17600/health`
- 上报接口：POST `http://127.0.0.1:17600/event`（schema 见 `schemas/ingest-event.schema.json`）

## Tokens / 主题
- 源：`design-tokens.json`
- WinUI 主题字典：`windows/src/WorkTrace.Windows/Themes/RecorderTheme.xaml`
- `App.xaml` 已合并该资源字典，可直接用 `{ThemeResource BrushBg1}` / `{StaticResource RadiusM}` 等资源。
