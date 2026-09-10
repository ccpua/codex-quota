# Codex Quota

[中文](README.md) · English

View your remaining Codex quota in the macOS menu bar and a floating desktop widget.

![Codex Quota interface](docs/images/codex-quota-preview.png)

## Requirements

- Mac: tested on Apple Silicon (M-series) with macOS 26. Other configurations have not been verified.
- Codex installed in the system Applications folder, with your account signed in.
- Python 3.8+ and Xcode Command Line Tools (for installation).

If Command Line Tools are not installed, run this in Terminal and wait for installation to finish:

```sh
xcode-select --install
```

## Install and launch

Download and extract this project's source code. Open Terminal in the project folder and run:

```sh
zsh build.sh
python3 install.py
open "$HOME/Applications/Codex Quota.app"
```

After installation, double-click `~/Applications/Codex Quota.app` to launch it.

Hover over the capsule to see details, or drag it to move. Right-click to change the language, appearance, or refresh interval, or to quit.

[MIT License](LICENSE)
