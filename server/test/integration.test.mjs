import { test,before,after,beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID,createHash } from 'node:crypto';
import { mkdtemp,rm,writeFile,mkdir,readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadConfig } from '../dist/config.js';
import { Database } from '../dist/db.js';
import { buildApp } from '../dist/app.js';
import { decrypt } from '../dist/security.js';
import { cleanup,deliverOne } from '../dist/worker.js';
import { diagnostics,recordOperation,recordMail,startProxyProbe } from '../dist/diagnostics.js';
import { rateLimitMany } from '../dist/security.js';
import { runWorker } from '../dist/worker.js';
import Ajv from 'ajv';
import { stageBackup,verifyBackup } from '../dist/backup.js';
import { validateMutation,compareStamp } from '../dist/protocol.js';
const databaseUrl=process.env.TEST_DATABASE_URL;
assert.ok(databaseUrl && /^planner_delivery_test/.test(new URL(databaseUrl).pathname.slice(1)),'Use an isolated planner_delivery_test database');
let db,app,store,dir,config;
const pw='Длинный пароль теста 42',secret='f'.repeat(64);
const hash=b=>createHash('sha256').update(b).digest('hex');
async function api(method,url,body,identity){return app.inject({method,url,headers:{...(identity?{authorization:`Bearer ${identity.accessToken}`}:{})},payload:body});}
async function challengeCode(id){const jobs=(await db.pool.query('SELECT encrypted_payload FROM jobs WHERE completed_at IS NULL ORDER BY created_at DESC')).rows;for(const j of jobs){const p=decrypt(secret,j.encrypted_payload);const m=p.text.match(/Код: (\d{8})/);if(m)return m[1];}throw new Error('No code');}
async function account(address='alice@example.test',deviceId=randomUUID()){
 const r=await api('POST','/v1/auth/register',{email:address,password:pw});assert.equal(r.statusCode,200,r.body);const c=r.json().challengeId;
 const v=await api('POST','/v1/auth/verify-email',{challengeId:c,code:await challengeCode(c),password:pw});assert.equal(v.statusCode,200,v.body);
 return login(address,deviceId);
}
async function login(address='alice@example.test',deviceId=randomUUID(),password=pw){const r=await api('POST','/v1/auth/login',{email:address,password,deviceId,deviceName:'Test device'});assert.equal(r.statusCode,200,r.body);const a={...r.json(),deviceId};a.libraryId=(await api('GET','/v1/me',undefined,a)).json().libraryId;return a;}
async function initialize(a,mutations=[]){const id=randomUUID();assert.equal((await api('POST','/v1/library/imports',{importId:id},a)).statusCode,200);if(mutations.length)assert.equal((await api('POST',`/v1/library/imports/${id}/mutations`,{mutations},a)).statusCode,200);const r=await api('POST',`/v1/library/imports/${id}/commit`,{},a);assert.equal(r.statusCode,200,r.body);return id;}
function operation(a,type,id,fields,kind='create',time=Date.now()-1000){const op=randomUUID();const stamp={physicalMillis:time,logicalCounter:0,deviceId:a.deviceId,operationId:op};return {operationId:op,libraryId:a.libraryId,deviceId:a.deviceId,entityId:id,entityType:type,kind,...(kind==='delete'?{deleteVersion:stamp}:{changes:Object.fromEntries(Object.entries(fields).map(([k,value])=>[k,{value,version:stamp}]))})};}
const task=(a,id=randomUUID(),title='Задача')=>operation(a,'task',id,{title,createdAt:new Date().toISOString(),placement:{kind:'inbox'}});
async function send(a,ops){const r=await api('POST','/v1/sync/mutations',{mutations:ops},a);assert.equal(r.statusCode,200,r.body);return r.json().results;}
async function snapshot(a){const r=await api('GET','/v1/sync/snapshot',undefined,a);assert.equal(r.statusCode,200,r.body);return r.json();}
async function addFile(a,taskId,bytes,sha=hash(bytes)){
 const id=randomUUID();const m=operation(a,'attachment',id,{taskId,filename:'файл.txt',mimeType:'text/plain',size:bytes.length,sha256:sha});
 assert.equal((await send(a,[m]))[0].status,'applied');const uploadId=randomUUID();const r=await api('POST',`/v1/attachments/${id}/uploads`,{uploadId},a);assert.equal(r.statusCode,200,r.body);return {id,uploadId,ready:r.json().ready};
}
async function part(a,u,index,bytes){return app.inject({method:'PUT',url:`/v1/uploads/${u}/parts/${index}`,headers:{authorization:`Bearer ${a.accessToken}`,'content-type':'application/octet-stream'},payload:bytes});}
before(async()=>{dir=await mkdtemp(join(tmpdir(),'planner-server-test-'));config=loadConfig({NODE_ENV:'test',DATABASE_URL:databaseUrl,AUTH_SECRET:secret,PUBLIC_BASE_URL:'http://localhost',DATA_DIR:dir,ALLOWED_REGISTRATION_EMAILS:'alice@example.test,bob@example.test',MAIL_FROM:'sender@example.test'});db=new Database(databaseUrl);await db.migrate();({app,store}=await buildApp(config,db));await app.ready();});
beforeEach(async()=>{await db.pool.query('TRUNCATE users,limits,jobs CASCADE');await db.pool.query("UPDATE settings SET value='false' WHERE key='maintenance'");config.quotaBytes=1073741824;config.userRequestsPerMinute=300;config.publicRequestsPerMinute=300;await db.pool.query("DELETE FROM settings WHERE key LIKE 'ops.%' OR key='proxy-probe'");});
after(async()=>{await app?.close();await db?.close();if(dir)await rm(dir,{recursive:true,force:true});});

test('health, migration repeatability and closed registration',async()=>{assert.equal((await api('GET','/health/ready')).statusCode,200);await db.migrate();const r=await api('POST','/v1/auth/register',{email:'outsider@example.test',password:pw});assert.equal(r.statusCode,403);assert.equal((await db.pool.query('SELECT * FROM users')).rowCount,0);assert.equal((await api('GET','/v1/config')).json().protocolVersion,1);});
test('password confirmation prevents pre-registration password takeover',async()=>{const r=await api('POST','/v1/auth/register',{email:'alice@example.test',password:'attacker password 123'});const id=r.json().challengeId;const c=await challengeCode(id);assert.equal((await api('POST','/v1/auth/verify-email',{challengeId:id,code:c,password:pw})).statusCode,200);await login();const bad=await api('POST','/v1/auth/login',{email:'alice@example.test',password:'attacker password 123',deviceId:randomUUID(),deviceName:'x'});assert.equal(bad.statusCode,401);const row=(await db.pool.query('SELECT password_hash FROM users')).rows[0];assert.ok(row.password_hash.startsWith('$argon2id$'));});
test('one-time verification code locks after five incorrect attempts',async()=>{const r=await api('POST','/v1/auth/register',{email:'alice@example.test',password:pw});const id=r.json().challengeId,c=await challengeCode(id);for(let i=0;i<5;i++)assert.equal((await api('POST','/v1/auth/verify-email',{challengeId:id,code:c==='00000000'?'11111111':'00000000',password:pw})).statusCode,400);assert.equal((await api('POST','/v1/auth/verify-email',{challengeId:id,code:c,password:pw})).statusCode,400);assert.equal((await db.pool.query('SELECT attempts FROM challenges WHERE id=$1',[id])).rows[0].attempts,5);});
test('refresh rotation, reuse revokes the device, logout isolation',async()=>{const a=await account();const b=await login();const r=await api('POST','/v1/auth/refresh',{refreshToken:a.refreshToken});assert.equal(r.statusCode,200);assert.equal((await api('POST','/v1/auth/refresh',{refreshToken:a.refreshToken})).statusCode,401);assert.equal((await api('GET','/v1/me',undefined,{accessToken:r.json().accessToken})).statusCode,401);assert.equal((await api('GET','/v1/me',undefined,b)).statusCode,200);await api('POST','/v1/auth/logout',{},b);assert.equal((await api('GET','/v1/me',undefined,b)).statusCode,401);});
test('reset has a generic response and revokes previous sessions',async()=>{const a=await account();await db.pool.query("UPDATE limits SET expires_at=now()-interval '1 second' WHERE key LIKE 'mail-minute:%'");const r=await api('POST','/v1/auth/password-reset/request',{email:'alice@example.test'});assert.equal(r.statusCode,200,r.body);const u=await api('POST','/v1/auth/password-reset/request',{email:'absent@example.test'});assert.equal(r.json().message,u.json().message);const id=r.json().challengeId;const newPassword='Новый пароль теста 456';const c=await challengeCode(id);const done=await api('POST','/v1/auth/password-reset/confirm',{challengeId:id,code:c,newPassword});assert.equal(done.statusCode,200,done.body);assert.equal((await api('GET','/v1/me',undefined,a)).statusCode,401);await login('alice@example.test',randomUUID(),newPassword);assert.equal((await api('POST','/v1/auth/password-reset/confirm',{challengeId:id,code:c,newPassword})).statusCode,400);});
test('import is invisible until commit, ordered by parents and idempotent',async()=>{const a=await account(),id=randomUUID(),folderId=randomUUID(),taskId=randomUUID();const f=operation(a,'folder',folderId,{name:'Работа',sortOrder:0});const t=task(a,taskId);t.changes.placement.value={kind:'folder',folderId};await api('POST','/v1/library/imports',{importId:id},a);assert.equal((await api('POST',`/v1/library/imports/${id}/mutations`,{mutations:[t,f]},a)).statusCode,200);assert.equal((await snapshot(a)).entities.length,0);const done=await api('POST',`/v1/library/imports/${id}/commit`,{},a);assert.equal(done.statusCode,200,done.body);assert.equal((await snapshot(a)).entities.length,2);assert.equal((await api('POST',`/v1/library/imports/${id}/commit`,{},a)).statusCode,200);assert.equal((await snapshot(a)).cursor,'2');});
test('invalid import rolls back all entities and can be repaired',async()=>{const a=await account(),id=randomUUID(),t=task(a);t.changes.placement.value={kind:'folder',folderId:randomUUID()};await api('POST','/v1/library/imports',{importId:id},a);await api('POST',`/v1/library/imports/${id}/mutations`,{mutations:[task(a),t]},a);assert.equal((await api('POST',`/v1/library/imports/${id}/commit`,{},a)).statusCode,409);assert.equal((await snapshot(a)).entities.length,0);assert.equal((await snapshot(a)).cursor,'0');});
test('mutations are idempotent and reject reuse with different data',async()=>{const a=await account();await initialize(a);const m=task(a);const first=await send(a,[m]);assert.equal(first[0].status,'applied');assert.deepEqual(await send(a,[m]),first);m.changes.title.value='другое';assert.equal((await send(a,[m]))[0].error.code,'operation_reused');assert.equal((await snapshot(a)).cursor,'1');});
test('field-level last-write-wins converges after reverse delivery',async()=>{const a=await account();await initialize(a);const b=await login();const m=task(a);await send(a,[m]);const time=Date.now()-500;const older=operation(a,'task',m.entityId,{title:'старое'},'update',time-100);const newer=operation(b,'task',m.entityId,{title:'новое'},'update',time);await send(b,[newer]);await send(a,[older,operation(a,'task',m.entityId,{description:'описание'},'update',time)]);const e=(await snapshot(a)).entities[0];assert.equal(e.fields.title,'новое');assert.equal(e.fields.description,'описание');assert.equal((await snapshot(b)).entities[0].fields.title,'новое');});
test('null clears a field, absent fields are retained and invalid dates rejected',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);await send(a,[operation(a,'task',m.entityId,{completedAt:new Date().toISOString()},'update')]);await send(a,[operation(a,'task',m.entityId,{completedAt:null},'update',Date.now())]);const e=(await snapshot(a)).entities[0];assert.equal(e.fields.completedAt,null);assert.equal(e.fields.title,'Задача');const bad=operation(a,'task',m.entityId,{focusDay:'2026-13-40'},'update');assert.equal((await send(a,[bad]))[0].status,'rejected');});
test('deletion wins against stale edits and cascades to subtasks',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);const child=randomUUID();await send(a,[operation(a,'checklistItem',child,{taskId:m.entityId,title:'подзадача',isCompleted:false,sortOrder:0})]);await send(a,[operation(a,'task',m.entityId,{},'delete')]);await send(a,[operation(a,'task',m.entityId,{title:'поздно'},'update',Date.now())]);assert.ok((await snapshot(a)).entities.every(e=>e.deleted));const replay=await send(a,[task(a,m.entityId)]);assert.equal(replay[0].status,'deleted');});
test('deleting a folder moves tasks and normalizes late placement',async()=>{const a=await account();await initialize(a);const f=randomUUID(),m=task(a);await send(a,[operation(a,'folder',f,{name:'Папка',sortOrder:0})]);m.changes.placement.value={kind:'folder',folderId:f};await send(a,[m]);await send(a,[operation(a,'folder',f,{},'delete')]);await send(a,[operation(a,'task',m.entityId,{placement:{kind:'folder',folderId:f}},'update',Date.now())]);assert.deepEqual((await snapshot(a)).entities.find(e=>e.id===m.entityId).fields.placement,{kind:'inbox'});});
test('accounts cannot read or write another library or revoke other devices',async()=>{const a=await account(),b=await account('bob@example.test');await initialize(a);await initialize(b);const m=task(a);await send(a,[m]);assert.equal((await snapshot(b)).entities.length,0);assert.equal((await send(b,[m]))[0].status,'rejected');assert.equal((await api('DELETE',`/v1/devices/${a.sessionId}`,undefined,b)).statusCode,404);});
test('rollback does not advance cursor; pagination and cursor expiry work',async()=>{const a=await account();await initialize(a);const bad=task(a);bad.changes.placement.value={kind:'folder',folderId:randomUUID()};assert.equal((await send(a,[bad]))[0].status,'rejected');assert.equal((await snapshot(a)).cursor,'0');await send(a,[task(a)]);const changes=(await api('GET','/v1/sync/changes?cursor=0',undefined,a)).json();assert.equal(changes.nextCursor,'1');assert.equal(changes.changes.length,1);await db.pool.query("UPDATE changes SET created_at=now()-interval '91 days'");await cleanup(db,store);assert.equal((await api('GET','/v1/sync/changes?cursor=0',undefined,a)).statusCode,410);});
test('maintenance rejects writes while reads remain possible',async()=>{const a=await account();await initialize(a);await db.maintenance(true);const r=await api('POST','/v1/sync/mutations',{mutations:[task(a)]},a);assert.equal(r.statusCode,503);assert.equal((await snapshot(a)).entities.length,0);assert.equal((await api('GET','/health/ready')).statusCode,503);await db.maintenance(false);});
test('chunked attachment resumes, verifies and returns identical bytes',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);const bytes=Buffer.alloc(8*1024*1024+3,87),f=await addFile(a,m.entityId,bytes);assert.equal((await part(a,f.uploadId,0,bytes.subarray(0,8388608))).statusCode,200);const state=(await api('GET',`/v1/uploads/${f.uploadId}`,undefined,a)).json();assert.equal(state.parts.length,1);assert.equal((await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a)).statusCode,409);assert.equal((await part(a,f.uploadId,1,bytes.subarray(8388608))).statusCode,200);const done=await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a);assert.equal(done.statusCode,200,done.body);assert.equal((await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a)).statusCode,200);const downloaded=await api('GET',`/v1/attachments/${f.id}/content`,undefined,a);assert.equal(downloaded.statusCode,200);assert.deepEqual(downloaded.rawPayload,bytes);assert.equal(downloaded.headers['x-content-sha256'],hash(bytes));});
test('parts are idempotent, changed duplicate and wrong checksum rejected',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);const f=await addFile(a,m.entityId,Buffer.from('abc'),'0'.repeat(64));assert.equal((await part(a,f.uploadId,0,Buffer.from('abc'))).statusCode,200);assert.equal((await part(a,f.uploadId,0,Buffer.from('abc'))).statusCode,200);assert.equal((await part(a,f.uploadId,0,Buffer.from('xyz'))).statusCode,409);assert.equal((await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a)).json().error.code,'checksum_mismatch');assert.equal((await api('GET',`/v1/attachments/${f.id}/content`,undefined,a)).statusCode,404);});
test('empty file is valid; deduplication is per owner and quota is enforced',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);const z=await addFile(a,m.entityId,Buffer.alloc(0));assert.equal((await api('POST',`/v1/uploads/${z.uploadId}/complete`,{},a)).statusCode,200);const f=await addFile(a,m.entityId,Buffer.from('abc'));await part(a,f.uploadId,0,Buffer.from('abc'));await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a);const second=await addFile(a,m.entityId,Buffer.from('abc'));assert.equal(second.ready,true);const usage=(await api('GET','/v1/storage',undefined,a)).json();assert.equal(usage.activeBytes,3);config.quotaBytes=3;const fid=randomUUID();await send(a,[operation(a,'attachment',fid,{taskId:m.entityId,filename:'x',mimeType:'text/plain',size:1,sha256:hash('x')})]);assert.equal((await api('POST',`/v1/attachments/${fid}/uploads`,{uploadId:randomUUID()},a)).json().error.code,'quota_exceeded');});
test('other owners cannot access upload parts or file content',async()=>{const a=await account(),b=await account('bob@example.test');await initialize(a);await initialize(b);const m=task(a);await send(a,[m]);const f=await addFile(a,m.entityId,Buffer.from('abc'));assert.equal((await api('GET',`/v1/uploads/${f.uploadId}`,undefined,b)).statusCode,404);assert.equal((await part(b,f.uploadId,0,Buffer.from('abc'))).statusCode,404);assert.equal((await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},b)).statusCode,404);await part(a,f.uploadId,0,Buffer.from('abc'));await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a);assert.equal((await api('GET',`/v1/attachments/${f.id}/content`,undefined,b)).statusCode,404);});
test('deleting a task prevents completion of an in-flight file',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);const f=await addFile(a,m.entityId,Buffer.from('abc'));await part(a,f.uploadId,0,Buffer.from('abc'));await send(a,[operation(a,'task',m.entityId,{},'delete')]);assert.equal((await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a)).statusCode,410);});
test('mail jobs are encrypted, retry and clear their payload after success',async()=>{const r=await api('POST','/v1/auth/register',{email:'alice@example.test',password:pw});assert.equal(r.statusCode,200);const id=r.json().challengeId,c=await challengeCode(id);let job=(await db.pool.query('SELECT * FROM jobs')).rows[0];assert.ok(!job.encrypted_payload.includes(c));await deliverOne(db,config,async()=>{throw new Error('SMTP unavailable');});job=(await db.pool.query('SELECT * FROM jobs')).rows[0];assert.equal(job.attempts,1);assert.equal(job.completed_at,null);await db.pool.query('UPDATE jobs SET available_at=now()');let mail;await deliverOne(db,config,async m=>{mail=m;});assert.ok(mail.text.includes(c));assert.equal((await db.pool.query('SELECT encrypted_payload FROM jobs')).rows[0].encrypted_payload,'');});
test('backup manifest verifies blobs and rejects corrupted archives',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);const f=await addFile(a,m.entityId,Buffer.from('abc'));await part(a,f.uploadId,0,Buffer.from('abc'));await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a);const root=join(dir,'backups'),id=randomUUID(),out=join(root,id);await mkdir(out,{recursive:true});await writeFile(join(out,'database.dump'),'test dump bytes');await db.maintenance(true);await stageBackup(db,store,root,id);await verifyBackup(root,out);await writeFile(join(out,'database.dump'),'corrupted');await assert.rejects(()=>verifyBackup(root,out));await db.maintenance(false);});
test('equal physical time has a deterministic ordering',()=>{const a={physicalMillis:1,logicalCounter:0,deviceId:'a',operationId:'x'},b={...a,deviceId:'b'};assert.equal(compareStamp(a,b),-1);assert.equal(compareStamp(b,a),1);assert.equal(compareStamp(a,a),0);});


test('reuploading an identical part repairs damaged temporary bytes',async()=>{const a=await account();await initialize(a);const m=task(a);await send(a,[m]);const bytes=Buffer.from('abc'),f=await addFile(a,m.entityId,bytes);await part(a,f.uploadId,0,bytes);await writeFile(store.part(f.uploadId,0),'BAD');assert.equal((await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a)).statusCode,409);assert.equal((await part(a,f.uploadId,0,bytes)).statusCode,200);assert.equal((await api('POST',`/v1/uploads/${f.uploadId}/complete`,{},a)).statusCode,200);assert.deepEqual((await api('GET',`/v1/attachments/${f.id}/content`,undefined,a)).rawPayload,bytes);});
test('account removal revokes access and removes queued mail without affecting other owners',async()=>{const a=await account(),b=await account('bob@example.test');const r=await api('DELETE','/v1/account',{password:pw},a);assert.equal(r.statusCode,200,r.body);assert.equal((await api('GET','/v1/me',undefined,a)).statusCode,401);await cleanup(db,store);assert.equal((await db.pool.query('SELECT * FROM users')).rowCount,1);let delivered;await deliverOne(db,config,async p=>{delivered=p.to;});assert.equal(delivered,'bob@example.test');assert.equal((await api('GET','/v1/me',undefined,b)).statusCode,200);});

test('folder deletion preserves placement version and converges across delivery orders',async()=>{const a=await account();await initialize(a);const f=randomUUID(),g=randomUUID(),t1=task(a),t2=task(a),time=Date.now()-1000;for(const t of [t1,t2]){t.changes.placement.value={kind:'folder',folderId:f};t.changes.placement.version.physicalMillis=time;}await send(a,[operation(a,'folder',f,{name:'Удаляемая',sortOrder:0}),operation(a,'folder',g,{name:'Оставшаяся',sortOrder:1}),t1,t2]);await send(a,[operation(a,'task',t1.entityId,{placement:{kind:'folder',folderId:g}},'update',time+10)]);await send(a,[operation(a,'folder',f,{},'delete',time+100)]);await send(a,[operation(a,'task',t2.entityId,{placement:{kind:'folder',folderId:g}},'update',time+10)]);const rows=(await snapshot(a)).entities.filter(e=>e.type==='task');assert.ok(rows.every(e=>e.fields.placement.folderId===g));});


test('OpenAPI describes every success/error response, binary upload and retry headers',async()=>{
 const doc=(await api('GET','/v1/openapi.json')).json();
 assert.equal(doc.info.version,'0.1.1');assert.ok(doc.components.schemas.TaskEntity);assert.ok(doc.components.schemas.LoginResponse);
 for(const [path,methods]of Object.entries(doc.paths))for(const [method,op]of Object.entries(methods)){
  if(!op.responses)continue;
  assert.ok(op.responses['200']?.content,`${method} ${path}`);
  assert.ok(op.responses['429']?.headers?.['Retry-After']);
 }
 assert.equal(doc.paths['/v1/uploads/{id}/parts/{part}'].put.requestBody.content['application/octet-stream'].schema.format,'binary');
 assert.ok(doc.paths['/v1/attachments/{id}/content'].get.responses['200'].headers['X-Content-SHA256']);
});
test('typed serialization retains complete entity fields, versions, nulls, IDs and token data',async()=>{
 const a=await account();await initialize(a);const m=task(a),instant=new Date().toISOString();
 m.changes={...m.changes,...operation(a,'task',m.entityId,{description:'Многострочное\nописание',deadline:{includesTime:true,instant,timeZoneId:'Europe/Moscow'},planning:{kind:'week',anchor:instant},focusDay:'2026-11-06'}).changes};
 // Stamps may use their own operation IDs; enclosing device identity must match.
 await send(a,[m]);const snap=await snapshot(a);const row=(await db.pool.query('SELECT * FROM entities WHERE id=$1',[m.entityId])).rows[0];
 assert.deepEqual(snap.entities[0].fields,row.fields);assert.deepEqual(snap.entities[0].versions,row.versions);
 const ajv=new Ajv({strict:false,validateFormats:false});for(const schema of Object.values(app.getSchemas()))ajv.addSchema(schema);
 for(const [schema,value]of [['SnapshotResponse',snap],['LoginResponse',a]]){
  // a additionally holds client-only deviceId/libraryId, validate the actual wire login below.
  const actual=schema==='LoginResponse'?(await api('POST','/v1/auth/login',{email:'alice@example.test',password:pw,deviceId:randomUUID(),deviceName:'Contract test'})).json():value;
  assert.ok(ajv.validate({$ref:schema+'#'},actual),JSON.stringify(ajv.errors));
 }
 const unknown=operation(a,'attachment',randomUUID(),{},'delete');await send(a,[unknown]);assert.deepEqual((await snapshot(a)).entities.find(e=>e.id===unknown.entityId).fields,{});
});
test('proxy configuration rejects wildcard trust and invalid addresses',()=>{
 for(const value of ['true','*','0.0.0.0/0','::/0','localhost','192.168.1.1/33','10.0.0.1/8/extra'])assert.throws(()=>loadConfig({NODE_ENV:'test',DATABASE_URL:databaseUrl,AUTH_SECRET:secret,PUBLIC_BASE_URL:'http://localhost',TRUSTED_PROXY_CIDRS:value}));
 assert.deepEqual(loadConfig({NODE_ENV:'test',DATABASE_URL:databaseUrl,AUTH_SECRET:secret,PUBLIC_BASE_URL:'http://localhost',TRUSTED_PROXY_CIDRS:'127.0.0.1,::1,172.20.0.1/32'}).trustedProxyCIDRs,['127.0.0.1','::1','172.20.0.1/32']);
});
test('trusted proxy separates external clients; an untrusted peer cannot spoof rate-limit identity',async()=>{
 const isolatedConfig={...config,trustedProxyCIDRs:['127.0.0.1'],publicRequestsPerMinute:2};
 const other=(await buildApp(isolatedConfig,db)).app;await other.ready();
 try{
  const request=(remote,forward)=>other.inject({method:'GET',url:'/v1/config',remoteAddress:remote,headers:{'x-forwarded-for':forward}});
  assert.equal((await request('127.0.0.1','198.51.100.10')).statusCode,200);
  assert.equal((await request('127.0.0.1','198.51.100.10')).statusCode,200);
  assert.equal((await request('127.0.0.1','198.51.100.10')).statusCode,429);
  assert.equal((await request('127.0.0.1','198.51.100.11')).statusCode,200);
  assert.equal((await request('203.0.113.5','198.51.100.20')).statusCode,200);
  assert.equal((await request('203.0.113.5','198.51.100.21')).statusCode,200);
  assert.equal((await request('203.0.113.5','198.51.100.22')).statusCode,429);
 }finally{await other.close();}
});
test('authenticated users behind one proxy have independent budgets',async()=>{
 const a=await account(),b=await account('bob@example.test');
 config.userRequestsPerMinute=3;config.publicRequestsPerMinute=1;
 await db.pool.query("DELETE FROM limits WHERE key LIKE 'api-user:%'");
 for(let i=0;i<3;i++)assert.equal((await api('GET','/v1/me',undefined,a)).statusCode,200);
 const denied=await api('GET','/v1/me',undefined,a);assert.equal(denied.statusCode,429);assert.equal(denied.json().error.code,'rate_limited');
 assert.equal((await api('GET','/v1/me',undefined,b)).statusCode,200);
 assert.ok(Number(denied.headers['retry-after'])>0);
});
test('Retry-After reports the longest exceeded window rather than fixed sixty seconds',async()=>{
 const address='alice@example.test';
 await db.pool.query('INSERT INTO limits(key,count,expires_at) VALUES($1,5,now()+interval \'45 minutes\')',[`mail-hour:${hash(address)}`]);
 const r=await api('POST','/v1/auth/register',{email:address,password:pw});
 assert.equal(r.statusCode,429);assert.ok(Number(r.headers['retry-after'])>=2699);assert.equal(r.json().error.retryAfterSeconds,Number(r.headers['retry-after']));
 await assert.rejects(()=>rateLimitMany(db,[{key:'multi-short',max:0,seconds:60},{key:'multi-long',max:0,seconds:600}]),e=>e.retryAfterSeconds>=599);
});
test('refresh sessions have independent limits even behind a single proxy',async()=>{
 const a=await account(),b=await login();
 await db.pool.query('INSERT INTO limits(key,count,expires_at) VALUES($1,120,now()+interval \'8 minutes\')',[`refresh-session:${a.sessionId}`]);
 const r=await api('POST','/v1/auth/refresh',{refreshToken:a.refreshToken});assert.equal(r.statusCode,429);assert.ok(Number(r.headers['retry-after'])>470);
 assert.equal((await api('POST','/v1/auth/refresh',{refreshToken:b.refreshToken})).statusCode,200);
});
test('operator diagnostics distinguish heartbeat, backlog and safe SMTP failure without leaking payload',async()=>{
 await api('POST','/v1/auth/register',{email:'alice@example.test',password:pw});
 const error=Object.assign(new Error('password=VERY_SECRET recipient=private@example.test'),{code:'EAUTH',responseCode:535});
 await deliverOne(db,config,async()=>{throw error;});
 await recordOperation(db,'worker',{lastSeenAt:new Date().toISOString(),version:'0.1.1',stopped:false});
 let state=await diagnostics(db,config);assert.equal(state.worker.alive,true);assert.equal(state.mail.pending,1);assert.equal(state.mail.errorCode,'EAUTH');assert.equal(state.mail.smtpResponseCode,535);
 assert.ok(!JSON.stringify(state).includes('VERY_SECRET'));assert.ok(!JSON.stringify(state).includes('private@example.test'));
 await recordMail(db,true);state=await diagnostics(db,config);assert.ok(state.mail.lastSuccessAt);
 await recordOperation(db,'worker',{lastSeenAt:new Date(Date.now()-180000).toISOString()});assert.equal((await diagnostics(db,config)).worker.alive,false);
 await db.pool.query('UPDATE jobs SET attempts=10');assert.equal((await diagnostics(db,config)).mail.failed,1);
});
test('worker publishes heartbeat and records graceful stop',async()=>{
 const controller=new AbortController();const running=runWorker(db,config,store,controller.signal);
 await new Promise(r=>setTimeout(r,150));assert.equal((await diagnostics(db,config)).worker.alive,true);
 controller.abort();await running;assert.equal((await diagnostics(db,config)).worker.alive,false);
});
test('proxy probe is local-only, expires and stores at most twenty recent samples',async()=>{
 const probe=await startProxyProbe(db);const url='/health/live?plannerProxyProbe='+probe.token;
 for(let i=0;i<23;i++){
  const r=await app.inject({method:'GET',url,remoteAddress:'198.51.100.'+(i+1)});assert.deepEqual(r.json(),{status:'ok',version:'0.1.1'});
 }
 const samples=(await diagnostics(db,config)).proxy.lastProbes;assert.equal(samples.length,20);assert.equal(samples[0].clientAddress,'198.51.100.4');assert.equal(samples.at(-1).clientAddress,'198.51.100.23');
 await db.pool.query("UPDATE settings SET value=jsonb_set(value,'{expiresAt}',to_jsonb('2000-01-01T00:00:00Z'::text)) WHERE key='proxy-probe'");
 await api('GET',url);assert.equal((await diagnostics(db,config)).proxy.lastProbes.length,20);
});
test('backup verification rejects symlinked files and directories escaping the stage',async()=>{
 const {symlink}=await import('node:fs/promises');
 const root=join(dir,'symlink-test-'+randomUUID()),outside=join(dir,'outside-'+randomUUID()),stage=join(root,randomUUID());await mkdir(stage,{recursive:true});await mkdir(outside);
 const blobId=randomUUID();await writeFile(join(outside,blobId),'abc');await symlink(outside,join(stage,'blobs'));await writeFile(join(stage,'database.dump'),'dump');
 await writeFile(join(stage,'manifest.json'),JSON.stringify({formatVersion:1,backupId:randomUUID(),files:[{path:'database.dump',size:4,sha256:hash('dump')},{path:'blobs/'+blobId,size:3,sha256:hash('abc')}]}));
 await assert.rejects(()=>verifyBackup(root,stage));
});
