#!/usr/bin/env python3
"""Проверяет новые инструкции 4-bit на прежних запросах. Результаты старого сравнения не меняет."""
from pathlib import Path
import subprocess,json,re,shutil,uuid,hashlib

ROOT=Path(__file__).resolve().parents[2]
LAB=ROOT/'.build/AssistantReliability'
SCHEMES=ROOT/'Planner.xcodeproj/xcshareddata/xcschemes'


def main():
    LAB.mkdir(parents=True,exist_ok=True)
    run_id=uuid.uuid4().hex
    existing=[LAB/n for n in ['Outputs','round-1.log','round-2.log','summary.json','source-hashes.json'] if (LAB/n).exists()]
    if existing:
        previous=LAB/'History'/run_id;previous.mkdir(parents=True)
        for path in existing:path.rename(previous/path.name)
    files=list((ROOT/'Planner').rglob('*.swift'))+[ROOT/'Planner/Assistant/ModelManifest.json']
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    (LAB/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
    manifest=json.loads((ROOT/'Planner/Assistant/ModelManifest.json').read_text())
    assert manifest['id']=='mlx-community/Qwen3.5-4B-4bit' and manifest['revision']=='0e7ffd5c629ef7719d4cbc04069232580bfa9d9c'
    name=SCHEMES/'PlannerAIReliability.xcscheme'
    assert not name.exists()
    template=(SCHEMES/'PlannerAIModelSmoke4.xcscheme').read_text()
    a=template.index('<EnvironmentVariables>'); b=template.index('</EnvironmentVariables>',a)+len('</EnvironmentVariables>')
    env=f'<EnvironmentVariables><EnvironmentVariable key="PLANNER_QUANT_BENCHMARK" value="4" isEnabled="YES"/><EnvironmentVariable key="PLANNER_QUANT_RUN" value="{run_id}" isEnabled="YES"/><EnvironmentVariable key="PLANNER_RELIABILITY" value="1" isEnabled="YES"/></EnvironmentVariables>'
    name.write_text(template[:a]+env+template[b:])
    try:
        for i in [1,2]:
            log=LAB/f'round-{i}.log'
            print('ROUND',i,log,flush=True)
            with log.open('w') as out:
                result=subprocess.run(['xcodebuild','-project','Planner.xcodeproj','-scheme','PlannerAIReliability','-configuration','Debug',
                    '-destination','platform=macOS,arch=arm64','-derivedDataPath','.build/AIModel4DerivedData',
                    '-clonedSourcePackagesDirPath','.build/SourcePackages','-disableAutomaticPackageResolution','-skipPackagePluginValidation',
                    'PLANNER_EXTRA_SWIFT_FLAGS=SHOWCASE','CODE_SIGN_ENTITLEMENTS=','-only-testing:PlannerTests/AssistantQuantizationBenchmark','test'],
                    cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
            if result.returncode:
                print(log.read_text()[-12000:],flush=True);raise RuntimeError('Harness failed')
            temp=Path(re.search(r'^QUANT OUTPUT_DIR (.+)$',log.read_text(),re.M).group(1))
            assert temp.name=='PlannerQuantizationBenchmark-'+run_id
            shutil.copytree(temp,LAB/'Outputs',dirs_exist_ok=True)
            print('ROUND COMPLETE',i,flush=True)
    finally:
        name.unlink()
        assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==sha for p,sha in hashes.items()), 'Application sources changed during benchmark'



if __name__=='__main__': main()
