# Codex Quota

中文 · [English](README.en.md)

在 macOS 菜单栏和桌面小窗查看 Codex 剩余额度。

![Codex Quota 界面](docs/images/codex-quota-preview.png)

## 环境要求

- Mac：已验证 Apple Silicon（M 系列）+ macOS 26，其他配置暂未验证。
- 已安装并登录 Codex，放在系统“应用程序”文件夹中。
- Python 3.8+ 和 Xcode Command Line Tools（用于安装）。

没有 Command Line Tools 时，在终端执行并等待安装完成：

```sh
xcode-select --install
```

## 安装与启动

下载本项目源码并解压，在项目文件夹中打开终端，依次执行：

```sh
zsh build.sh
python3 install.py
open "$HOME/Applications/Codex Quota.app"
```

以后直接双击 `~/Applications/Codex Quota.app` 即可启动。

鼠标悬停胶囊查看详情，拖动可调整位置；右键菜单可设置语言、外观和刷新间隔，也可退出程序。

[MIT License](LICENSE)
