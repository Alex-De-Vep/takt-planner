#!/usr/bin/env python3
"""Собирает отдельные приложения для скриншотов. Не запускает приложения или тесты."""
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build' / 'showcase'


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    entitlements = BUILD / 'Showcase.entitlements'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
    log_path = BUILD / 'build.log'
    with log_path.open('w') as log:
        try:
            run('xcodebuild', '-project', ROOT / 'Planner.xcodeproj', '-scheme', 'Planner',
                '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
                '-derivedDataPath', BUILD / 'DerivedData',
                'PRODUCT_BUNDLE_IDENTIFIER=local.planner.Showcase',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG SHOWCASE',
                f'CODE_SIGN_ENTITLEMENTS={entitlements}', 'build', cwd=ROOT,
                stdout=log, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError:
            print(log_path.read_text()[-10000:])
            raise
    source = BUILD / 'DerivedData/Build/Products/Debug/Planner.app'
    for language, appearance in [('ru', 'light'), ('ru', 'dark'), ('en', 'light')]:
        app = BUILD / f'Tasks-{language}-{appearance}.app'
        run('/usr/bin/ditto', source, app)
        info = app / 'Contents/Info.plist'
        metadata = plistlib.loads(info.read_bytes())
        metadata.update(CFBundleIdentifier=f'local.planner.Showcase.{language}.{appearance}',
                        CFBundleName='Tasks Showcase', CFBundleDisplayName='Tasks Showcase',
                        ShowcaseLanguage=language, ShowcaseAppearance=appearance)
        info.write_bytes(plistlib.dumps(metadata))
        run('/usr/bin/codesign', '--force', '--sign', '-', '--entitlements', entitlements, app)
        print(app)
    print('Готово. Данные вымышленные, библиотека и события хранятся только в памяти.')


if __name__ == '__main__':
    main()
