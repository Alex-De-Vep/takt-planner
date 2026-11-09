#!/usr/bin/env python3
"""Сводит результаты без исключения неудачных ответов. Времена включают повтор формата в приложении."""
from pathlib import Path
from statistics import median,mean
import json

ROOT=Path(__file__).resolve().parents[2]
LAB=ROOT/'.build/QuantizationBenchmark'


def main():
    reports=[json.loads(p.read_text()) for p in (LAB/'Outputs/Results').glob('*.json')]
    assert len(reports)==4, f'Expected 4 reports, got {len(reports)}'
    reports.sort(key=lambda r:r['startedAt'])
    assert [r['bits'] for r in reports]==['4','3','3','4']
    summary={}
    def field_issues(record):
        # Лишний вопрос ухудшает диалог, но сам по себе не меняет данные карточки.
        result=[e for e in record['issues'] if e != 'Лишний уточняющий вопрос']
        if record['id']=='correct-proposal':
            tasks=[p for p in (record.get('normalized') or {}).get('actions',[]) if p['kind']=='task']
            if tasks and tasks[0].get('date') is None:
                result=[e for e in result if e != 'Потерян ключ или придуман срок']
        return result
    for bits in ['4','3']:
        group=[r for r in reports if r['bits']==bits]
        records=[c for r in group for c in r['records']]
        summary[bits]={
            'revision':group[0]['revision'], 'requests':len(records),
            'passed':sum(not c['issues'] for c in records),
            'fields_correct':sum(not field_issues(c) for c in records),
            'invalid_json':sum(any('JSON' in e for e in c['issues']) for c in records),
            'load_seconds_median':median(r['loadSeconds'] for r in group),
            'reload_seconds_median':median(r['reloadSeconds'] for r in group),
            'response_seconds_median':median(c['seconds'] for c in records),
            'response_seconds_mean':mean(c['seconds'] for c in records),
            'loaded_active_bytes_median':median(r['loadedActive'] for r in group),
            'loaded_footprint_bytes_median':median(r['loadedFootprint'] for r in group),
            'peak_active_bytes':max(c['activePeak'] for c in records),
            'peak_footprint_bytes':max(c['physicalPeak'] for c in records),
            'unloaded_footprint_bytes_median':median(r['unloadedFootprint'] for r in group),
            'unloaded_active_bytes_max':max(r['unloadedActive'] for r in group),
            'created_tasks':sum(c['tasksCreated'] for c in records),
            'created_events':sum(c['eventsCreated'] for c in records),
            'round_passed':[sum(not c['issues'] for c in r['records']) for r in group],
            'failed_cases':[{**{'round':i+1,'id':c['id'],'issues':c['issues']},'raw':c['raw']} for i,r in enumerate(group) for c in r['records'] if c['issues']],
        }
    ids=[c['id'] for c in reports[0]['records']]
    cases=[]
    common=[]
    common_fields=[]
    for name in ids:
        row={'id':name}
        for bits in ['4','3']:
            items=[c for r in reports if r['bits']==bits for c in r['records'] if c['id']==name]
            row[bits]={'passed':sum(not c['issues'] for c in items),'fields_correct':sum(not field_issues(c) for c in items),'seconds':median(c['seconds'] for c in items),'issues':[c['issues'] for c in items]}
        cases.append(row)
        if row['4']['passed']==2 and row['3']['passed']==2: common.append(row)
        if row['4']['fields_correct']==2 and row['3']['fields_correct']==2: common_fields.append(row)
    result={'summary':summary,'cases':cases,'common_correct_cases':len(common),
            'common_correct_seconds_median':{b:median(c[b]['seconds'] for c in common) if common else None for b in ['4','3']},
            'common_field_correct_cases':len(common_fields),
            'common_field_correct_seconds_median':{b:median(c[b]['seconds'] for c in common_fields) if common_fields else None for b in ['4','3']}}
    (LAB/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    for bits,data in summary.items():
        print(bits+'bit',json.dumps({k:v for k,v in data.items() if k!='failed_cases'},ensure_ascii=False))
        for case in data['failed_cases']: print('FAIL',bits,case['round'],case['id'],case['issues'])
    print('Common correct:',result['common_correct_cases'],result['common_correct_seconds_median'])


if __name__=='__main__': main()
