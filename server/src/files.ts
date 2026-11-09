import { mkdir, readFile, writeFile, rename, rm, open, stat, readdir, access } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import type { Database,Tx } from './db.js';
import type { AuthService,Identity } from './auth.js';
import type { Config } from './config.js';
import { fail,requireValue } from './errors.js';
import { digest,uuid } from './security.js';
import { lockLibrary,readEntity,publish } from './sync.js';
export const PART_BYTES=8*1024*1024;
export class FileStore {
 constructor(readonly root:string) {}
 async initialize(){for(const name of ['blobs','uploads'])await mkdir(join(this.root,name),{recursive:true,mode:0o700});}
 blob(id:string){if(!uuid(id))throw new Error('Invalid blob id');return join(this.root,'blobs',id);}
 upload(id:string){if(!uuid(id))throw new Error('Invalid upload id');return join(this.root,'uploads',id);}
 part(id:string,part:number){requireValue(Number.isSafeInteger(part)&&part>=0&&part<=1000);return join(this.upload(id),String(part));}
}
async function uploadRow(tx:Tx,identity:Identity,id:string){
 const r=await tx.query('SELECT * FROM uploads WHERE id=$1 AND library_id=$2 FOR UPDATE',[id,identity.libraryId]);
 if(!r.rowCount)fail(404,'not_found','Загрузка не найдена');
 const u=r.rows[0];
 const e=await readEntity(tx,identity.libraryId,u.attachment_id);
 if(!e||e.deleted)fail(410,'gone','Вложение удалено');
 if(!u.completed_at && u.expires_at<=new Date())fail(410,'upload_expired','Создайте новую сессию загрузки');
 return u;
}
export function installFiles(app:FastifyInstance,db:Database,auth:AuthService,config:Config,store:FileStore){
 app.addContentTypeParser('application/octet-stream',{parseAs:'buffer',bodyLimit:PART_BYTES},(_request,body,done)=>done(null,body));
 app.post('/v1/attachments/:id/uploads',async request=>{
   const identity=await auth.authenticate(request),attachmentId=(request.params as any).id,uploadId=(request.body as any)?.uploadId;
   requireValue(uuid(attachmentId)&&uuid(uploadId));
   return db.tx(async tx=>{
     await lockLibrary(tx,identity);
     const e=await readEntity(tx,identity.libraryId,attachmentId);
     if(!e||e.type!=='attachment'||e.deleted)fail(404,'not_found','Вложение не найдено');
     if(e.fields.size>config.maxFileBytes)fail(413,'file_too_large','Файл превышает лимит');
     if(e.fileReady)return {uploadId,ready:true,partBytes:PART_BYTES};
     const old=await tx.query('SELECT * FROM uploads WHERE id=$1',[uploadId]);
     if(old.rowCount){
       if(old.rows[0].library_id!==identity.libraryId||old.rows[0].attachment_id!==attachmentId)fail(409,'upload_id_reused','Идентификатор загрузки занят');
       const u=await uploadRow(tx,identity,uploadId);return {uploadId,ready:!!u.completed_at,partBytes:PART_BYTES};
     }
     const duplicate=await tx.query('SELECT id FROM blobs WHERE library_id=$1 AND sha256=$2 AND size=$3',[identity.libraryId,e.fields.sha256,e.fields.size]);
     if(duplicate.rowCount){
       await access(store.blob(duplicate.rows[0].id));
       await tx.query('INSERT INTO attachment_files(library_id,attachment_id,blob_id) VALUES($1,$2,$3)',[identity.libraryId,attachmentId,duplicate.rows[0].id]);
       await tx.query('UPDATE blobs SET delete_after=NULL WHERE id=$1',[duplicate.rows[0].id]);e.fileReady=true;await publish(tx,identity.libraryId,e);
       return {uploadId,ready:true,partBytes:PART_BYTES};
     }
     const active=await tx.query('SELECT 1 FROM uploads WHERE library_id=$1 AND attachment_id=$2 AND completed_at IS NULL AND expires_at>now()',[identity.libraryId,attachmentId]);
     if(active.rowCount)fail(409,'upload_in_progress','Для вложения уже есть активная загрузка');
     const usage=await tx.query(`SELECT (SELECT COALESCE(sum(size),0) FROM blobs WHERE library_id=$1)+(SELECT COALESCE(sum(size),0) FROM uploads WHERE library_id=$1 AND completed_at IS NULL AND expires_at>now()) AS total`,[identity.libraryId]);
     if(BigInt(usage.rows[0].total)+BigInt(e.fields.size)>BigInt(config.quotaBytes))fail(409,'quota_exceeded','Недостаточно места в облаке');
     await mkdir(store.upload(uploadId),{recursive:true,mode:0o700});
     await tx.query('INSERT INTO uploads(id,library_id,attachment_id,size,sha256) VALUES($1,$2,$3,$4,$5)',[uploadId,identity.libraryId,attachmentId,e.fields.size,e.fields.sha256]);
     return {uploadId,ready:false,partBytes:PART_BYTES,expiresIn:86400};
   },true);
 });
 app.get('/v1/uploads/:id',async request=>{
   const identity=await auth.authenticate(request),id=(request.params as any).id;requireValue(uuid(id));
   return db.tx(async tx=>{
     await lockLibrary(tx,identity);const u=await uploadRow(tx,identity,id);
     const r=await tx.query('SELECT part,size,sha256 FROM upload_parts WHERE upload_id=$1 ORDER BY part',[id]);
     return {uploadId:id,attachmentId:u.attachment_id,ready:!!u.completed_at,expiresAt:u.expires_at,partBytes:PART_BYTES,parts:r.rows};
   });
 });
 app.put('/v1/uploads/:id/parts/:part',{bodyLimit:PART_BYTES},async request=>{
   const identity=await auth.authenticate(request),id=(request.params as any).id,p=(request.params as any).part;
   requireValue(uuid(id)&&/^\d{1,4}$/.test(p)&&Buffer.isBuffer(request.body));const part=Number(p),bytes=request.body as Buffer;
   return db.tx(async tx=>{
     await lockLibrary(tx,identity);const u=await uploadRow(tx,identity,id);
     if(u.completed_at)fail(409,'upload_completed','Загрузка уже завершена');
     const total=Number(u.size),count=Math.ceil(total/PART_BYTES);
     requireValue(part<count&&bytes.length===Math.min(PART_BYTES,total-part*PART_BYTES),'invalid_part','Неверный размер части');
     const hash=digest(bytes),old=await tx.query('SELECT sha256 FROM upload_parts WHERE upload_id=$1 AND part=$2',[id,part]);
     if(old.rowCount&&old.rows[0].sha256!==hash)fail(409,'part_mismatch','У части уже другое содержимое');
     const path=store.part(id,part),temp=`${path}.${randomUUID()}.tmp`;
     await writeFile(temp,bytes,{mode:0o600,flag:'wx'});await rename(temp,path);
     await tx.query('INSERT INTO upload_parts(upload_id,part,size,sha256) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',[id,part,bytes.length,hash]);
     return {ok:true,sha256:hash};
   },true);
 });
 app.post('/v1/uploads/:id/complete',async request=>{
   const identity=await auth.authenticate(request),id=(request.params as any).id;requireValue(uuid(id));
   return db.tx(async tx=>{
     await lockLibrary(tx,identity);const u=await uploadRow(tx,identity,id);
     const e=await readEntity(tx,identity.libraryId,u.attachment_id);
     if(!e||e.deleted)fail(410,'gone','Вложение удалено');
     if(u.completed_at||e.fileReady)return {ok:true,attachment:e};
     const parts=(await tx.query('SELECT * FROM upload_parts WHERE upload_id=$1 ORDER BY part',[id])).rows;
     const count=Math.ceil(Number(u.size)/PART_BYTES);
     if(parts.length!==count||parts.some((p,i)=>p.part!==i))fail(409,'missing_parts','Не все части файла загружены');
     const assembled=join(store.upload(id),'assembled.tmp');const handle=await open(assembled,'w',0o600);const hash=createHash('sha256');let size=0;
     try{for(const p of parts){const data=await readFile(store.part(id,p.part));if(data.length!==p.size||digest(data)!==p.sha256)fail(409,'part_corrupted','Повторите повреждённую часть');hash.update(data);size+=data.length;await handle.writeFile(data);}await handle.sync();}finally{await handle.close();}
     if(size!==Number(u.size)||hash.digest('hex')!==u.sha256){await rm(assembled,{force:true});fail(409,'checksum_mismatch','Контрольная сумма файла не совпадает');}
     const duplicate=await tx.query('SELECT id FROM blobs WHERE library_id=$1 AND sha256=$2 AND size=$3',[identity.libraryId,u.sha256,u.size]);
     let blobId:string;
     if(duplicate.rowCount){blobId=duplicate.rows[0].id;await rm(assembled,{force:true});await access(store.blob(blobId));}
     else{blobId=randomUUID();await rename(assembled,store.blob(blobId));await tx.query('INSERT INTO blobs(id,library_id,sha256,size) VALUES($1,$2,$3,$4)',[blobId,identity.libraryId,u.sha256,u.size]);}
     await tx.query('UPDATE blobs SET delete_after=NULL WHERE id=$1',[blobId]);
     await tx.query('INSERT INTO attachment_files(library_id,attachment_id,blob_id) VALUES($1,$2,$3)',[identity.libraryId,e.id,blobId]);
     await tx.query('UPDATE uploads SET completed_at=now() WHERE id=$1',[id]);e.fileReady=true;await publish(tx,identity.libraryId,e);
     // Части удаляет worker после коммита; повтор завершения не читает их повторно.
     return {ok:true,attachment:e};
   },true);
 });
 app.get('/v1/attachments/:id/content',async(request,reply)=>{
   const identity=await auth.authenticate(request),id=(request.params as any).id;requireValue(uuid(id));
   const r=await db.pool.query(`SELECT e.fields,b.id,b.size,b.sha256 FROM entities e JOIN attachment_files a ON a.library_id=e.library_id AND a.attachment_id=e.id JOIN blobs b ON b.id=a.blob_id
     WHERE e.library_id=$1 AND e.id=$2 AND e.deleted=false`,[identity.libraryId,id]);
   if(!r.rowCount)fail(404,'file_not_ready','Файл пока недоступен');const f=r.rows[0];
   try{const s=await stat(store.blob(f.id));if(s.size!==Number(f.size))throw new Error('size');}catch{fail(503,'storage_unavailable','Файл недоступен в хранилище. Требуется проверка сервера');}
   const filename=encodeURIComponent(f.fields.filename).replace(/[!'()*]/g,c=>`%${c.charCodeAt(0).toString(16).toUpperCase()}`);
   return reply.type('application/octet-stream').header('Content-Length',String(f.size)).header('Content-Disposition',`attachment; filename*=UTF-8''${filename}`).header('X-Content-SHA256',f.sha256).header('Cache-Control','private, no-store').send(createReadStream(store.blob(f.id)));
 });
 app.get('/v1/storage',async request=>{
   const identity=await auth.authenticate(request);
   const r=await db.pool.query(`SELECT
     COALESCE(sum(size) FILTER(WHERE delete_after IS NULL),0) AS active,
     COALESCE(sum(size) FILTER(WHERE delete_after IS NOT NULL),0) AS retained
     FROM blobs WHERE library_id=$1`,[identity.libraryId]);
   const pending=await db.pool.query('SELECT COALESCE(sum(size),0) AS reserved FROM uploads WHERE library_id=$1 AND completed_at IS NULL AND expires_at>now()',[identity.libraryId]);
   return {quotaBytes:config.quotaBytes,maxFileBytes:config.maxFileBytes,activeBytes:Number(r.rows[0].active),retainedBytes:Number(r.rows[0].retained),reservedBytes:Number(pending.rows[0].reserved)};
 });
}
