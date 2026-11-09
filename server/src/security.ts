import { createHash, createHmac, randomBytes, randomInt, createCipheriv, createDecipheriv, timingSafeEqual } from 'node:crypto';
import argon2 from 'argon2';
import type { Database, Tx } from './db.js';
import { ApiError, requireValue } from './errors.js';
export const uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
export function uuid(x: unknown): x is string { return typeof x === 'string' && new RegExp(uuidPattern).test(x); }
export const digest = (s: string | Buffer) => createHash('sha256').update(s).digest('hex');
export const token = () => randomBytes(32).toString('base64url');
export const code = () => String(randomInt(0, 100000000)).padStart(8, '0');
export function email(value: unknown) {
  requireValue(typeof value === 'string');
  const normalized=value.trim().toLowerCase();
  requireValue(normalized.length<=254&&/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized));
  return normalized;
}
export function password(value: unknown): asserts value is string {
  requireValue(typeof value === 'string' && Array.from(value).length >= 12 && Array.from(value).length <= 128 && !value.includes('\0'), 'invalid_password', 'Пароль должен содержать от 12 до 128 символов');
}
export async function hashPassword(value: string) { return argon2.hash(value, { type: argon2.argon2id, memoryCost: 65536, timeCost: 3, parallelism: 1 }); }
export async function checkPassword(hash: string, value: string) { try { return await argon2.verify(hash, value); } catch { return false; } }
export function codeHash(secret: string, id: string, value: string) { return createHmac('sha256', secret).update(`${id}:${value}`).digest('hex'); }
export function same(a: string, b: string) { return a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b)); }
export function encrypt(secret: string, value: unknown) {
  const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', createHash('sha256').update(secret).digest(), iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64');
}
export function decrypt(secret: string, value: string): any {
  const bytes = Buffer.from(value, 'base64');
  const cipher = createDecipheriv('aes-256-gcm', createHash('sha256').update(secret).digest(), bytes.subarray(0,12));
  cipher.setAuthTag(bytes.subarray(12,28));
  return JSON.parse(Buffer.concat([cipher.update(bytes.subarray(28)),cipher.final()]).toString('utf8'));
}
export async function rateLimit(db: Database, key: string, max: number, seconds: number) {
  return rateLimitMany(db, [{key,max,seconds}]);
}
export async function rateLimitMany(db: Database, limits: {key:string;max:number;seconds:number}[]) {
  // Одна атомарная команда: счётчики сохраняются при отказе; берём наибольшее время ожидания.
  const r = await db.pool.query(`WITH input AS (
    SELECT * FROM jsonb_to_recordset($1::jsonb) AS x(key text, seconds integer)
  ) INSERT INTO limits(key,count,expires_at) SELECT key,1,now()+seconds*interval '1 second' FROM input ORDER BY key
    ON CONFLICT(key) DO UPDATE SET count=CASE WHEN limits.expires_at<=now() THEN 1 ELSE limits.count+1 END,
    expires_at=CASE WHEN limits.expires_at<=now() THEN EXCLUDED.expires_at ELSE limits.expires_at END
    RETURNING key,count,GREATEST(1,ceil(extract(epoch FROM expires_at-now())))::integer AS wait`, [JSON.stringify(limits)]);
  const exceeded=r.rows.filter(row=>row.count>limits.find(x=>x.key===row.key)!.max);
  if(exceeded.length)throw new ApiError(429,'rate_limited','Слишком много попыток. Попробуйте позже',Math.max(...exceeded.map(x=>x.wait)));
}
export async function queueMail(tx: Tx, secret: string, to: string, subject: string, text: string, expiresAt?: string, userId?: string) {
  await tx.query('INSERT INTO jobs(id,kind,encrypted_payload,user_id) VALUES(gen_random_uuid(),$1,$2,$3)', ['mail',encrypt(secret,{to,subject,text,expiresAt}),userId??null]);
}
