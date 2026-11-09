import { requireValue, fail } from './errors.js';
import { uuid } from './security.js';
export type EntityType = 'task'|'folder'|'checklistItem'|'attachment';
export interface Stamp { physicalMillis:number; logicalCounter:number; deviceId:string; operationId:string; }
export interface Field { value:any; version:Stamp; }
export interface Mutation { operationId:string; libraryId:string; deviceId:string; entityId:string; entityType:EntityType; kind:'create'|'update'|'delete'; changes?:Record<string,Field>; deleteVersion?:Stamp; }
export interface Entity { id:string; type:EntityType; fields:Record<string,any>; versions:Record<string,Stamp>; deleted:boolean; revision:string; fileReady?:boolean; }
const types=['task','folder','checklistItem','attachment'];
const keys:Record<EntityType,string[]>={
 task:['title','description','createdAt','completedAt','focusDay','placement','deadline','planning'],
 folder:['name','sortOrder'],checklistItem:['taskId','title','isCompleted','sortOrder'],
 attachment:['taskId','filename','mimeType','size','sha256'],
};
function exactKeys(value:any,allowed:string[]) { requireValue(value && typeof value==='object' && !Array.isArray(value) && Object.keys(value).every(k=>allowed.includes(k))); }
export function compareStamp(a:Stamp,b:Stamp) {
  for (const k of ['physicalMillis','logicalCounter','deviceId','operationId'] as const) { if(a[k]<b[k])return -1;if(a[k]>b[k])return 1; } return 0;
}
function timestamp(v:any) { if(typeof v!=='string'||!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$/.test(v)||!Number.isFinite(Date.parse(v)))return false;const normalized=v.includes('.')?v.replace(/\.(\d+)Z$/,(_m:string,n:string)=>`.${n.padEnd(3,'0')}Z`):v.replace(/Z$/,'.000Z');return new Date(v).toISOString()===normalized; }
function day(v:any) { if(typeof v!=='string'||!/^\d{4}-\d\d-\d\d$/.test(v))return false;const d=new Date(`${v}T00:00:00Z`);return Number.isFinite(d.getTime())&&d.toISOString().slice(0,10)===v; }
function text(v:any,max:number) { return typeof v==='string' && Buffer.byteLength(v)<=max && !v.includes('\0'); }
function stamp(v:any,deviceId:string) {
 exactKeys(v,['physicalMillis','logicalCounter','deviceId','operationId']);
 requireValue(Number.isSafeInteger(v.physicalMillis) && v.physicalMillis>=0 && Number.isSafeInteger(v.logicalCounter) && v.logicalCounter>=0 && v.logicalCounter<=2147483647 && v.deviceId===deviceId && uuid(v.operationId));
 if(v.physicalMillis>Date.now()+300000)fail(409,'clock_skew','Часы устройства опережают сервер. Проверьте время');
}
export function validateValue(type:EntityType,k:string,v:any) {
 requireValue(keys[type].includes(k));
 if(k==='title') requireValue(text(v,16384));
 if(k==='description') requireValue(text(v,1048576));
 if(k==='name') requireValue(text(v,320) && v.trim().length>0 && Array.from(v).length<=80);
 if(k==='filename') requireValue(text(v,1024) && v.length>0 && !/[\r\n]/.test(v));
 if(k==='mimeType') requireValue(text(v,128) && /^[\w.+-]+\/[\w.+-]+$/.test(v));
 if(k==='sortOrder') requireValue(Number.isSafeInteger(v) && v>=0 && v<=2147483647);
 if(k==='taskId') requireValue(uuid(v));
 if(k==='isCompleted') requireValue(typeof v==='boolean');
 if(k==='size') requireValue(Number.isSafeInteger(v) && v>=0 && v<=104857600);
 if(k==='sha256') requireValue(typeof v==='string' && /^[a-f0-9]{64}$/.test(v));
 if(k==='createdAt') requireValue(timestamp(v));
 if(k==='completedAt') requireValue(v===null || timestamp(v));
 if(k==='focusDay') requireValue(v===null || day(v));
 if(k==='placement') {
   exactKeys(v,['kind','folderId']);requireValue(['inbox','week','month','folder'].includes(v.kind));
   requireValue(v.kind==='folder'?uuid(v.folderId):v.folderId===undefined);
 }
 if(k==='deadline' && v!==null) {
   exactKeys(v,['date','instant','includesTime','timeZoneId']);
   requireValue(typeof v.includesTime==='boolean' && typeof v.timeZoneId==='string' && v.timeZoneId.length<=100);
   try { new Intl.DateTimeFormat('en',{timeZone:v.timeZoneId}); } catch { fail(400,'invalid_request','Неверный часовой пояс'); }
   requireValue(v.includesTime?timestamp(v.instant) && v.date===undefined:day(v.date) && v.instant===undefined);
 }
 if(k==='planning' && v!==null) { exactKeys(v,['kind','anchor']);requireValue(['week','month'].includes(v.kind) && timestamp(v.anchor)); }
}
export function validateMutation(v:any,libraryId:string,deviceId:string): asserts v is Mutation {
 exactKeys(v,['operationId','libraryId','deviceId','entityId','entityType','kind','changes','deleteVersion']);
 requireValue(uuid(v.operationId) && uuid(v.entityId) && v.libraryId===libraryId && v.deviceId===deviceId && types.includes(v.entityType) && ['create','update','delete'].includes(v.kind));
 if(v.kind==='delete') { requireValue(v.changes===undefined);stamp(v.deleteVersion,deviceId);return; }
 requireValue(v.deleteVersion===undefined && v.changes && typeof v.changes==='object' && !Array.isArray(v.changes) && Object.keys(v.changes).length>0 && Object.keys(v.changes).length<=keys[v.entityType as EntityType].length);
 for(const [k,f]of Object.entries(v.changes) as [string,any][]) { exactKeys(f,['value','version']);requireValue(Object.hasOwn(f,'value'));stamp(f.version,deviceId);validateValue(v.entityType,k,f.value); }
 if(v.kind==='create') {
   const required:Record<EntityType,string[]>={task:['title','createdAt','placement'],folder:['name','sortOrder'],checklistItem:['taskId','title','isCompleted','sortOrder'],attachment:['taskId','filename','mimeType','size','sha256']};
   requireValue(required[v.entityType as EntityType].every(k=>Object.hasOwn(v.changes,k)));
 }
 if(v.kind==='update') {
   requireValue(!Object.hasOwn(v.changes,'createdAt') && !Object.hasOwn(v.changes,'taskId'));
   if(v.entityType==='attachment')fail(400,'immutable_attachment','Для изменения содержимого добавьте новое вложение');
 }
}
export function canonical(value:any):string {
 if(value===null || typeof value!=='object')return JSON.stringify(value);
 if(Array.isArray(value))return `[${value.map(canonical).join(',')}]`;
 return `{${Object.keys(value).sort().map(k=>`${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
