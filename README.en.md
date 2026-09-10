# Codex Quota

[中文](README.md) · English

View your remaining Codex quota in the macOS menu bar and a floating desktop widget.

![Codex Quota interface](docs/images/codex-quota-preview.png)

## Requirements

- Apple Silicon (M-series) Mac running macOS 26 or later.
- Codex installed in the system Applications folder, with your account signed in.

## Download and launch (no build required)

1. Click **Code → Download ZIP** on this repository's page, then extract the download.
2. Drag **Codex Quota.app** into your Applications folder.
3. Double-click **Codex Quota** to launch. Python and developer tools are not required.

This version has not been notarized by Apple. If macOS blocks the first launch because it cannot verify the developer, confirm that you downloaded it from this repository, then go to **System Settings → Privacy & Security → Open Anyway**. [Apple's instructions](https://support.apple.com/en-us/102445)

Hover over the capsule to see details, or drag it to move. Right-click to change the language, appearance, or refresh interval, or to quit.

<details>
<summary>Optional: install from source</summary>

Requires Python 3.8+ and Xcode Command Line Tools (install with `xcode-select --install`). Run these commands in the project folder:

```sh
zsh build.sh
python3 install.py
open "$HOME/Applications/Codex Quota.app"
```

</details>

[MIT License](LICENSE)
