#!/usr/bin/env python3
"""Package the server for a different Windows computer; never includes local config or data."""
from pathlib import Path
import hashlib,json,shutil,zipfile,tempfile
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'server'
VERSION=json.loads((SOURCE/'package.json').read_text())['version']
DIST=ROOT/'dist'
DIST.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='planner-delivery-',dir=ROOT/'.build') as temporary:
    package=Path(temporary)/f'PlannerServer-{VERSION}'
    app=package/'app'
    app.mkdir(parents=True)
    excluded={'node_modules','dist','data','backups','__pycache__','.env'}
    for path in SOURCE.rglob('*'):
        relative=path.relative_to(SOURCE)
        if any(part in excluded for part in relative.parts) or path.is_symlink():continue
        if path.is_dir():continue
        if path.name.startswith('.env') and path.name!='.env.example':continue
        if path.suffix in {'.log','.pyc'}:continue
        target=app/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
    for name in ['storage-sync-plan.ru.md','windows-server-setup.ru.md']:
        shutil.copy2(ROOT/'docs'/name,app/'docs'/name)
        copied=app/'docs'/name
        copied.write_text(copied.read_text().replace('(../server/docs/UPGRADE-WINDOWS.ru.md)','(UPGRADE-WINDOWS.ru.md)'))
    for name in ['LICENSE','NOTICE']:
        shutil.copy2(ROOT/name,app/name)
    readme=(app/'README.md').read_text().replace('(../docs/windows-server-setup.ru.md)','(docs/windows-server-setup.ru.md)')
    (app/'README.md').write_text(readme)
    (package/'INSTALL-WINDOWS.md').write_text(f'''# Planner Server {VERSION} для Windows

Если уже установлена 0.1.0, сначала прочтите `app/docs/UPGRADE-WINDOWS.ru.md`. Распакуйте новую поставку в отдельную папку и запускайте её `Update-Server.ps1 -InstallRoot C:\\PlannerServer` оттуда. Существующие конфигурация, тома и публичный адрес сохраняются. Перед обновлением нужны отдельный резервный носитель и проверка восстановления.

Для первой установки скопируйте содержимое `app` в `C:\\PlannerServer\\app`, сохранив соседние `config`, `logs` и `backup-staging`. Полная инструкция — `app/README.md`.

Проверьте SHA-256 ZIP по отдельному `.sha256` и файлы по `app/SHA256SUMS.json`. В поставке нет паролей, баз и персональных данных. SMTP-пароль вводится только локально на Windows.

Клиент macOS пока хранит данные локально; его подключение к серверу выполняется следующим этапом.
''')
    files=[]
    for p in sorted(app.rglob('*')):
        if p.is_file():files.append({'path':p.relative_to(app).as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'size':p.stat().st_size})
    (app/'SHA256SUMS.json').write_text(json.dumps({'version':VERSION,'files':files},ensure_ascii=False,indent=2)+'\n')
    result=DIST/f'PlannerServer-{VERSION}-Windows.zip'
    with zipfile.ZipFile(result,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for p in sorted(package.rglob('*')):
            if p.is_file():archive.write(p,p.relative_to(package.parent))
    with zipfile.ZipFile(result) as archive:
        assert archive.testzip() is None
        for f in files:
            content=archive.read(f'PlannerServer-{VERSION}/app/'+f['path'])
            assert hashlib.sha256(content).hexdigest()==f['sha256']
        for name in archive.namelist():
            assert not any(part in {'node_modules','data','backups','.env'} for part in Path(name).parts),name
            assert not name.endswith('server.env'),name
    checksum=hashlib.sha256(result.read_bytes()).hexdigest()
    result.with_suffix('.zip.sha256').write_text(f'{checksum}  {result.name}\n')
    print(f'{result}\n{len(files)} files, {result.stat().st_size} bytes; ZIP and SHA-256 verified')
