#!/usr/bin/env python3
"""Подготавливает стандартные размеры macOS AppIcon из сохранённого оригинала."""
from pathlib import Path
import json
import shutil
import subprocess

MACOS_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = MACOS_ROOT.parents[1]
source = REPO_ROOT / "Design/AppIcon/tasks-icon.png"
destination = MACOS_ROOT / "Planner/Assets.xcassets/AppIcon.appiconset"
destination.mkdir(parents=True, exist_ok=True)

# Меняем только разрешение для упаковки в Xcode; оригинал и прозрачность сохраняются.
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        filename = f"icon_{points}x{points}@{scale}x.png"
        subprocess.run(["/usr/bin/sips", "--resampleHeightWidth", str(pixels), str(pixels),
                        str(source), "--out", str(destination / filename)], check=True, stdout=subprocess.DEVNULL)
        images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": filename})
(destination / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print(destination)

# Tahoe получает собственную композицию, а не вставляет маленький PNG на белую плитку.
# Оригинал не ретушируем: композиция задаёт масштаб и системную маску скругления.
native = MACOS_ROOT / "Planner/TasksIcon.icon"
(native / "Assets").mkdir(parents=True, exist_ok=True)
shutil.copy2(source, native / "Assets/tasks-icon.png")
composition = {
    "fill": {"linear-gradient": ["srgb:0.55,0.25,1,1", "srgb:0.34,0.06,0.9,1"]},
    "groups": [{
        "layers": [{"image-name": "tasks-icon.png", "name": "Tasks",
                    "glass": False,
                    "position": {"scale": 1.27, "translation-in-points": [0, 0]}}],
        "shadow": {"kind": "neutral", "opacity": 0},
        "specular": False,
        "translucency": {"enabled": False, "value": 0}
    }],
    "supported-platforms": {"squares": "shared"}
}
(native / "icon.json").write_text(json.dumps(composition, indent=2) + "\n")
print(native)
