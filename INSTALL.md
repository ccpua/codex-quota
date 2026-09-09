# Codex Quota：安装与使用指南

适用版本：1.6.0。最后核对：2026-09-09。

这是一个 macOS 菜单栏工具：桌面平时仅显示按钮大小的额度胶囊，鼠标悬停后展开详情。它定时读取当前登录账号的 Codex 额度，由用户独立启动和退出。

**首次使用推荐从源码构建，再运行安装脚本。** 不需要购买 API Key，也不用把登录令牌交给本程序。

## 目录

- [1. 安装前确认](#1-安装前确认)
- [2. 准备开发工具](#2-准备开发工具)
- [3. 获取源码](#3-获取源码)
- [4. 编译和安装](#4-编译和安装)
- [5. 确认安装成功](#5-确认安装成功)
- [6. 日常使用](#6-日常使用)
- [7. 升级](#7-升级)
- [8. 常见问题](#8-常见问题)
- [9. 停用和卸载](#9-停用和卸载)
- [10. 安装位置与数据说明](#10-安装位置与数据说明)
- [11. 给维护者的分发说明](#11-给维护者的分发说明)

## 1. 安装前确认

### 系统兼容性

| 环境 | 当前状态 |
| --- | --- |
| Apple Silicon（M 系列芯片）+ macOS 26 | 已验证的构建与运行环境 |
| 随当前源码提供的现成 `.app` | `arm64`，二进制最低系统版本为 macOS 26.0 |
| 其他 macOS 版本或 Intel Mac | 请在目标机器上从源码构建；尚未完成兼容性验证 |
| Windows / Linux | 不支持，界面依赖 macOS AppKit |

虽然 `Info.plist` 声明了 macOS 13.0，当前 `build.sh` 没有指定编译部署目标，现成二进制的实际最低版本是 **26.0**。不能据此保证它能在 macOS 13、14 或 15 上运行。从源码构建也可能需要适配较旧的工具链或系统。

在“苹果菜单 → 关于本机”中查看系统版本和芯片，也可以运行：

```sh
sw_vers -productVersion
uname -m
```

### Codex 与账号

安装前请先完成以下准备：

1. 安装并登录 Codex 桌面应用，确认能正常使用。
2. 将桌面应用放在系统“应用程序”目录 `/Applications` 中。
3. 确保网络能访问 Codex 服务，以及福利重置预测配置地址 `config-center-1412625299.cos.ap-guangzhou.myqcloud.com`。

如果不确定，可以检查实际存在的应用：

```sh
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' '/Applications/Codex.app/Contents/Info.plist'
```

若安装的名称是 `ChatGPT.app`，把上面路径中的 `Codex.app` 换成 `ChatGPT.app`。提示文件不存在时先核对应用位置。

本工具启动额度查询时，会依次寻找这些可执行文件，使用第一个存在且可执行的文件：

```text
/Applications/ChatGPT.app/Contents/Resources/codex
/Applications/Codex.app/Contents/Resources/codex
/opt/homebrew/bin/codex
/usr/local/bin/codex
```

当前版本不搜索其他自定义目录，也没有路径设置界面。仅使用 CLI 时也必须登录能返回额度信息的账号。

## 2. 准备开发工具

打开 macOS 自带的“终端”，运行：

```sh
xcode-select --install
```

按系统提示安装 **Command Line Tools for Xcode**，等安装完成后再继续。已经安装时，系统可能提示无需重复安装。完整 Xcode 也可以提供这些工具。[Apple 安装说明](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/)

验证工具是否可用：

```sh
xcode-select -p
xcrun swiftc --version
python3 --version
```

本项目需要：

| 工具 | 用途与要求 |
| --- | --- |
| Swift 编译器、macOS SDK | 编译应用；已验证 Apple Swift 6.2.3，更旧工具链尚未验证 |
| Python 3.8 或更高版本 | 运行安装脚本，仅使用标准库 |
| `zsh`、`codesign` | 构建和校验应用 |

不需要安装 Node.js、npm、第三方 Python 包或第三方 Swift 依赖。

如果 `python3` 不存在或版本低于 3.8，请先安装合适的 Python 3，再继续。

## 3. 获取源码

从 GitHub 克隆完整源码：

```sh
git clone https://github.com/ccpua/codex-quota.git
```

建议将项目放到：

```text
~/Github/codex-quota
```

其中 `~` 代表你自己的用户主目录。源码也可以放在其他可写目录，无须沿用作者的用户名或目录。

文件夹中应至少有：

```text
codex-quota/
├── main.swift
├── QuotaView.swift
├── HoverSurface.swift
├── HoverGeometry.swift
├── Preview.swift
├── Info.plist
├── build.sh
├── install.py
├── icon.svg
└── IconRenderer.swift
```

在终端进入项目文件夹：

```sh
cd "$HOME/Github/codex-quota"
```

如果放在其他位置，修改上述路径。也可以在终端输入 `cd `（末尾有空格），把项目文件夹拖进终端，再按回车。

## 4. 编译和安装

### 第一步：编译

在项目目录运行：

```sh
zsh build.sh
```

**确认命令成功结束后再安装。** 编译会生成：

```text
Codex Quota.app
```

看到 `replacing existing signature` 不代表失败，这是构建脚本进行本地签名时的正常输出。若出现编译错误，请先处理，不要继续使用可能残留的旧构建。

构建还会把 `icon.svg` 渲染成 `Codex Quota.app/Contents/Resources/AppIcon.png`，并写入 app 的图标配置。图标是深色额度环与 Codex 火花组合，Finder、Dock 和应用程序文件夹会使用它。

可额外校验构建结果：

```sh
codesign --verify --deep --strict 'Codex Quota.app'
```

校验成功通常没有输出。这里验证的是签名完整性；当前签名属于本地 ad-hoc 签名，不代表 Apple 开发者身份认证或公证。

### 第二步：安装

```sh
python3 install.py
```

从**当前用户正常登录的 Mac 终端**执行即可，不要使用 `sudo`。脚本会自动：

1. 检查新构建及其签名。
2. 如存在旧版本，退出旧额度工具。
3. 将应用安装到当前用户的 `~/Applications`。
4. 停用并删除旧版本遗留的 Codex 启停监听器。
5. 升级时恢复原先正在运行的额度工具；原先已关闭的状态则保留。

如果电脑上安装的是旧版 `Codex 额度.app`，安装脚本会先退出旧进程，再迁移到新的 `Codex Quota.app` 名称。

正常输出类似：

```text
Installed: /Users/你的用户名/Applications/Codex Quota.app
Automatic Codex launch integration: removed
Preserved monitor state: running
```

最后一行也可能显示 `closed or first installation`，这也是正常状态。

### 第三步：打开 Codex Quota

安装后手动打开：

```sh
open "$HOME/Applications/Codex Quota.app"
```

启动或退出 Codex 不会自动启动、关闭或重新打开额度工具。安装完成后不用保留终端窗口。项目源码可以保留用于升级，也可以另行移动。

## 5. 确认安装成功

### 观察界面

| 检查项 | 预期结果 |
| --- | --- |
| 菜单栏 | 显示 `Codex 36%` 一类文字，数值为示例 |
| 桌面胶囊 | 默认 96 × 34 pt，显示剩余百分比和进度环 |
| 悬停 | 稍作停留后平滑展开详情，显示周期、重置时间、福利重置预测和更新时间 |
| 移开鼠标 | 短暂延迟后平滑收起 |
| 刷新 | 点击详情右下角刷新图标后，更新时间更新 |
| 退出额度工具 | 工具独立退出，不会自动重开 |
| 重新启动 Codex | 不影响额度工具的运行状态 |

进行最后一项检查前，请先保存 Codex 中正在进行的工作。

### 检查真实额度连接

```sh
"$HOME/Applications/Codex Quota.app/Contents/MacOS/CodexQuota" --smoke-test
```

测试会临时启动查询进程，完成后自动退出；可能短暂显示额外的菜单栏项。成功示例：

```text
Connected: 本周额度 remaining=36%
```

失败会输出错误提示并返回非零状态。这只是连接测试，不替代正常启动应用。

## 6. 日常使用

福利重置预测在启动时立即请求 COS，此后每 10 分钟独立更新。手动刷新和电脑唤醒也会触发更新；额度刷新间隔设置只影响额度的定时查询。

在右键或“…”菜单选择“外观 / Appearance”可使用跟随系统、Light 或 Dark 模式；选择后胶囊和面板立即切换，设置会保存。选择“语言 / Language → 中文 / English”可立即切换面板语言。选择“时区 / Time zone”可跟随系统或使用指定地区时区；这些设置都无需重启。福利预测原始时间按北京时间解析后转换，包含夏令时和跨日处理。额度重置时间及更新时间同样按所选时区显示。

| 操作 | 结果 |
| --- | --- |
| 拖动胶囊背景 | 调整位置，退出后会保存 |
| 鼠标悬停胶囊 | 约 0.1 秒后平滑展开 |
| 鼠标离开详情 | 约 0.32 秒后平滑收起 |
| 点击图钉 | 切换置顶，并保存设置 |
| 点击“…” | 打开刷新、置顶和退出菜单 |
| 点击“×” | 隐藏整个胶囊；菜单栏仍保留 |
| 左键点击菜单栏额度 | 显示或隐藏胶囊 |
| 右键点击菜单栏额度 | 打开菜单 |
| 菜单选择退出额度工具 | 本次 Codex 会话中保持关闭 |

胶囊上的数字表示**剩余百分比**，不是已消耗百分比，也不是 API 金额余额。若账号返回两个周期，胶囊与菜单栏显示剩余百分比更低的一个，展开后可以同时查看。

数据每 60 秒更新一次；电脑唤醒时也会尝试刷新。显示精度还取决于服务器更新时间。断网时会保留最后读数，并显示“待更新”或警告。额度重置时间使用当前电脑的本地时区。福利重置预测从远程纯文本配置读取，无时区的时间按 `Asia/Shanghai` 解析并缓存最后一次成功结果；预测时间已过时会显示“等待预测更新”。

展开使用弹性伸展和内容错峰浮现，收起时反向聚拢；开启系统“减少动态效果”时即时切换。Codex Quota 独立运行，不受 Codex 启动或退出影响。

## 7. 升级

获取新源码后，进入新版本项目目录，依次运行：

```sh
zsh build.sh
```

确认构建成功，再运行：

```sh
python3 install.py
```

不必先卸载。脚本会替换应用、移除旧版监听器，并尝试在安装失败时恢复旧版本。额度工具原先的运行/关闭状态和用户偏好会保留。

## 8. 常见问题

### 找不到 `build.sh` 或 `install.py`

先运行 `pwd` 和 `ls`，确认终端位于完整项目目录中，而不是项目的上一级目录。不要只复制一个 Swift 文件。

### `swiftc` 不存在，或 `invalid active developer path`

重新检查 `xcode-select -p` 和 `xcrun swiftc --version`，按照第 2 节安装适合当前系统的 Command Line Tools。切换或升级 Xcode 后也可能需要重新选择开发工具路径。

### 提示系统版本不支持，或 `Bad CPU type in executable`

现成 app 只验证了 Apple Silicon、macOS 26 环境。不要仅凭 `Info.plist` 中的版本号判断兼容性；在自己的机器上重新构建，或向维护者索取匹配架构和系统的版本。较旧环境仍可能需要源码适配。

### 提示无法验证开发者或应用受阻

当前构建没有 Developer ID 签名和 Apple 公证。下载到另一台 Mac 后，系统可能阻止打开。

推荐从可信来源取得源码并在本机重新构建。如果选择打开维护者提供的构建，应先确认来源与完整性，再按 macOS“系统设置 → 隐私与安全性”中对应应用的提示操作；不要关闭全局安全保护。详细步骤见 [Apple 官方说明](https://support.apple.com/en-us/102445)。

如果提示“已损坏”或“会损坏电脑”，应停止使用该构建，重新获取可信源码并构建，或联系维护者核查；不要把它当作普通的未知开发者提示直接放行。

### 菜单栏没有显示额度，或显示 `Codex —`

依次检查：

1. 是否已用第 4 节的 `open` 命令启动额度工具。
2. 屏幕菜单栏是否空间不足，或被菜单栏管理工具隐藏。
3. 运行 `--smoke-test` 检查额度查询状态。

### 提示“未找到 Codex”

检查第 1 节列出的四个可执行文件路径。当前程序不会从任意 `PATH`、nvm 目录或自定义路径中寻找 Codex。只把 GUI 应用放在下载目录里也可能找不到。

### 提示“请在 Codex 中登录”或没有额度数据

先在 Codex 完成登录，再点击刷新。仅 API Key 登录不等同于拥有可查询的订阅额度；服务端没有返回数据时，程序不会猜测额度。

如果同时安装了多个 Codex 版本，请注意查询程序按第 1 节的路径顺序选择可执行文件。桌面应用与所选程序的登录环境不一致时，也可能导致查询失败。

### 查询超时或一直显示“待更新”

检查 Codex 是否能正常联网，再点击刷新。请求超时后会保留上次数据并在下次刷新时重试。使用代理时也应检查图形应用能否正常访问网络；终端里的临时环境变量不一定会传给后台应用。

### 需要屏幕录制、辅助功能或 Computer Use 权限吗？

正常查看额度、悬停、拖动和点击自己的窗口，不需要授予屏幕录制、辅助功能或 Codex Computer Use 权限。开发过程中由自动化工具检查界面，可能另需电脑操作权限；那不属于本程序安装要求。

## 9. 停用和卸载

### 暂时退出

右键点击菜单栏额度，选择“退出 Codex Quota”。工具会保持关闭，直到用户再次手动打开。

### 完整卸载

1. 从菜单栏退出额度工具。
2. 在 Finder 前往 `~/Applications`，把 **`Codex Quota.app`** 移到废纸篓。
3. 源码目录和其中的 `build-cache`、构建产物可以按需保留或移到废纸篓。

应用位置和置顶等偏好可以保留。如果还想清除它们，在额度工具退出后运行：

```sh
defaults delete local.ming.codexquota
```

提示域不存在表示没有对应偏好可清除。卸载本工具不需要修改 Codex 的登录信息或删除 `~/.codex`。

## 10. 安装位置与数据说明

| 位置或设置 | 用途 |
| --- | --- |
| `~/Applications/Codex Quota.app` | 安装后的独立额度程序 |
| 偏好域 `local.ming.codexquota` | 置顶与胶囊位置 |
| 项目目录中的 `build-cache/` | 编译缓存，可重新生成 |
| 项目目录中的 `qa/hover-previews/` | 手动运行预览命令生成的模拟界面图片 |

本工具启动本机 `codex app-server`，通过 `account/rateLimits/read` 读取额度。登录凭据及其刷新由 Codex 管理；本工具源码不直接读取、保存或要求粘贴令牌，不启动模型对话，不自动使用额度重置券。

## 11. 给维护者的分发说明

分享给别人时，推荐发送完整源码包，包含本指南、README、全部 Swift 文件、`Info.plist`、`build.sh`、`install.py`、`icon.svg` 和 `IconRenderer.swift`。可以排除 `build-cache/`、预览图片与 `.app` 构建产物。

如果分发预编译 `.app`，还应提供 `install.py` 并保持它与 app 位于同一目录，明确测试过的芯片和 macOS 版本。使用这种包时，接收者可以跳过编译，进入包目录运行 `python3 install.py`；仍需兼容的 Python、登录后的桌面会话、可用的 Codex，以及通过系统的应用打开检查。

应用采用独立手动启动方式；安装脚本不会注册随 Codex 启停的后台监听器。

构建脚本目前生成本机架构版本，不是 Universal 应用，也不执行 Developer ID 签名或公证。正式公开发布前，应分别验证目标系统和架构，并完善对应分发流程。

胶囊及面板非按钮区域可直接按住拖动。

刷新间隔：点击详情面板的“…” → “刷新间隔…”，可设置 10–3600 秒，默认 60 秒。保存后立即刷新一次并重设定时器；设置会保留到下次启动。手动刷新、唤醒刷新和服务端额度更新通知仍可提前触发查询。
