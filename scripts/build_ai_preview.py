#!/usr/bin/env python3
"""Собирает изолированный AI Preview для Mac M1+ и проверяет установочный образ."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build'
DIST = ROOT / 'dist'
DERIVED = BUILD / 'AIReleaseDerivedData'
APP_NAME = 'Задачи AI Preview.app'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def verify(app):
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert metadata['CFBundleIdentifier'] == 'local.planner.AIPreview'
    assert metadata['CFBundleDisplayName'] == 'Задачи AI Preview'
    executable = app / 'Contents/MacOS' / metadata['CFBundleExecutable']
    architectures = run('/usr/bin/lipo', '-archs', executable, capture_output=True, text=True).stdout.strip()
    assert architectures == 'arm64', architectures
    resources = app / 'Contents/Resources'
    assert (resources / 'ModelManifest.json').exists()
    assert list(resources.glob('*.bundle')), 'Отсутствуют ресурсы Swift-пакетов'
    assert list(resources.rglob('*.metallib')), 'Отсутствует скомпилированная библиотека Metal'
    assert not list(app.rglob('*.safetensors')), 'Веса должны скачиваться отдельно'
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    signed = run('/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', app, capture_output=True)
    entitlements = plistlib.loads(signed.stdout)
    assert entitlements['com.apple.security.network.client']
    assert entitlements['com.apple.security.app-sandbox']
    assert not entitlements.get('com.apple.security.get-task-allow', False)
    return metadata


def main():
    BUILD.mkdir(exist_ok=True); DIST.mkdir(exist_ok=True)
    with (BUILD / 'ai-release-build.log').open('w') as log:
        try:
            run('xcodebuild', '-project', ROOT / 'Planner.xcodeproj', '-scheme', 'Planner', '-configuration', 'Release',
                '-destination', 'generic/platform=macOS', '-derivedDataPath', DERIVED,
                '-clonedSourcePackagesDirPath', BUILD / 'SourcePackages', '-disableAutomaticPackageResolution',
                '-skipPackagePluginValidation', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'build', cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print((BUILD / 'ai-release-build.log').read_text()[-12000:]); raise
    with tempfile.TemporaryDirectory(prefix='ai-release-', dir=BUILD) as tmp:
        stage = Path(tmp) / 'image'; stage.mkdir()
        app = stage / APP_NAME
        run('/usr/bin/ditto', DERIVED / 'Build/Products/Release/Planner.app', app)
        info_path = app / 'Contents/Info.plist'
        metadata = plistlib.loads(info_path.read_bytes())
        metadata['CFBundleDisplayName'] = metadata['CFBundleName'] = 'Задачи AI Preview'
        info_path.write_bytes(plistlib.dumps(metadata))
        for name in ('LICENSE', 'NOTICE'):
            shutil.copy2(ROOT / name, app / 'Contents/Resources' / name)
            shutil.copy2(ROOT / name, stage / name)
        # Уведомления об авторстве всех включённых Swift-пакетов и их зависимостей.
        notices = []
        for checkout in sorted((BUILD / 'SourcePackages/checkouts').iterdir()):
            for license_file in checkout.glob('LICENSE*'):
                if license_file.is_file(): notices.append(checkout.name + '\n' + license_file.read_text(errors='replace'))
        (app / 'Contents/Resources/ThirdPartyLicenses.txt').write_text('\n\n'.join(notices))
        run('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--options', 'runtime',
            '--entitlements', ROOT / 'Planner/Planner.entitlements', '--generate-entitlement-der', app)
        metadata = verify(app)
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (stage / 'Прочитайте перед установкой.txt').write_text(
            'Задачи AI Preview — экспериментальная сборка\n\n'
            'Требуется Mac с Apple M1 или новее и macOS 26+. Только arm64.\n'
            'Перетащите приложение в Программы. Основную версию заменять не нужно.\n'
            'Это отдельная пустая библиотека; рабочие задачи не импортируются автоматически.\n'
            'Откройте кнопку чата в шапке и нажмите «Скачать и включить». Загрузка модели — около 3,06 GB.\n'
            'Модель работает локально. Перед созданием задач и событий проверьте предложения.\n'
            'При разрешении EventKit события сохраняются в настоящие системные календари.\n'
            'Сборка подписана ad-hoc, без Developer ID и нотариализации.\n', encoding='utf-8')
        image = Path(tmp) / ('Tasks-AI-Preview-' + metadata['CFBundleShortVersionString'] + '-macOS-arm64.dmg')
        run('/usr/bin/hdiutil', 'create', '-volname', 'Задачи AI Preview', '-srcfolder', stage, '-format', 'UDZO', image)
        run('/usr/bin/hdiutil', 'verify', image)
        mount = Path(tmp) / 'mounted'; mount.mkdir()
        run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, image)
        try: verify(mount / APP_NAME)
        finally: run('/usr/bin/hdiutil', 'detach', mount)
        destination = DIST / APP_NAME
        if destination.exists(): shutil.rmtree(destination)
        run('/usr/bin/ditto', app, destination)
        output = DIST / image.name; image.replace(output)
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        output.with_suffix('.dmg.sha256').write_text(f'{digest}  {output.name}\n')
        print(f'Готово: {output}')


if __name__ == '__main__':
    main()
