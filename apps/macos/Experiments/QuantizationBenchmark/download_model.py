#!/usr/bin/env python3
"""Скачивает только экспериментальную 3-битную модель; рабочие файлы приложения не меняет."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / '.build/QuantizationBenchmark'
MODEL = LAB / 'Models/3bit'
META = LAB / 'model3-metadata.json'
REPO = 'mlx-community/Qwen3.5-4B-3bit'
REVISION = '6a87bc4e52f513d6d68397b844db31a255f3fb19'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for part in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(part)
    return h.hexdigest()


def main():
    LAB.mkdir(parents=True, exist_ok=True)
    subprocess.run(['curl', '-fsSL', '--retry', '3', f'https://huggingface.co/api/models/{REPO}/revision/{REVISION}?blobs=true', '-o', str(META)], check=True)
    metadata = json.loads(META.read_text())
    assert metadata['sha'] == REVISION
    siblings = {f['rfilename']: f for f in metadata['siblings']}
    files = [f['name'] for f in json.loads((ROOT / 'Planner/Assistant/ModelManifest.json').read_text())['files']]
    MODEL.mkdir(parents=True, exist_ok=True)
    manifest = {'id': REPO, 'revision': REVISION, 'files': []}
    for name in files:
        f = siblings[name]
        target = MODEL / name
        expected = f.get('lfs', {}).get('sha256')
        valid = target.exists() and target.stat().st_size == f['size']
        if valid and expected:
            valid = digest(target) == expected
        elif valid:
            data = target.read_bytes()
            valid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == f['blobId']
        if not valid:
            partial = target.with_suffix(target.suffix + '.part')
            print('Downloading', name, f['size'], flush=True)
            subprocess.run(['curl', '-fsSL', '--retry', '3', '--connect-timeout', '30', '--continue-at', '-',
                            f'https://huggingface.co/{REPO}/resolve/{REVISION}/{name}', '-o', str(partial)], check=True)
            assert partial.stat().st_size == f['size'], name
            if expected:
                assert digest(partial) == expected, name
            else:
                data = partial.read_bytes()
                assert hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == f['blobId'], name
            partial.replace(target)
        manifest['files'].append({'name': name, 'bytes': target.stat().st_size, 'sha256': digest(target)})
        print('Verified', name, flush=True)
    (LAB / 'ModelManifest-3bit.json').write_text(json.dumps(manifest, indent=2) + '\n')
    config = json.loads((MODEL / 'config.json').read_text())
    assert config['quantization']['bits'] == 3
    print('Ready:', MODEL, sum(f['bytes'] for f in manifest['files']), flush=True)


if __name__ == '__main__':
    main()
