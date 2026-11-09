#!/usr/bin/env python3
"""Сравнение новых инструкций и правил с сохранённой базовой проверкой 4-bit."""
from pathlib import Path
from statistics import median,mean
import json

ROOT=Path(__file__).resolve().parents[2]
LAB=ROOT/'.build/AssistantReliability'


def main():
    reports=[json.loads(p.read_text()) for p in (LAB/'Outputs/Results').glob('*.json')]
    assert len(reports)==2
    reports.sort(key=lambda d:d['startedAt'])
    assert all(r['bits']=='4' and len(r['records'])==26 for r in reports)
    baseline=json.loads((ROOT/'Experiments/QuantizationBenchmark/results/summary.json').read_text())['summary']['4']
    data=[c for r in reports for c in r['records']]
    known=[c for c in data if not c['id'].startswith('heldout-')]
    heldout=[c for c in data if c['id'].startswith('heldout-')]
    result={
        'revision':reports[0]['revision'],'requests':len(data),'passed':sum(not c['issues'] for c in data),
        'known_requests':len(known),'known_passed':sum(not c['issues'] for c in known),
        'heldout_requests':len(heldout),'heldout_passed':sum(not c['issues'] for c in heldout),
        'baseline_known_passed':baseline['passed'],'baseline_known_requests':baseline['requests'],
        'response_seconds_median_known':median(c['seconds'] for c in known),
        'baseline_response_seconds_median':baseline['response_seconds_median'],
        'response_seconds_mean_known':mean(c['seconds'] for c in known),
        'loaded_active_bytes':median(r['loadedActive'] for r in reports),
        'loaded_footprint_bytes':median(r['loadedFootprint'] for r in reports),
        'peak_active_bytes':max(c['activePeak'] for c in data),
        'peak_footprint_bytes':max(c['physicalPeak'] for c in data),
        'unloaded_active_bytes_max':max(r['unloadedActive'] for r in reports),
        'unloaded_footprint_bytes':median(r['unloadedFootprint'] for r in reports),
        'round_passed':[sum(not c['issues'] for c in r['records']) for r in reports],
        'failed':[{'id':c['id'],'issues':c['issues'],'raw':c['raw']} for c in data if c['issues']],
    }
    (LAB/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
