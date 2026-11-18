#!/usr/bin/env python3
"""Собирает Takt для Mac с Apple Silicon и проверяет установочный образ."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile

MACOS_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = MACOS_ROOT.parents[1]
BUILD = MACOS_ROOT / '.build'
DIST = REPO_ROOT / 'dist'
DERIVED = BUILD / 'AIReleaseDerivedData'
DISPLAY_NAME = 'Takt'
APP_NAME = f'{DISPLAY_NAME}.app'
WIDGET_ENTITLEMENT = 'com.apple.security.application-groups'
WIDGET_PATH = Path('Contents/PlugIns/TodayWidget.appex')


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def signature_entitlements(bundle):
    signed = run('/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', bundle, capture_output=True)
    return plistlib.loads(signed.stdout)


def apple_team(bundle):
    run('/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple generic', bundle)
    details = run('/usr/bin/codesign', '--display', '--verbose=4', bundle, capture_output=True, text=True)
    match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details.stderr, re.MULTILINE)
    if not match:
        raise ValueError('The signing identity has no Apple Developer Team ID.')
    return match[1]


def widget_app_group(identity):
    if not identity or identity == '-':
        raise ValueError('A DMG with the Today widget requires an Apple signing identity. '
                         'Set PLANNER_RELEASE_SIGNING_IDENTITY or use --without-widget.')
    with tempfile.TemporaryDirectory(prefix='takt-signing-') as directory:
        probe = Path(directory) / 'signature-check'
        shutil.copyfile('/usr/bin/true', probe)
        probe.chmod(0o700)
        run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', probe, capture_output=True)
        return f'{apple_team(probe)}.local.planner.today'


def sign(bundle, source, temporary, identity, group):
    entitlements = plistlib.loads((MACOS_ROOT / source).read_bytes())
    if group:
        entitlements[WIDGET_ENTITLEMENT] = [group]
    else:
        entitlements.pop(WIDGET_ENTITLEMENT, None)
    path = temporary / (bundle.stem + '.entitlements')
    path.write_bytes(plistlib.dumps(entitlements))
    run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', '--options', 'runtime',
        '--entitlements', path, '--generate-entitlement-der', bundle)


def verify(app, widget_group):
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert metadata['CFBundleIdentifier'] == 'local.planner.Planner'
    assert metadata['CFBundleDisplayName'] == metadata['CFBundleName'] == DISPLAY_NAME
    assert metadata['CFBundleShortVersionString'] == '0.3.23'
    assert metadata['CFBundleVersion'] == '107'
    assert metadata['LSMinimumSystemVersion'] == '26.0'
    for language in ('ru', 'en'):
        localized = run('/usr/bin/plutil', '-convert', 'json', '-o', '-',
                        app / 'Contents/Resources' / f'{language}.lproj/InfoPlist.strings', capture_output=True)
        names = json.loads(localized.stdout)
        assert names['CFBundleDisplayName'] == names['CFBundleName'] == DISPLAY_NAME
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
    entitlements = signature_entitlements(app)
    assert entitlements['com.apple.security.network.client']
    assert entitlements['com.apple.security.network.server']
    assert entitlements['com.apple.security.app-sandbox']
    assert entitlements['com.apple.security.personal-information.calendars']
    assert not any(k.startswith('com.apple.security.temporary-exception') for k in entitlements)
    assert not entitlements.get('com.apple.security.files.user-selected.read-only', False)
    if widget_group:
        verify_widget(app, metadata, entitlements, widget_group)
    else:
        assert not (app / WIDGET_PATH).exists()
        assert WIDGET_ENTITLEMENT not in entitlements
        assert 'TaktWidgetAppGroup' not in metadata
    for name in ('LICENSE', 'NOTICE'):
        assert (resources / name).read_bytes() == (REPO_ROOT / name).read_bytes()
    assert not entitlements.get('com.apple.security.get-task-allow', False)
    return metadata


def verify_widget(app, metadata, entitlements, group):
    assert entitlements[WIDGET_ENTITLEMENT] == [group]
    assert metadata['TaktWidgetAppGroup'] == group
    widget = app / WIDGET_PATH
    assert list(widget.parent.glob('*.appex')) == [widget]
    widget_metadata = plistlib.loads((widget / 'Contents/Info.plist').read_bytes())
    assert widget_metadata['CFBundleIdentifier'] == metadata['CFBundleIdentifier'] + '.TodayWidget'
    assert widget_metadata['CFBundleShortVersionString'] == metadata['CFBundleShortVersionString']
    assert widget_metadata['CFBundleVersion'] == metadata['CFBundleVersion']
    assert widget_metadata['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
    assert widget_metadata['TaktWidgetAppGroup'] == group
    assert signature_entitlements(widget) == {
        'com.apple.security.app-sandbox': True,
        WIDGET_ENTITLEMENT: [group],
    }
    team = group.partition('.')[0]
    assert apple_team(app) == apple_team(widget) == team
    widget_binary = widget / 'Contents/MacOS' / widget_metadata['CFBundleExecutable']
    assert run('/usr/bin/lipo', '-archs', widget_binary, capture_output=True, text=True).stdout.strip() == 'arm64'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--without-widget', action='store_true', help='Build a DMG without Today for local testing.')
    args = parser.parse_args()
    identity = os.environ.get('PLANNER_RELEASE_SIGNING_IDENTITY', '-')
    try:
        widget_group = None if args.without_widget else widget_app_group(identity)
    except ValueError as error:
        parser.error(str(error))
    except subprocess.CalledProcessError:
        parser.error('The selected identity could not make a valid Apple signature. '
                     'Check security find-identity -v -p codesigning.')

    # Не допускаем случайную упаковку отдельной Preview или демонстрационной библиотеки как обновления.
    generator = (MACOS_ROOT / 'scripts/generate_project.py').read_text()
    assert '"PLANNER_APP_BUNDLE_IDENTIFIER": "local.planner.Planner"' in generator
    persistence = (MACOS_ROOT / 'Planner/Persistence/PlannerPersistence.swift').read_text()
    assert '.appending(path: "Planner", directoryHint: .isDirectory)' in persistence
    assert 'PlannerAIPreview' not in persistence
    BUILD.mkdir(exist_ok=True); DIST.mkdir(exist_ok=True)
    with (BUILD / 'ai-release-build.log').open('w') as log:
        try:
            run('xcodebuild', '-project', MACOS_ROOT / 'Planner.xcodeproj', '-scheme', 'Planner', '-configuration', 'Release',
                '-destination', 'generic/platform=macOS', '-derivedDataPath', DERIVED,
                '-clonedSourcePackagesDirPath', BUILD / 'SourcePackages', '-disableAutomaticPackageResolution',
                '-skipPackagePluginValidation', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO',
                f'PLANNER_WIDGET_APP_GROUP={widget_group or "group.local.planner.today"}', 'build', cwd=MACOS_ROOT, stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print((BUILD / 'ai-release-build.log').read_text()[-12000:]); raise
    with tempfile.TemporaryDirectory(prefix='ai-release-', dir=BUILD) as tmp:
        stage = Path(tmp) / 'image'; stage.mkdir()
        app = stage / APP_NAME
        run('/usr/bin/ditto', DERIVED / 'Build/Products/Release' / APP_NAME, app)
        info_path = app / 'Contents/Info.plist'
        metadata = plistlib.loads(info_path.read_bytes())
        metadata['CFBundleDisplayName'] = metadata['CFBundleName'] = DISPLAY_NAME
        if not widget_group:
            shutil.rmtree(app / WIDGET_PATH)
            metadata.pop('TaktWidgetAppGroup', None)
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
        if widget_group:
            sign(app / WIDGET_PATH, 'Configuration/TodayWidget.entitlements', Path(tmp), identity, widget_group)
        sign(app, 'Planner/Planner.entitlements', Path(tmp), identity, widget_group)
        metadata = verify(app, widget_group)
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (stage / 'Прочитайте перед установкой.txt').write_text(
            'Takt — обновление с помощником\n\n'
            'Требуется Mac с Apple M1 или новее и macOS 26+. Только arm64.\n'
            'Закройте приложение через ⌘Q, затем замените его в Программах.\n'
            'Если предыдущая версия называется «Задачи», уберите её из Программ после установки Takt.\n'
            'Идентификатор и библиотека прежние: ваши папки, задачи и настройки открываются автоматически.\n'
            'Помощник создаёт задачи и дорабатывает их текст только после подтверждения предложений.\n'
            'Доработка новой задачи меняет черновик: создание остаётся отдельным действием.\n'
            'Отдельная AI Preview и её данные не переносятся в основную библиотеку.\n'
            'Откройте кнопку чата в шапке и нажмите «Скачать и включить». Загрузка модели — около 3,06 GB.\n'
            'Локальная модель работает на Mac. Облачные модели подключаются в настройках помощника.\n'
            'Перед созданием задач и событий проверьте предложения.\n'
            'При разрешении EventKit события сохраняются в настоящие системные календари.\n'
            + ('Сборка подписана ad-hoc и не нотариализована.\n' if identity == '-' else
               'Сборка подписана локальным сертификатом и не нотариализована.\n'), encoding='utf-8')
        suffix = '-macOS-arm64.dmg' if widget_group else '-macOS-arm64-no-widget.dmg'
        image = Path(tmp) / (DISPLAY_NAME + '-' + metadata['CFBundleShortVersionString'] + suffix)
        run('/usr/bin/hdiutil', 'create', '-volname', DISPLAY_NAME, '-srcfolder', stage, '-format', 'UDZO', image)
        run('/usr/bin/hdiutil', 'verify', image)
        mount = Path(tmp) / 'mounted'; mount.mkdir()
        run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, image)
        try: verify(mount / APP_NAME, widget_group)
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
