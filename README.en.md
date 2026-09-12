# Codex Quota

The expanded panel also shows **added, modified and deleted source lines** across locally saved Codex projects, refreshed in the background every 10 seconds.

Counts combine today's non-merge commits (committer time in the selected time zone, across locally available branches) with current uncommitted changes. Uncommitted changes may predate today, so the total is not a strict measure of edits made today. Replacement lines are paired within each diff hunk; remaining lines count as additions or deletions. Shared repositories are deduplicated, registered worktrees are included, and staged/unstaged changes are compared together against HEAD. New, unignored source files are included. Source and test files include blank lines and comments; docs, configuration, binaries and common build/dependency paths are excluded. These are project changes from all authors and tools, not Codex-only output. Hover text marks incomplete results when a directory is unavailable. Discovery uses Codex's local storage and may need updates when its format changes.

After building, run `"Codex Quota.app/Contents/MacOS/CodexQuota" --code-activity-test` for fixture tests or `--code-activity-scan` for a single read-only scan of linked projects.

[中文](README.md) · English

View your remaining Codex quota in the macOS menu bar and a floating desktop widget.

![Codex Quota interface](docs/images/codex-quota-preview-en.png)

## Requirements

- Apple Silicon (M-series) Mac running macOS 26 or later.
- Codex installed in the system Applications folder, with your account signed in.

## Download and launch (no build required)

Download `Codex-Quota-*-arm64.dmg` from [Releases](https://github.com/ccpua/codex-quota/releases):

1. Double-click the DMG.
2. Drag **Codex Quota.app** into your Applications folder.
3. Double-click **Codex Quota** to launch. Python and developer tools are not required.

If a DMG is not available, click **Code → Download ZIP** on this repository's page, extract it, and drag the included app into Applications.

This version has not been notarized by Apple. If macOS blocks the first launch because it cannot verify the developer, confirm that you downloaded it from this repository, then go to **System Settings → Privacy & Security → Open Anyway**. [Apple's instructions](https://support.apple.com/en-us/102445)

Hover over the capsule to see details, or drag it to move. Right-click to check for updates, change the language, appearance, or refresh interval, or quit.

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
