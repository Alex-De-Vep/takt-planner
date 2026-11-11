#!/usr/bin/env python3
"""ABBA-сравнение в отдельных процессах. Приложение, настройки и манифест рабочей модели не меняются."""
from pathlib import Path
import hashlib
import json
import subprocess
import re
import shutil
import uuid

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / '.build/QuantizationBenchmark'
SCHEMES = ROOT / 'Planner.xcodeproj/xcshareddata/xcschemes'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    LAB.mkdir(parents=True, exist_ok=True)
    runtime = list((ROOT / 'Planner').rglob('*.swift')) + [ROOT / 'Planner/Assistant/ModelManifest.json']
    baseline = {str(p.relative_to(ROOT)): digest(p) for p in runtime}
    (LAB / 'runtime-baseline.json').write_text(json.dumps(baseline, indent=2))
    manifest = json.loads((ROOT / 'Planner/Assistant/ModelManifest.json').read_text())
    for f in manifest['files']:
        path = ROOT / '.build/ModelCache4' / f['name']
        assert path.stat().st_size == f['bytes'] and digest(path) == f['sha256'], f['name']
    template = (SCHEMES / 'PlannerAIModelSmoke4.xcscheme').read_text()
    generated = []
    run_id = uuid.uuid4().hex
    try:
        for bits in [3, 4]:
            name = SCHEMES / f'PlannerAIQuant{bits}.xcscheme'
            assert not name.exists(), name
            start = template.index('<EnvironmentVariables>')
            end = template.index('</EnvironmentVariables>', start) + len('</EnvironmentVariables>')
            environment = f'<EnvironmentVariables><EnvironmentVariable key="PLANNER_QUANT_BENCHMARK" value="{bits}" isEnabled="YES"/><EnvironmentVariable key="PLANNER_QUANT_RUN" value="{run_id}" isEnabled="YES"/></EnvironmentVariables>'
            name.write_text(template[:start] + environment + template[end:])
            generated.append(name)
        for index, bits in enumerate([4, 3, 3, 4], start=1):
            log = LAB / f'round-{index}-{bits}bit.log'
            print(f'ROUND {index}: {bits}-bit; log {log}', flush=True)
            with log.open('w') as out:
                result = subprocess.run(['xcodebuild', '-project', 'Planner.xcodeproj', '-scheme', f'PlannerAIQuant{bits}',
                    '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
                    '-derivedDataPath', '.build/AIModel4DerivedData', '-clonedSourcePackagesDirPath', '.build/SourcePackages',
                    '-disableAutomaticPackageResolution', '-skipPackagePluginValidation',
                    'PLANNER_EXTRA_SWIFT_FLAGS=SHOWCASE', 'CODE_SIGN_ENTITLEMENTS=',
                    '-only-testing:PlannerTests/AssistantQuantizationBenchmark', 'test'], cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
            if result.returncode:
                print(log.read_text()[-10000:], flush=True)
                raise RuntimeError(f'Benchmark harness failed: {log}')
            output = re.search(r'^QUANT OUTPUT_DIR (.+)$', log.read_text(), re.M)
            assert output, 'No output directory in log'
            temporary = Path(output.group(1))
            assert temporary.name == 'PlannerQuantizationBenchmark-' + run_id
            shutil.copytree(temporary, LAB / 'Outputs', dirs_exist_ok=True)
            print('ROUND COMPLETE', index, flush=True)
    finally:
        for path in generated:
            path.unlink()
        changed = [p for p, sha in baseline.items() if digest(ROOT / p) != sha]
        assert not changed, changed
        print('Runtime sources and production model manifest unchanged.', flush=True)


if __name__ == '__main__':
    main()
