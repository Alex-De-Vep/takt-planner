import { mkdir,cp,readdir,stat,readFile,writeFile,lstat,realpath } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve,relative,isAbsolute,join } from 'node:path';
import type { Database } from './db.js';
import type { FileStore } from './files.js';
import { SERVER_VERSION } from './version.js';
import { recordOperation } from './diagnostics.js';
import { uuid } from './security.js';
import { requireValue } from './errors.js';
export async function fileHash(path:string){const hash=createHash('sha256');for await(const data of createReadStream(path))hash.update(data);return hash.digest('hex');}
function within(root:string,path:string){const full=resolve(path),rel=relative(resolve(root),full);requireValue(rel!==''&&!rel.startsWith('..')&&!isAbsolute(rel));return full;}
export async function stageBackup(db:Database,store:FileStore,root:string,id:string){
 requireValue(uuid(id));const dir=within(root,join(root,id));
 const maintenance=(await db.pool.query("SELECT value FROM settings WHERE key='maintenance'")).rows[0]?.value;
 requireValue(maintenance===true,'maintenance_required','Сначала включите обслуживание');
 await mkdir(join(dir,'blobs'),{recursive:true});
 const rows=(await db.pool.query('SELECT id,size,sha256 FROM blobs ORDER BY id')).rows;
 const files:any[]=[];
 for(const b of rows){const path=store.blob(b.id);requireValue((await stat(path)).size===Number(b.size),'corrupt_storage');requireValue(await fileHash(path)===b.sha256,'corrupt_storage');await cp(path,join(dir,'blobs',b.id));files.push({path:`blobs/${b.id}`,size:Number(b.size),sha256:b.sha256});}
 const dump=join(dir,'database.dump');const ds=await stat(dump);files.push({path:'database.dump',size:ds.size,sha256:await fileHash(dump)});
 await writeFile(join(dir,'manifest.json'),JSON.stringify({formatVersion:1,serverVersion:SERVER_VERSION,backupId:id,createdAt:new Date().toISOString(),files},null,2),{mode:0o600});
 return {backupId:id,files:files.length};
}
export async function verifyBackup(root:string,input:string){
 const dir=within(root,input);
 const realDir=within(await realpath(root),await realpath(dir));
 requireValue((await lstat(dir)).isDirectory()&&!(await lstat(dir)).isSymbolicLink());
 const manifestPath=join(dir,'manifest.json');requireValue((await lstat(manifestPath)).isFile()&&!(await lstat(manifestPath)).isSymbolicLink());
 const manifest=JSON.parse(await readFile(manifestPath,'utf8'));
 requireValue(manifest.formatVersion===1&&uuid(manifest.backupId)&&Array.isArray(manifest.files)&&manifest.files.length>0);
 const names=new Set<string>();
 for(const f of manifest.files){
   requireValue(typeof f.path==='string'&&(f.path==='database.dump'||(/^blobs\//.test(f.path)&&uuid(f.path.slice(6))))&&!names.has(f.path));names.add(f.path);
   requireValue(Number.isSafeInteger(f.size)&&f.size>=0&&typeof f.sha256==='string'&&/^[a-f0-9]{64}$/.test(f.sha256));
   const p=within(dir,join(dir,f.path)),s=await lstat(p);within(realDir,await realpath(p));requireValue(s.isFile()&&!s.isSymbolicLink()&&s.size===f.size&&await fileHash(p)===f.sha256,'invalid_backup','Архив повреждён или неполон');
 }
 requireValue(names.has('database.dump'));return {dir,manifest};
}
export async function restoreFiles(db:Database,store:FileStore,root:string,input:string){
 requireValue(process.env.RESTORE_MODE==='true','restore_disabled','Восстановление разрешено только в отдельном restore-проекте');
 const {dir,manifest}=await verifyBackup(root,input);requireValue((await readdir(join(store.root,'blobs'))).length===0,'nonempty_destination','Каталог файлов назначения должен быть пустым');
 const expected=(await db.pool.query('SELECT id,size,sha256 FROM blobs')).rows;
 for(const b of expected){const f=manifest.files.find((x:any)=>x.path===`blobs/${b.id}`);requireValue(f&&f.size===Number(b.size)&&f.sha256===b.sha256);await cp(join(dir,f.path),store.blob(b.id),{errorOnExist:true,force:false});}
 await db.tx(async tx=>{
   await tx.query('UPDATE sessions SET revoked_at=now()');await tx.query('UPDATE challenges SET consumed_at=now()');await tx.query('DELETE FROM jobs');
   // Временные передачи в резервную копию не включены: освобождаем их резервы.
   await tx.query('DELETE FROM uploads WHERE completed_at IS NULL');
   await tx.query("UPDATE settings SET value='false'::jsonb WHERE key='maintenance'");
   await tx.query("DELETE FROM settings WHERE key LIKE 'ops.%' OR key='proxy-probe'");
 });await recordOperation(db,'restore',{lastSuccessAt:new Date().toISOString(),backupId:manifest.backupId});return {restoredFiles:expected.length,sessionsRevoked:true};
}
