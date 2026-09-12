#!/usr/bin/env python3
"""Render README images with the real AppKit views from the current source."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
IMAGE_DIR = ROOT / "docs" / "images"
SOURCES = [
    "main.swift",
    "Preferences.swift",
    "QuotaView.swift",
    "HoverSurface.swift",
    "HoverGeometry.swift",
    "Updater.swift",
    "Preview.swift",
    "CodeActivity.swift",
    "CodeActivityTests.swift",
]


def main() -> None:
    IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="codex-quota-readme-") as temporary:
        work = Path(temporary)
        renderer = work / "preview-renderer"
        subprocess.run(
            [
                "swiftc",
                *SOURCES,
                "-o",
                str(renderer),
                "-framework",
                "AppKit",
                "-lsqlite3",
                "-module-cache-path",
                str(work / "module-cache"),
                "-O",
            ],
            cwd=ROOT,
            check=True,
        )
        for language, suffix in (("zh", ""), ("en", "-en")):
            previews = work / f"previews-{language}"
            subprocess.run(
                [
                    str(renderer),
                    "-displayLanguage",
                    language,
                    "-displayTimeZone",
                    "Asia/Shanghai",
                    "--render-previews",
                    str(previews),
                ],
                cwd=ROOT,
                check=True,
            )
            shutil.copyfile(previews / "dark-dual.png", IMAGE_DIR / f"codex-quota-preview{suffix}.png")
            shutil.copyfile(previews / "dark-normal.png", IMAGE_DIR / f"codex-quota-weekly-only{suffix}.png")

    print(IMAGE_DIR / "codex-quota-preview.png")
    print(IMAGE_DIR / "codex-quota-weekly-only.png")
    print(IMAGE_DIR / "codex-quota-preview-en.png")
    print(IMAGE_DIR / "codex-quota-weekly-only-en.png")


if __name__ == "__main__":
    main()
