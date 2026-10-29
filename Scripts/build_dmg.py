#!/usr/bin/env python3
"""Create TokenBar Plus's drag-to-Applications disk image on macOS."""

import argparse
import subprocess
from pathlib import Path

import dmgbuild


def verify_copied_app(event: dict[str, object]) -> None:
    """Validate the copied payload before dmgbuild seals the disk image."""
    if event["type"] == "operation::finished" and event.get("operation") == "file::add":
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(event["file"])], check=True)


def main() -> None:
    """Package the supplied app with a fixed Finder installation layout."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Signed TokenBar.app bundle")
    parser.add_argument("--background", required=True, type=Path, help="680 × 440 background PNG")
    parser.add_argument("--output", required=True, type=Path, help="Output .dmg file")
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)

    # Finder 位置与背景使用同一组逻辑坐标，背景以原生元数据嵌入磁盘映像。
    dmgbuild.build_dmg(
        str(output),
        "TokenBar Plus",
        callback=verify_copied_app,
        settings={
            "format": "UDZO",
            "filesystem": "HFS+",
            "compression_level": 9,
            "files": [(str(app), "TokenBar.app")],
            "symlinks": {"应用程序": "/Applications"},
            "icon": str(Path(__file__).resolve().parents[1] / "Resources/AppIcon.icns"),
            "background": str(args.background.resolve()),
            "window_rect": ((120, 120), (680, 540)),
            "icon_size": 96,
            "text_size": 14,
            "icon_locations": {"TokenBar.app": (180, 220), "应用程序": (500, 220)},
            "default_view": "icon-view",
            "include_list_view_settings": False,
            "show_toolbar": False,
            "show_sidebar": False,
            "show_status_bar": False,
            "show_pathbar": False,
            "show_tab_view": False,
        },
    )
    subprocess.run(["codesign", "--force", "--sign", "-", str(output)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(output)], check=True)
    subprocess.run(["hdiutil", "verify", str(output)], check=True)
    print(f"Created {output}")


if __name__ == "__main__":
    main()
