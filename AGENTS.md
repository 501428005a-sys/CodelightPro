# AGENTS.md

给在本仓库工作的 AI 编码助手（Claude Code、Codex 等）的说明。用户文档见 [README.md](README.md)。

## 项目是什么

CodelightPro 是一个 macOS 菜单栏 + 悬浮面板应用（SwiftPM 可执行目标，没有 Xcode 工程），实时显示本机 **Codex** 与 **Claude Code** 的状态（工作中 / 需审批 / 完成 / 空闲 / 出错）和用量额度。可选地把状态上报到 relay，再推送到 iPhone 上的 Codelight App（iPhone App 与 relay 不在本仓库）。

## 常用命令

```bash
swift build                      # 快速编译检查（改完 Swift 代码至少跑这个）
bash scripts/make_app.sh         # release 编译 + 打包 CodelightPro.app（含图标、Info.plist、ad-hoc 签名）
bash scripts/make_app.sh debug   # debug 配置打包
bash scripts/make_release.sh     # 通用包（arm64 + x86_64）→ dist/CodelightPro-<版本>.zip
open CodelightPro.app            # 运行；重新运行前先退出旧实例：
pkill -f CodelightPro.app/Contents/MacOS/CodelightPro
```

- 没有单元测试。验证方式：`swift build` 通过 + 打包运行 app 实际看效果。
- App 偏好存在 `UserDefaults` 域 `com.codelightpro.app`（`swift run` 时域名不同）。调试时可用 `defaults read/write com.codelightpro.app …`，改完记得恢复。
- 部署目标 macOS 13，Swift 5.9；只链接系统框架 + `sqlite3`，不要引入第三方 Swift 依赖。

## 目录结构

```
Sources/CodelightPro/
  main.swift            入口：.accessory 应用（无 Dock 图标）
  AppDelegate.swift     窗口控制器：StripPanel 面板、菜单栏控制中心、显示模式（灵动岛/悬浮窗）、
                        自动隐藏、鼠标离开自动收起、手机配对
  AppModel.swift        全局 ObservableObject：状态 + UserDefaults 持久化的偏好 + on* 回调
  Poller.swift          每 2 秒轮询各 Monitor，写入 AppModel，并通过 StatusSyncClient 上报
  Models/               AgentStatus、DisplayMode/IslandMetrics、配对模型
  Monitors/             读取 ~/.codex、~/.claude；Claude 官方用量 API；Claude Code / Codex hooks 安装；授权
  Services/             relay 同步客户端、开机自启动（SMAppService）、音效
  UI/                   SwiftUI 视图：RootView 按模式分发到悬浮窗 / IslandView；ExpandedView 详情；
                        ActivityGlow 光圈；PixelCat 像素猫；Theme 颜色
scripts/                打包、发布、图标渲染、Claude token 设置
docs/assets/            README 用的图标和 GIF（来自真实运行的 App 录屏）
```

## 架构要点

- **数据流**：`Monitors` → `Poller` → `AppModel`（`@Published`）→ SwiftUI 视图；`AppModel` 通过 `onExpandChange`、`onDisplayModeSettingChange` 等闭包回调通知 `AppDelegate` 做窗口层面的事。视图不直接操作窗口。
- **显示模式**：`AppModel.displayMode` 只由 `AppDelegate` 修改（`morph` 结束时），不要在别处直接改。规则：
  - 没有自动切换：模式只随拖动改变。悬浮窗拖到屏幕顶部中间松手 → 灵动岛；按住灵动岛移动超过 4pt → 变回悬浮窗并跟随鼠标（不足 4pt 算点击展开）。模式存 `display.mode`，灵动岛所在屏幕存 `display.screen`。
  - 两种模式之间的过渡由 `AppDelegate.morph(to:shell:on:)` + `PanelMorphView` 完成：先无动画地把窗口扩到能容纳起止两个外壳，再用 SwiftUI spring 动画外壳的位置、尺寸、圆角（`PanelShellShape`），结束后换回稳态视图。展开 / 收起同理：窗口尺寸变化必须放在动画事务之外（见 `toggleExpanded()`），否则内容会从中心展开。
  - 灵动岛尺寸来自 `IslandMetrics(screen:)`（刘海宽高取自 `safeAreaInsets` / `auxiliaryTopLeft/RightArea`）。窗口顶边贴屏幕顶，层级在菜单栏之上；`StripPanel` 重写了 `constrainFrameRect` 以允许这样放置。
- **Claude 状态**：`ClaudeHookInstaller` 会在 `~/.claude/settings.json` 里安装只追加一行状态的 hooks（会先备份原文件）；状态与缓存文件在 `~/.codelightpro/`（`claude-status`、`events`、`token` 等）。
- **审批**：`ApprovalHooks.swift` 里的 `PermissionRequest` hook（`~/.codelightpro/approve.sh`）Claude Code 与 Codex 共用，只转发用户在面板 / 手机上做的决定；没有回应时什么也不输出，交回 Agent 自己的提示。不要让它自行做决定。
- **relay 契约**：`StatusSyncClient` 上报的载荷由线上 relay 和 iPhone App 读取，改 `AgentStatus` 字段或载荷结构要保持向后兼容。

## 约定

- **语言**：界面文案用中文；代码注释、标识符、提交信息用英文。注释风格参照现有代码：`///` 说明“为什么”，不写显而易见的内容。
- **并发**：UI 相关类型标 `@MainActor`；磁盘 / 网络工作放到后台（参考 `ClaudeHookInstaller` 在 utility 队列上运行）。
- **动画性能**：常驻动画（光圈、像素猫）用 Core Animation 在渲染服务器里跑，不要改回 SwiftUI 逐帧重绘 —— 这是刻意做的性能优化（见 `ActivityGlow.swift`、`PixelCat.swift` 顶部注释）。
- **颜色**：统一用 `Theme` 里的常量和 `Theme.color(_:)`、`Theme.glowColor(_:)` 等函数，不要在视图里写死新颜色。
- **偏好设置**：新增开关时加到 `AppModel`（`@Published` + `didSet` 写 `UserDefaults`，key 用 `area.name` 形式，如 `sound.enabled`），并同时出现在齿轮设置弹窗（`ExpandedView.swift` 的 `SettingsPopover`）和菜单栏控制中心（`AppDelegate.makeControlCenterMenu`）。
- **安全**：不要打印或上报 token、cookie、session key；`~/.codelightpro/token` 权限保持 600。不要提交 `.env` 或 `.p8` 密钥。
