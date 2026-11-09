import { setTimeout as delay } from 'node:timers/promises';
import nodemailer from 'nodemailer';
import { rm,readdir,stat } from 'node:fs/promises';
import { recordMail,recordOperation } from './diagnostics.js';
import { SERVER_VERSION } from './version.js';
import type { Database } from './db.js';
import type { Config } from './config.js';
import { decrypt } from './security.js';
import { FileStore } from './files.js';
export async function deliverOne(db:Database,config:Config,send?: (mail:any)=>Promise<unknown>) {
 const claim=await db.tx(async tx=>{
   const r=await tx.query(`SELECT * FROM jobs WHERE (user_id IS NULL OR EXISTS(SELECT 1 FROM users WHERE id=jobs.user_id AND deleted_at IS NULL)) AND completed_at IS NULL AND attempts<10 AND available_at<=now() AND (locked_until IS NULL OR locked_until<now()) ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1`);
   if(!r.rowCount)return null;const job=r.rows[0];
   await tx.query("UPDATE jobs SET attempts=attempts+1,locked_until=now()+interval '60 seconds' WHERE id=$1",[job.id]);return job;
 });
 if(!claim)return false;
 try{
   const payload=decrypt(config.authSecret,claim.encrypted_payload);
   if(!payload.expiresAt||Date.parse(payload.expiresAt)>Date.now()){
     if(send)await send(payload);
     else{
       const smtp=nodemailer.createTransport({host:config.smtpHost,port:config.smtpPort,secure:config.smtpSecure,auth:config.smtpUser?{user:config.smtpUser,pass:config.smtpPassword}:undefined,connectionTimeout:10000,greetingTimeout:10000,socketTimeout:20000});
       try{await smtp.sendMail({from:config.mailFrom,to:payload.to,subject:payload.subject,text:payload.text,disableFileAccess:true,disableUrlAccess:true});}finally{smtp.close();}
     }
     await recordMail(db,true);
   }
   await db.pool.query('UPDATE jobs SET completed_at=now(),locked_until=NULL,encrypted_payload=$2 WHERE id=$1',[claim.id,'']);
 }catch(error){
   await recordMail(db,false,error);
   await db.pool.query("UPDATE jobs SET locked_until=NULL,available_at=now()+LEAST(3600,power(2,attempts)::integer)*interval '1 second' WHERE id=$1",[claim.id]);
 }
 return true;
}
export async function cleanup(db:Database,store:FileStore) {
 // Очистка и публикация используют общую блокировку обслуживания и блокировку библиотеки.
 const libs=await db.pool.query('SELECT id FROM libraries ORDER BY id');
 for(const lib of libs.rows)await db.tx(async tx=>{
   const r=await tx.query('SELECT id,owner_id FROM libraries WHERE id=$1 FOR UPDATE',[lib.id]);if(!r.rowCount)return;
   const deleted=(await tx.query('SELECT deleted_at FROM users WHERE id=$1',[r.rows[0].owner_id])).rows[0]?.deleted_at;
   if(deleted){
     const blobs=await tx.query('SELECT id FROM blobs WHERE library_id=$1',[lib.id]);
     const uploads=await tx.query('SELECT id FROM uploads WHERE library_id=$1',[lib.id]);
     for(const b of blobs.rows)await rm(store.blob(b.id),{force:true});for(const u of uploads.rows)await rm(store.upload(u.id),{recursive:true,force:true});
     await tx.query('DELETE FROM users WHERE id=$1',[r.rows[0].owner_id]);return;
   }
   await tx.query(`UPDATE blobs b SET delete_after=now()+interval '30 days' WHERE b.library_id=$1 AND delete_after IS NULL AND NOT EXISTS(
     SELECT 1 FROM attachment_files a JOIN entities e ON e.library_id=a.library_id AND e.id=a.attachment_id WHERE a.blob_id=b.id AND e.deleted=false)`,[lib.id]);
   const old=await tx.query('SELECT id FROM blobs WHERE library_id=$1 AND delete_after<=now()',[lib.id]);
   for(const b of old.rows){
     await tx.query('DELETE FROM attachment_files WHERE blob_id=$1',[b.id]);
     await tx.query('DELETE FROM blobs WHERE id=$1',[b.id]);
     await rm(store.blob(b.id),{force:true});
   }
   const uploads=await tx.query('SELECT id,completed_at FROM uploads WHERE library_id=$1 AND (completed_at IS NOT NULL OR expires_at<now())',[lib.id]);
   for(const u of uploads.rows){await rm(store.upload(u.id),{recursive:true,force:true});if(!u.completed_at)await tx.query('DELETE FROM uploads WHERE id=$1',[u.id]);}
   // Курсор продвигается под той же блокировкой, что новые записи журнала.
   const cutoff=await tx.query("SELECT max(revision) AS revision FROM changes WHERE library_id=$1 AND created_at<now()-interval '90 days'",[lib.id]);
   if(cutoff.rows[0].revision){await tx.query('UPDATE libraries SET min_cursor=GREATEST(min_cursor,$2) WHERE id=$1',[lib.id,cutoff.rows[0].revision]);await tx.query('DELETE FROM changes WHERE library_id=$1 AND revision<=$2',[lib.id,cutoff.rows[0].revision]);}
   await tx.query("DELETE FROM operations WHERE library_id=$1 AND created_at<now()-interval '90 days'",[lib.id]);
 },true);
 await db.pool.query("DELETE FROM imports WHERE expires_at<now() AND committed_at IS NULL");
 await db.pool.query("DELETE FROM challenges WHERE expires_at<now()-interval '1 day'");
 await db.pool.query("DELETE FROM limits WHERE expires_at<now()-interval '1 day'");
 await db.pool.query("DELETE FROM jobs WHERE completed_at<now()-interval '7 days' OR created_at<now()-interval '1 day'");
 await db.pool.query('DELETE FROM access_tokens WHERE expires_at<now()');
 // Файлы, оставшиеся после сбоя до коммита, безопасно удаляются только после суток.
 for(const id of await readdir(`${store.root}/blobs`)){
   if(!/^[a-f0-9-]{36}$/.test(id))continue;
   const file=store.blob(id),s=await stat(file);
   if(s.mtimeMs>Date.now()-86400000)continue;
   if(!(await db.pool.query('SELECT 1 FROM blobs WHERE id=$1',[id])).rowCount)await rm(file,{force:true});
 }
}
export async function runWorker(db:Database,config:Config,store:FileStore,signal:AbortSignal){
 let lastCleanup=0,lastHeartbeat=0;
 while(!signal.aborted){
   try{
     if(Date.now()-lastHeartbeat>10000){await recordOperation(db,'worker',{lastSeenAt:new Date().toISOString(),version:SERVER_VERSION,stopped:false});lastHeartbeat=Date.now();}
     if(Date.now()-lastCleanup>60000){await cleanup(db,store);lastCleanup=Date.now();}
     if(await deliverOne(db,config))continue;
   }catch{console.error(JSON.stringify({event:'worker_error'}));}
   await delay(1000,undefined,{signal}).catch(()=>{});
 }
 await recordOperation(db,'worker',{stopped:true,lastSeenAt:new Date().toISOString()});
}
