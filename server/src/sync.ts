import type { FastifyInstance } from 'fastify';
import { randomUUID } from 'node:crypto';
import type { Database,Tx } from './db.js';
import type { Identity,AuthService } from './auth.js';
import { fail,requireValue,ApiError } from './errors.js';
import { canonical,compareStamp,validateMutation,type Mutation,type Entity,type Stamp } from './protocol.js';
import { digest,uuid } from './security.js';
export const emptyFields=(type:string):Record<string,any>=>type==='task'?{description:'',completedAt:null,focusDay:null,deadline:null,planning:null}:{};
export async function lockLibrary(tx:Tx,identity:Identity) {
 const r=await tx.query('SELECT l.* FROM libraries l JOIN users u ON u.id=l.owner_id WHERE l.id=$1 AND l.owner_id=$2 AND u.deleted_at IS NULL FOR UPDATE OF l',[identity.libraryId,identity.userId]);
 if(!r.rowCount)fail(401,'unauthorized','Библиотека недоступна');return r.rows[0];
}
export function entityRow(row:any):Entity {return {id:row.id,type:row.type,fields:row.fields,versions:row.versions,deleted:row.deleted,revision:String(row.revision),...(row.type==='attachment'?{fileReady:!!row.file_ready}:{})};}
export async function readEntity(tx:Tx,lib:string,id:string) {
 const r=await tx.query('SELECT e.*,EXISTS(SELECT 1 FROM attachment_files a WHERE a.library_id=e.library_id AND a.attachment_id=e.id) AS file_ready FROM entities e WHERE e.library_id=$1 AND e.id=$2',[lib,id]);
 return r.rowCount?entityRow(r.rows[0]):null;
}
export async function publish(tx:Tx,lib:string,entity:Entity) {
 const rev=await tx.query('UPDATE libraries SET revision=revision+1 WHERE id=$1 RETURNING revision',[lib]);
 entity.revision=String(rev.rows[0].revision);
 await tx.query(`INSERT INTO entities(library_id,id,type,fields,versions,deleted,revision) VALUES($1,$2,$3,$4,$5,$6,$7)
 ON CONFLICT(library_id,id) DO UPDATE SET fields=EXCLUDED.fields,versions=EXCLUDED.versions,deleted=EXCLUDED.deleted,revision=EXCLUDED.revision,updated_at=now()`,[lib,entity.id,entity.type,JSON.stringify(entity.fields),JSON.stringify(entity.versions),entity.deleted,entity.revision]);
 await tx.query('INSERT INTO changes(library_id,revision,entity) VALUES($1,$2,$3)',[lib,entity.revision,JSON.stringify(entity)]);
 return entity;
}
export async function applyMutation(tx:Tx,identity:Identity,m:Mutation) {
 const fingerprint=digest(canonical(m));
 const previous=await tx.query('SELECT request_hash,result FROM operations WHERE library_id=$1 AND id=$2',[identity.libraryId,m.operationId]);
 if(previous.rowCount) { if(previous.rows[0].request_hash!==fingerprint)fail(409,'operation_reused','Идентификатор операции уже использован');return previous.rows[0].result; }
 const current=await readEntity(tx,identity.libraryId,m.entityId);
 if(current && current.type!==m.entityType)fail(409,'entity_type_mismatch','Идентификатор занят другой сущностью');
 let e:Entity;
 if(current?.deleted) e=current;
 else if(m.kind==='delete') {
   e=current??{id:m.entityId,type:m.entityType,fields:{},versions:{},deleted:false,revision:'0'};
   e.deleted=true;e.versions.deleted=m.deleteVersion!;
   await publish(tx,identity.libraryId,e);
   if(e.type==='task') {
     const children=await tx.query("SELECT * FROM entities WHERE library_id=$1 AND fields->>'taskId'=$2 AND deleted=false",[identity.libraryId,e.id]);
     for(const row of children.rows) {const child=entityRow(row);child.deleted=true;child.versions.deleted=m.deleteVersion!;await publish(tx,identity.libraryId,child);}
   }
   if(e.type==='folder') {
     const children=await tx.query("SELECT * FROM entities WHERE library_id=$1 AND type='task' AND fields->'placement'->>'folderId'=$2 AND deleted=false",[identity.libraryId,e.id]);
     for(const row of children.rows) {const task=entityRow(row);task.fields.placement={kind:'inbox'};await publish(tx,identity.libraryId,task);}
   }
 } else {
   if(!current && m.kind==='update')fail(404,'not_found','Сущность не найдена');
   if(current && m.kind==='create')fail(409,'already_exists','Сущность уже создана');
   e=current??{id:m.entityId,type:m.entityType,fields:emptyFields(m.entityType),versions:{},deleted:false,revision:'0'};
   let changed=!current;
   for(const [key,field]of Object.entries(m.changes!)) {
     if(e.versions[key] && compareStamp(field.version,e.versions[key]!)<=0)continue;
     let value=field.value;
     if(key==='placement' && value.kind==='folder') {
       const folder=await readEntity(tx,identity.libraryId,value.folderId);
       if(!folder || folder.type!=='folder')fail(409,'missing_parent','Сначала синхронизируйте папку');
       if(folder.deleted)value={kind:'inbox'};
     }
     if(key==='taskId') {
       const task=await readEntity(tx,identity.libraryId,value);
       if(!task || task.type!=='task')fail(409,'missing_parent','Сначала синхронизируйте задачу');
       if(task.deleted) {e.deleted=true;e.versions.deleted=task.versions.deleted!;}
     }
     e.fields[key]=value;e.versions[key]=field.version;changed=true;
   }
   if(changed)await publish(tx,identity.libraryId,e);
 }
 const result={operationId:m.operationId,status:e.deleted?'deleted':'applied',entity:e};
 await tx.query('INSERT INTO operations(library_id,id,request_hash,result) VALUES($1,$2,$3,$4)',[identity.libraryId,m.operationId,fingerprint,JSON.stringify(result)]);
 return result;
}
export function installSync(app:FastifyInstance,db:Database,auth:AuthService) {
 app.get('/v1/library',async request=> {const id=await auth.authenticate(request);const r=await db.pool.query('SELECT id,initialized,revision FROM libraries WHERE id=$1',[id.libraryId]);return r.rows[0];});
 app.get('/v1/sync/snapshot',async request=> {
   const id=await auth.authenticate(request);
   return db.tx(async tx=> {
     await tx.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
     const l=await tx.query('SELECT revision,min_cursor,initialized FROM libraries WHERE id=$1',[id.libraryId]);
     const r=await tx.query('SELECT e.*,EXISTS(SELECT 1 FROM attachment_files a WHERE a.library_id=e.library_id AND a.attachment_id=e.id) AS file_ready FROM entities e WHERE e.library_id=$1 ORDER BY e.id',[id.libraryId]);
     return {protocolVersion:1,libraryId:id.libraryId,cursor:String(l.rows[0].revision),initialized:l.rows[0].initialized,entities:r.rows.map(entityRow)};
   });
 });
 app.get('/v1/sync/changes',async request=> {
   const id=await auth.authenticate(request),q=request.query as any;requireValue(typeof q.cursor==='string' && /^\d{1,19}$/.test(q.cursor) && BigInt(q.cursor)<=9223372036854775807n);
   return db.tx(async tx=> {
     await tx.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY');
     const l=(await tx.query('SELECT revision,min_cursor FROM libraries WHERE id=$1',[id.libraryId])).rows[0];
     if(BigInt(q.cursor)<BigInt(l.min_cursor))fail(410,'cursor_expired','Нужен новый снимок библиотеки');
     requireValue(BigInt(q.cursor)<=BigInt(l.revision),'invalid_cursor');
     // Ограничение по числу; размер одного события ограничен входным запросом.
     const r=await tx.query('SELECT revision,entity FROM changes WHERE library_id=$1 AND revision>$2 ORDER BY revision LIMIT 100',[id.libraryId,q.cursor]);
     const next=r.rows.length?String(r.rows.at(-1)!.revision):String(l.revision);
     return {libraryId:id.libraryId,changes:r.rows.map(x=>({revision:String(x.revision),entity:x.entity})),nextCursor:next,hasMore:BigInt(next)<BigInt(l.revision)};
   });
 });
 app.post('/v1/sync/mutations',async request=> {
   const id=await auth.authenticate(request),list=(request.body as any)?.mutations;
   requireValue(Array.isArray(list) && list.length>0 && list.length<=100);
   const results=[];
   for(const m of list) {
     try {
       validateMutation(m,id.libraryId,id.deviceId);
       results.push(await db.tx(async tx=> {const l=await lockLibrary(tx,id);if(!l.initialized)fail(409,'library_not_initialized','Завершите первое подключение');return applyMutation(tx,id,m);},true));
     } catch(error) {
       if(!(error instanceof ApiError) || error.status>=500)throw error;
       results.push({operationId:uuid(m?.operationId)?m.operationId:null,status:'rejected',error:{code:error.code,message:error.message}});
     }
   }return {results};
 });
 app.post('/v1/library/imports',async request=> {
   const id=await auth.authenticate(request),importId=(request.body as any)?.importId;requireValue(uuid(importId));
   return db.tx(async tx=> {
     const l=await lockLibrary(tx,id);
     const old=await tx.query('SELECT * FROM imports WHERE id=$1 AND library_id=$2 AND session_id=$3',[importId,id.libraryId,id.sessionId]);
     if(old.rowCount)return {importId,committed:!!old.rows[0].committed_at};
     if(l.initialized)fail(409,'library_exists','Используйте существующую облачную библиотеку');
     await tx.query('INSERT INTO imports(id,library_id,session_id) VALUES($1,$2,$3)',[importId,id.libraryId,id.sessionId]);return {importId,committed:false};
   },true);
 });
 app.post('/v1/library/imports/:id/mutations',async request=> {
   const identity=await auth.authenticate(request),importId=(request.params as any).id,list=(request.body as any)?.mutations;
   requireValue(uuid(importId) && Array.isArray(list) && list.length<=100 && list.length>0);
   for(const m of list) {validateMutation(m,identity.libraryId,identity.deviceId);requireValue(m.kind==='create');}
   return db.tx(async tx=> {
     await lockLibrary(tx,identity);
     const i=await tx.query('SELECT * FROM imports WHERE id=$1 AND library_id=$2 AND session_id=$3 FOR UPDATE',[importId,identity.libraryId,identity.sessionId]);
     if(!i.rowCount || i.rows[0].expires_at<=new Date())fail(404,'not_found','Импорт недоступен');
     if(i.rows[0].committed_at)fail(409,'import_committed','Импорт завершён');
     for(const m of list) {
       const hash=digest(canonical(m)),old=await tx.query('SELECT request_hash FROM import_operations WHERE import_id=$1 AND operation_id=$2',[importId,m.operationId]);
       if(old.rowCount && old.rows[0].request_hash!==hash)fail(409,'operation_reused','Операция уже имеет другое содержимое');
       await tx.query('INSERT INTO import_operations(import_id,operation_id,body,request_hash) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',[importId,m.operationId,JSON.stringify(m),hash]);
     }return {accepted:list.length};
   },true);
 });
 app.post('/v1/library/imports/:id/commit',async request=> {
   const identity=await auth.authenticate(request),importId=(request.params as any).id;requireValue(uuid(importId));
   return db.tx(async tx=> {
     const l=await lockLibrary(tx,identity);
     const i=await tx.query('SELECT * FROM imports WHERE id=$1 AND library_id=$2 AND session_id=$3 FOR UPDATE',[importId,identity.libraryId,identity.sessionId]);
     if(!i.rowCount)fail(404,'not_found','Импорт недоступен');if(i.rows[0].committed_at)return {ok:true};
     if(i.rows[0].expires_at<=new Date())fail(410,'import_expired','Начните импорт заново');
     if(l.initialized)fail(409,'library_exists','Библиотека уже создана');
     const rows=await tx.query(`SELECT body FROM import_operations WHERE import_id=$1 ORDER BY CASE body->>'entityType' WHEN 'folder' THEN 0 WHEN 'task' THEN 1 ELSE 2 END,operation_id`,[importId]);
     for(const row of rows.rows)await applyMutation(tx,identity,row.body);
     await tx.query('UPDATE libraries SET initialized=true WHERE id=$1',[identity.libraryId]);
     await tx.query('UPDATE imports SET committed_at=now() WHERE id=$1',[importId]);return {ok:true};
   },true);
 });
}
