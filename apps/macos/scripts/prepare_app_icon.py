#!/usr/bin/env python3
"""Экспортирует нативную иконку для README и стандартного набора macOS AppIcon."""
from pathlib import Path
import json
import subprocess

MACOS_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = MACOS_ROOT.parents[1]
native = MACOS_ROOT / "Planner/TasksIcon.icon"
design = REPO_ROOT / "Design/AppIcon"
source = design / "tasks-icon.png"
destination = MACOS_ROOT / "Planner/Assets.xcassets/AppIcon.appiconset"
destination.mkdir(parents=True, exist_ok=True)

xcode = Path(subprocess.check_output(["/usr/bin/xcode-select", "-p"], text=True).strip()).parent
composer = xcode / "Applications/Icon Composer.app/Contents/Executables/ictool"
subprocess.run([composer, native, "--export-image", "--output-file", source,
                "--platform", "macOS", "--rendition", "Default", "--width", "1024", "--height", "1024",
                "--scale", "1"], check=True, stdout=subprocess.DEVNULL)


def resize(output: Path, pixels: int) -> None:
    subprocess.run(["/usr/bin/sips", "--resampleHeightWidth", str(pixels), str(pixels),
                    source, "--out", output], check=True, stdout=subprocess.DEVNULL)


resize(design / "tasks-icon-preview.png", 512)
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        filename = f"icon_{points}x{points}@{scale}x.png"
        resize(destination / filename, points * scale)
        images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": filename})
(destination / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print(destination)
