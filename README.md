# Codex Quota

中文 · [English](README.en.md)

在 macOS 菜单栏和桌面小窗查看 Codex 剩余额度。

![Codex Quota 界面](docs/images/codex-quota-preview.png)

## 环境要求

- Apple Silicon（M 系列）Mac，macOS 26 或更新版本。
- 已安装并登录 Codex，放在系统“应用程序”文件夹中。

## 下载与启动（无需编译）

优先在 [Releases](https://github.com/ccpua/codex-quota/releases) 下载 `Codex-Quota-*-arm64.dmg`：

1. 双击 DMG。
2. 将 **Codex Quota.app** 拖到“应用程序”文件夹。
3. 双击 **Codex Quota** 启动，无需安装 Python 或开发工具。

没有 DMG 时，也可以在仓库页面点击 **Code → Download ZIP**，解压后将其中的 app 拖到“应用程序”文件夹。

当前版本尚未经过苹果公证。如果首次打开被提示无法验证开发者，请确认来自本仓库，再到 **系统设置 → 隐私与安全性 → 仍要打开**。[苹果操作说明](https://support.apple.com/zh-cn/102445)

鼠标悬停胶囊查看详情，拖动可调整位置；右键菜单可检查更新，或设置语言、外观和刷新间隔，也可退出程序。

<details>
<summary>可选：从源码安装</summary>

需要 Python 3.8+ 和 Xcode Command Line Tools（运行 `xcode-select --install` 安装）。在项目文件夹中执行：

```sh
zsh build.sh
python3 install.py
open "$HOME/Applications/Codex Quota.app"
```

</details>

[MIT License](LICENSE)
