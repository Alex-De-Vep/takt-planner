#!/usr/bin/env python3
"""Собирает обновление «Задач» с локальным ИИ для Mac M1+ и проверяет установочный образ."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile

MACOS_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = MACOS_ROOT.parents[1]
BUILD = MACOS_ROOT / '.build'
DIST = REPO_ROOT / 'dist'
DERIVED = BUILD / 'AIReleaseDerivedData'
APP_NAME = 'Задачи.app'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def verify(app):
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert metadata['CFBundleIdentifier'] == 'local.planner.Planner'
    assert metadata['CFBundleDisplayName'] == metadata['CFBundleName'] == 'Задачи'
    assert metadata['CFBundleShortVersionString'] == '0.2.17'
    assert metadata['CFBundleVersion'] == '67'
    assert metadata['LSMinimumSystemVersion'] == '26.0'
    for language, expected in [('ru', 'Задачи'), ('en', 'Tasks')]:
        localized = run('/usr/bin/plutil', '-convert', 'json', '-o', '-',
                        app / 'Contents/Resources' / f'{language}.lproj/InfoPlist.strings', capture_output=True)
        names = json.loads(localized.stdout)
        assert names['CFBundleDisplayName'] == names['CFBundleName'] == expected
    executable = app / 'Contents/MacOS' / metadata['CFBundleExecutable']
    architectures = run('/usr/bin/lipo', '-archs', executable, capture_output=True, text=True).stdout.strip()
    assert architectures == 'arm64', architectures
    resources = app / 'Contents/Resources'
    assert (resources / 'ModelManifest.json').exists()
    for name in ('start.sh', 'bridge.mjs', 'package.json', 'package-lock.json'):
        assert (resources / 'CopilotBridge.bundle' / name).is_file()
    anchor = resources / 'GigaChatTrust.bundle' / 'RussianTrustedRootCA.der'
    assert hashlib.sha256(anchor.read_bytes()).hexdigest() == 'd26d2d0231b7c39f92cc738512ba54103519e4405d68b5bd703e9788ca8ecf31'
    assert metadata['NSAppTransportSecurity']['NSExceptionDomains'] == {
        host: {'NSExceptionAllowsInsecureHTTPLoads': True}
        for host in ('ngw.devices.sberbank.ru', 'api.giga.chat')
    }
    assert list(resources.glob('*.bundle')), 'Отсутствуют ресурсы Swift-пакетов'
    assert list(resources.rglob('*.metallib')), 'Отсутствует скомпилированная библиотека Metal'
    assert not list(app.rglob('*.safetensors')), 'Веса должны скачиваться отдельно'
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    signed = run('/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', app, capture_output=True)
    entitlements = plistlib.loads(signed.stdout)
    assert entitlements['com.apple.security.network.client']
    assert entitlements['com.apple.security.network.server']
    assert entitlements['com.apple.security.app-sandbox']
    assert entitlements['com.apple.security.personal-information.calendars']
    assert not any(k.startswith('com.apple.security.temporary-exception') for k in entitlements)
    assert not entitlements.get('com.apple.security.files.user-selected.read-only', False)
    assert not (app / 'Contents/PlugIns').exists()
    for name in ('LICENSE', 'NOTICE'):
        assert (resources / name).read_bytes() == (REPO_ROOT / name).read_bytes()
    assert not entitlements.get('com.apple.security.get-task-allow', False)
    return metadata


def main():
    # Не допускаем случайную упаковку отдельной Preview или демонстрационной библиотеки как обновления.
    generator = (MACOS_ROOT / 'scripts/generate_project.py').read_text()
    assert 'f"local.planner.{name}"' in generator
    persistence = (MACOS_ROOT / 'Planner/Persistence/PlannerPersistence.swift').read_text()
    assert '.appending(path: "Planner", directoryHint: .isDirectory)' in persistence
    assert 'PlannerAIPreview' not in persistence
    BUILD.mkdir(exist_ok=True); DIST.mkdir(exist_ok=True)
    with (BUILD / 'ai-release-build.log').open('w') as log:
        try:
            run('xcodebuild', '-project', MACOS_ROOT / 'Planner.xcodeproj', '-scheme', 'Planner', '-configuration', 'Release',
                '-destination', 'generic/platform=macOS', '-derivedDataPath', DERIVED,
                '-clonedSourcePackagesDirPath', BUILD / 'SourcePackages', '-disableAutomaticPackageResolution',
                '-skipPackagePluginValidation', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'build', cwd=MACOS_ROOT, stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print((BUILD / 'ai-release-build.log').read_text()[-12000:]); raise
    with tempfile.TemporaryDirectory(prefix='ai-release-', dir=BUILD) as tmp:
        stage = Path(tmp) / 'image'; stage.mkdir()
        app = stage / APP_NAME
        run('/usr/bin/ditto', DERIVED / 'Build/Products/Release/Planner.app', app)
        info_path = app / 'Contents/Info.plist'
        metadata = plistlib.loads(info_path.read_bytes())
        metadata['CFBundleDisplayName'] = metadata['CFBundleName'] = 'Задачи'
        info_path.write_bytes(plistlib.dumps(metadata))
        for name in ('LICENSE', 'NOTICE'):
            shutil.copy2(REPO_ROOT / name, app / 'Contents/Resources' / name)
            shutil.copy2(REPO_ROOT / name, stage / name)
        # Уведомления об авторстве всех включённых Swift-пакетов и их зависимостей.
        notices = []
        for checkout in sorted((BUILD / 'SourcePackages/checkouts').iterdir()):
            for license_file in checkout.glob('LICENSE*'):
                if license_file.is_file(): notices.append(checkout.name + '\n' + license_file.read_text(errors='replace'))
        (app / 'Contents/Resources/ThirdPartyLicenses.txt').write_text('\n\n'.join(notices))
        run('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--options', 'runtime',
            '--entitlements', MACOS_ROOT / 'Planner/Planner.entitlements', '--generate-entitlement-der', app)
        metadata = verify(app)
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (stage / 'Прочитайте перед установкой.txt').write_text(
            'Задачи — обновление с локальным помощником\n\n'
            'Требуется Mac с Apple M1 или новее и macOS 26+. Только arm64.\n'
            'Закройте «Задачи» через ⌘Q, затем замените приложение в Программах.\n'
            'Идентификатор и библиотека прежние: ваши папки, задачи и настройки открываются автоматически.\n'
            'Помощник создаёт задачи и дорабатывает их текст только после подтверждения предложений.\n'
            'Доработка новой задачи меняет черновик: создание остаётся отдельным действием.\n'
            'Отдельная AI Preview и её данные не переносятся в основную библиотеку.\n'
            'Откройте кнопку чата в шапке и нажмите «Скачать и включить». Загрузка модели — около 3,06 GB.\n'
            'Локальная модель работает на Mac. Облачные модели подключаются в настройках помощника.\n'
            'Перед созданием задач и событий проверьте предложения.\n'
            'При разрешении EventKit события сохраняются в настоящие системные календари.\n'
            'Сборка подписана ad-hoc, без Developer ID и нотариализации.\n', encoding='utf-8')
        image = Path(tmp) / ('Tasks-' + metadata['CFBundleShortVersionString'] + '-macOS-arm64.dmg')
        run('/usr/bin/hdiutil', 'create', '-volname', 'Задачи', '-srcfolder', stage, '-format', 'UDZO', image)
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
