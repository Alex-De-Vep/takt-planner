#!/usr/bin/env python3
"""Собирает локальный релиз «Задачи» и DMG без запуска приложения или тестов."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
DERIVED = BUILD / "ReleaseDerivedData"
DIST = ROOT / "dist"
APP_NAME = "Задачи.app"


def run(*args, **kwargs):
    return subprocess.run([str(value) for value in args], check=True, **kwargs)


def info(app):
    with (app / "Contents/Info.plist").open("rb") as source:
        return plistlib.load(source)


def verify_app(app):
    metadata = info(app)
    assert metadata["CFBundleIdentifier"] == "local.planner.Planner"
    assert metadata["CFBundleDisplayName"] == metadata["CFBundleName"] == "Задачи"
    resources = app / "Contents/Resources"
    for name in ("LICENSE", "NOTICE"):
        assert (resources / name).read_bytes() == (ROOT / name).read_bytes()
    icon = resources / metadata["CFBundleIconFile"]
    if icon.suffix != ".icns":
        icon = icon.with_suffix(".icns")
    assert icon.is_file() and icon.stat().st_size > 0, "Не найдена иконка приложения"
    for language, name in [("ru", "Задачи"), ("en", "Tasks")]:
        localized = run("/usr/bin/plutil", "-convert", "json", "-o", "-",
                        resources / f"{language}.lproj/InfoPlist.strings", capture_output=True)
        assert json.loads(localized.stdout)["CFBundleDisplayName"] == name
    executable = app / "Contents/MacOS" / metadata["CFBundleExecutable"]
    run("/usr/bin/lipo", executable, "-verify_arch", "arm64", "x86_64")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    signed_entitlements = run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app, capture_output=True)
    entitlements = plistlib.loads(signed_entitlements.stdout)
    assert entitlements["com.apple.security.app-sandbox"] is True
    assert entitlements["com.apple.security.network.client"] is True
    assert entitlements["com.apple.security.personal-information.calendars"] is True
    assert not entitlements.get("com.apple.security.get-task-allow", False)
    assert not any(key.startswith("com.apple.security.temporary-exception") for key in entitlements)
    assert not (app / "Contents/PlugIns").exists(), "В релиз не должны попадать тестовые пакеты"
    return metadata


def main():
    BUILD.mkdir(exist_ok=True)
    DIST.mkdir(exist_ok=True)
    log_path = BUILD / "release-build.log"
    print("Сборка Release для Apple Silicon и Intel…", flush=True)
    with log_path.open("w") as log:
        try:
            run("xcodebuild", "-project", ROOT / "Planner.xcodeproj", "-scheme", "Planner",
                "-configuration", "Release", "-destination", "generic/platform=macOS",
                "-derivedDataPath", DERIVED, "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
                "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "build",
                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print(log_path.read_text()[-12000:])
            raise

    with tempfile.TemporaryDirectory(prefix="release-", dir=BUILD) as temporary:
        work = Path(temporary)
        stage = work / "image"
        stage.mkdir()
        app = stage / APP_NAME
        run("/usr/bin/ditto", DERIVED / "Build/Products/Release/Planner.app", app)
        metadata = info(app)
        # Имя устанавливаемого пакета и резервное системное имя — «Задачи».
        # Внутренний executable и bundle ID остаются прежними: библиотека пользователя сохраняется.
        metadata["CFBundleName"] = metadata["CFBundleDisplayName"] = "Задачи"
        with (app / "Contents/Info.plist").open("wb") as destination:
            plistlib.dump(metadata, destination)

        # Условия Apache 2.0 сопровождают исходники, приложение и установочный образ.
        for name in ("LICENSE", "NOTICE"):
            shutil.copy2(ROOT / name, app / "Contents/Resources" / name)
            shutil.copy2(ROOT / name, stage / name)

        # Локальная ad-hoc подпись не является Developer ID и не заменяет нотариализацию Apple.
        # Подписываем после изменения метаданных, с релизными правами без отладочных исключений.
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime",
            "--entitlements", ROOT / "Planner/Planner.entitlements", "--generate-entitlement-der", app)
        metadata = verify_app(app)
        version = metadata["CFBundleShortVersionString"]
        minimum_system = metadata["LSMinimumSystemVersion"]
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        (stage / "Установка.txt").write_text(
            f"Задачи {version}\n\n"
            "Перетащите «Задачи» в папку Applications («Программы»).\n"
            "Затем извлеките образ диска и откройте приложение из «Программ».\n\n"
            f"Требуется macOS {minimum_system} или новее. Apple Silicon и Intel.\n"
            "Название в русской системе — «Задачи», в английской — Tasks.\n"
            "Идентификатор приложения сохранён; используется существующая локальная библиотека.\n\n"
            "Это локальная сборка с ad-hoc подписью, без Developer ID и нотариализации Apple.\n"
            "Для распространения подписанного релиза потребуется сертификат Developer ID.\n",
            encoding="utf-8")

        # Проверяем временный образ, а готовый файл заменяем только после успешной проверки.
        image = work / f"Tasks-{version}-macOS-universal.dmg"
        run("/usr/bin/hdiutil", "create", "-volname", "Задачи", "-srcfolder", stage,
            "-format", "UDZO", "-fs", "HFS+", image)
        run("/usr/bin/hdiutil", "verify", image)
        mount = work / "mounted"
        mount.mkdir()
        run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image)
        try:
            verify_app(mount / APP_NAME)
            for name in ("LICENSE", "NOTICE"):
                assert (mount / name).read_bytes() == (ROOT / name).read_bytes()
            assert (mount / "Applications").readlink() == Path("/Applications")
        finally:
            run("/usr/bin/hdiutil", "detach", mount)

        installed_app = DIST / APP_NAME
        if installed_app.exists():
            shutil.rmtree(installed_app)
        run("/usr/bin/ditto", app, installed_app)
        result = DIST / image.name
        image.replace(result)
        digest = hashlib.sha256(result.read_bytes()).hexdigest()
        result.with_suffix(".dmg.sha256").write_text(f"{digest}  {result.name}\n")
        print(f"Готово: {result}\nПриложение: {installed_app}\nЖурнал: {log_path}", flush=True)


if __name__ == "__main__":
    main()
