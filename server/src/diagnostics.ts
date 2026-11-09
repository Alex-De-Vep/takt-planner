import { randomBytes, timingSafeEqual, createHash } from 'node:crypto';
import { statfs } from 'node:fs/promises';
import type { FastifyRequest } from 'fastify';
import type { Database } from './db.js';
import type { Config } from './config.js';
import { SERVER_VERSION, PROTOCOL_VERSION } from './version.js';

export async function recordOperation(db:Database,key:string,value:Record<string,unknown>) {
  await db.pool.query(`INSERT INTO settings(key,value) VALUES($1,$2::jsonb)
    ON CONFLICT(key) DO UPDATE SET value=settings.value || EXCLUDED.value`,[`ops.${key}`,JSON.stringify(value)]);
}
export function smtpError(error:unknown) {
  const e=error as {code?:string;responseCode?:number};
  const allowed=['EAUTH','ECONNECTION','ETIMEDOUT','ESOCKET','EDNS','ECONNRESET','ECONNREFUSED','EENVELOPE','EMESSAGE','ETLS'];
  return {errorCode:allowed.includes(e?.code||'')?e.code:'SMTP_ERROR',smtpResponseCode:Number.isInteger(e?.responseCode)&&e.responseCode!>=100&&e.responseCode!<=599?e.responseCode:null};
}
export async function recordMail(db:Database,success:boolean,error?:unknown) {
  await recordOperation(db,'mail',success?{lastSuccessAt:new Date().toISOString()}:{lastFailureAt:new Date().toISOString(),...smtpError(error)});
}
export async function diagnostics(db:Database,config:Config) {
  const rows=await db.pool.query("SELECT key,value FROM settings WHERE key='maintenance' OR key LIKE 'ops.%'");
  const settings=Object.fromEntries(rows.rows.map(r=>[r.key,r.value]));
  const counts=(await db.pool.query(`SELECT count(*) FILTER(WHERE completed_at IS NULL AND attempts<10)::integer AS pending,
    count(*) FILTER(WHERE completed_at IS NULL AND attempts>=10)::integer AS failed,
    min(created_at) FILTER(WHERE completed_at IS NULL AND attempts<10) AS oldest FROM jobs WHERE kind='mail'`)).rows[0];
  const worker=settings['ops.worker']??{};
  const lastSeen=worker.lastSeenAt?Date.parse(worker.lastSeenAt):NaN;
  const disk=await statfs(config.dataDir);
  return {serverVersion:SERVER_VERSION,protocolVersion:PROTOCOL_VERSION,publicBaseUrl:config.publicBaseUrl,
    apiMaintenance:settings.maintenance===true,
    worker:{...worker,alive:Number.isFinite(lastSeen)&&Date.now()-lastSeen<120000&&!worker.stopped},
    mail:{...settings['ops.mail'],pending:counts.pending,failed:counts.failed,oldestPendingAt:counts.oldest?.toISOString()??null},
    backup:settings['ops.backup']??null,restore:settings['ops.restore']??null,
    dataAvailableBytes:disk.bavail*disk.bsize,
    proxy:{trustedCIDRs:config.trustedProxyCIDRs,lastProbes:settings['ops.proxy-probes']??[]}};
}
export async function startProxyProbe(db:Database) {
  const token=randomBytes(24).toString('hex'),expiresAt=new Date(Date.now()+300000).toISOString();
  const hash=createHash('sha256').update(token).digest('hex');
  await db.pool.query("INSERT INTO settings(key,value) VALUES('proxy-probe',$1) ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value",[JSON.stringify({hash,expiresAt})]);
  await db.pool.query("DELETE FROM settings WHERE key='ops.proxy-probes'");
  return {token,expiresAt};
}
export async function recordProxyProbe(db:Database,request:FastifyRequest) {
  const token=new URL(request.url,'http://localhost').searchParams.get('plannerProxyProbe');
  if(!token||!/^[a-f0-9]{48}$/.test(token))return;
  const row=(await db.pool.query("SELECT value FROM settings WHERE key='proxy-probe'")).rows[0]?.value;
  const hash=createHash('sha256').update(token).digest('hex');
  if(!row||Date.parse(row.expiresAt)<Date.now()||typeof row.hash!=='string'||row.hash.length!==hash.length||!timingSafeEqual(Buffer.from(row.hash),Buffer.from(hash)))return;
  const forwarded=request.headers['x-forwarded-for'];
  const value={at:new Date().toISOString(),socketAddress:request.raw.socket.remoteAddress??null,clientAddress:request.ip,
    forwardedFor:typeof forwarded==='string'?forwarded.slice(0,512):null};
  // Только локальная CLI-диагностика. Публичный ответ не содержит адреса и заголовки.
  await db.pool.query(`INSERT INTO settings(key,value) VALUES('ops.proxy-probes',jsonb_build_array($1::jsonb))
    ON CONFLICT(key) DO UPDATE SET value=(SELECT COALESCE(jsonb_agg(v ORDER BY n),'[]'::jsonb) FROM
      (SELECT v,n FROM jsonb_array_elements(settings.value || EXCLUDED.value) WITH ORDINALITY AS t(v,n) ORDER BY n DESC LIMIT 20) recent)`,[JSON.stringify(value)]);
}
