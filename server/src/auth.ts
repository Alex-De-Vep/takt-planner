import type { FastifyInstance, FastifyRequest } from 'fastify';
import { randomUUID } from 'node:crypto';
import type { Config } from './config.js';
import type { Database, Tx } from './db.js';
import { ApiError, fail, requireValue } from './errors.js';
import { checkPassword, code, codeHash, digest, email, hashPassword, password, queueMail, rateLimit, rateLimitMany, same, token, uuid } from './security.js';
export interface Identity { userId: string; libraryId: string; sessionId: string; deviceId: string; email: string; }
export interface AuthService { authenticate(request: FastifyRequest): Promise<Identity>; }
const generic = { message: 'Если адрес доступен для этой операции, письмо будет отправлено' };
export async function installAuth(app: FastifyInstance, db: Database, config: Config): Promise<AuthService> {
  // Проверка неизвестного пользователя тоже выполняет Argon2, без быстрого раскрытия существования аккаунта.
  const dummyHash = await hashPassword(token());
  const identities = new WeakMap<FastifyRequest, Identity>();
  let hashing = 0;
  async function withHash<T>(fn: () => Promise<T>) {
    if (hashing >= 2) throw new ApiError(429,'busy','Повторите попытку немного позже',1);
    hashing++;
    try { return await fn(); } finally { hashing--; }
  }
  async function limit(request: FastifyRequest, address: string) {
    await rateLimitMany(db,[{key:`auth-ip:${digest(request.ip)}`,max:60,seconds:600},{key:`auth-email:${digest(address)}`,max:30,seconds:600}]);
  }
  async function challenge(tx: Tx, userId: string | null, address: string, purpose: 'verify'|'reset') {
    const id = randomUUID(), value = code();
    const expires = new Date(Date.now()+600000).toISOString();
    await tx.query('UPDATE challenges SET consumed_at=now() WHERE email=$1 AND purpose=$2 AND consumed_at IS NULL',[address,purpose]);
    await tx.query('INSERT INTO challenges(id,user_id,email,purpose,code_hash,expires_at) VALUES($1,$2,$3,$4,$5,$6)',[id,userId,address,purpose,codeHash(config.authSecret,id,value),expires]);
    if (userId) await queueMail(tx,config.authSecret,address,purpose==='verify'?'Подтверждение почты — Задачи':'Восстановление пароля — Задачи',`Код: ${value}\nКод действует 10 минут. Если вы не запрашивали эту операцию, пропустите письмо.`,expires,userId);
    return id;
  }
  async function sendLimits(address: string) {
    await rateLimitMany(db,[{key:`mail-minute:${digest(address)}`,max:1,seconds:60},{key:`mail-hour:${digest(address)}`,max:5,seconds:3600}]);
  }
  async function issueTokens(tx: Tx, sessionId: string) {
    const accessToken = token(), refreshToken = token();
    await tx.query('INSERT INTO access_tokens(hash,session_id,expires_at) VALUES($1,$2,now()+interval \'15 minutes\')',[digest(accessToken),sessionId]);
    await tx.query(`INSERT INTO refresh_tokens(hash,session_id,expires_at) SELECT $1,id,LEAST(absolute_expires_at,now()+interval '30 days') FROM sessions WHERE id=$2`,[digest(refreshToken),sessionId]);
    return { accessToken, refreshToken, expiresIn:900, tokenType:'Bearer' };
  }
  async function authenticate(request: FastifyRequest): Promise<Identity> {
    const cached=identities.get(request);if(cached)return cached;
    const header = request.headers.authorization;
    if (!header?.startsWith('Bearer ') || header.length > 256) fail(401,'unauthorized','Требуется вход');
    const r = await db.pool.query(`SELECT u.id AS user_id,u.email,l.id AS library_id,s.id AS session_id,s.device_id
      FROM access_tokens a JOIN sessions s ON s.id=a.session_id JOIN users u ON u.id=s.user_id JOIN libraries l ON l.owner_id=u.id
      WHERE a.hash=$1 AND a.expires_at>now() AND s.revoked_at IS NULL AND s.absolute_expires_at>now() AND s.idle_expires_at>now() AND u.verified_at IS NOT NULL AND u.deleted_at IS NULL`,[digest(header.slice(7))]);
    if (!r.rowCount) fail(401,'unauthorized','Требуется повторный вход');
    const v=r.rows[0];
    await rateLimit(db,`api-user:${v.user_id}`,config.userRequestsPerMinute,60);
    const identity={userId:v.user_id,email:v.email,libraryId:v.library_id,sessionId:v.session_id,deviceId:v.device_id};
    identities.set(request,identity);return identity;
  }
  app.post('/v1/auth/register',async request => {
    const body=request.body as any, address=email(body?.email); password(body?.password);
    await limit(request,address); await sendLimits(address);
    if (!config.publicRegistration && !config.allowedEmails.includes(address)) fail(403,'registration_closed','Регистрация для этого адреса пока недоступна');
    const hash=await withHash(()=>hashPassword(body.password));
    const challengeId=await db.tx(async tx=> {
      await tx.query('INSERT INTO users(id,email,password_hash) VALUES($1,$2,$3) ON CONFLICT(email) DO NOTHING',[randomUUID(),address,hash]);
      const r=await tx.query('SELECT id,verified_at,deleted_at FROM users WHERE email=$1 FOR UPDATE',[address]);
      const u=r.rows[0];
      return challenge(tx,u && !u.verified_at && !u.deleted_at ? u.id : null,address,'verify');
    });
    return {...generic,challengeId};
  });
  app.post('/v1/auth/resend-verification',async request=> {
    const address=email((request.body as any)?.email); await limit(request,address); await sendLimits(address);
    const challengeId=await db.tx(async tx=> {
      const r=await tx.query('SELECT id FROM users WHERE email=$1 AND verified_at IS NULL AND deleted_at IS NULL FOR UPDATE',[address]);
      return challenge(tx,r.rows[0]?.id??null,address,'verify');
    }); return {...generic,challengeId};
  });
  async function consume(request: FastifyRequest,purpose:'verify'|'reset') {
    const body=request.body as any;
    requireValue(uuid(body?.challengeId) && typeof body?.code==='string' && /^\d{8}$/.test(body.code));
    if (purpose==='reset') password(body?.newPassword); else password(body?.password);
    await rateLimit(db,`code-ip:${digest(request.ip)}`,60,600);
    const newHash=await withHash(()=>hashPassword(purpose==='reset'?body.newPassword:body.password));
    const success=await db.tx(async tx=> {
      const r=await tx.query(`SELECT * FROM challenges WHERE id=$1 AND purpose=$2 FOR UPDATE`,[body.challengeId,purpose]);
      const c=r.rows[0];
      if (!c || c.consumed_at || c.attempts>=5 || c.expires_at<=new Date() || !c.user_id) return false;
      // Не бросаем исключение внутри транзакции: счётчик неверных кодов должен сохраниться.
      await tx.query('UPDATE challenges SET attempts=attempts+1 WHERE id=$1',[c.id]);
      if (!same(c.code_hash,codeHash(config.authSecret,c.id,body.code))) return false;
      const user=await tx.query('SELECT id FROM users WHERE id=$1 AND deleted_at IS NULL FOR UPDATE',[c.user_id]);
      if (!user.rowCount) return false;
      await tx.query('UPDATE challenges SET consumed_at=now() WHERE id=$1',[c.id]);
      if (purpose==='verify') {
        await tx.query('UPDATE users SET verified_at=now(),password_hash=$2 WHERE id=$1',[c.user_id,newHash]);
        await tx.query('INSERT INTO libraries(id,owner_id) VALUES($1,$2) ON CONFLICT(owner_id) DO NOTHING',[randomUUID(),c.user_id]);
      } else {
        await tx.query('UPDATE users SET password_hash=$1 WHERE id=$2',[newHash,c.user_id]);
        await tx.query('UPDATE sessions SET revoked_at=now() WHERE user_id=$1',[c.user_id]);
      } return true;
    });
    if (!success) fail(400,'invalid_code','Код неверен, истёк или уже использован');
    return {ok:true};
  }
  app.post('/v1/auth/verify-email',r=>consume(r,'verify'));
  app.post('/v1/auth/password-reset/confirm',r=>consume(r,'reset'));
  app.post('/v1/auth/password-reset/request',async request=> {
    const address=email((request.body as any)?.email); await limit(request,address); await sendLimits(address);
    const challengeId=await db.tx(async tx=> {
      const u=await tx.query('SELECT id FROM users WHERE email=$1 AND deleted_at IS NULL AND verified_at IS NOT NULL FOR UPDATE',[address]);
      return challenge(tx,u.rows[0]?.id??null,address,'reset');
    }); return {...generic,challengeId};
  });
  app.post('/v1/auth/login',async request=> {
    const body=request.body as any,address=email(body?.email); password(body?.password);
    requireValue(uuid(body?.deviceId) && typeof body?.deviceName==='string' && body.deviceName.length>0 && body.deviceName.length<=100);
    await limit(request,address);
    const r=await db.pool.query('SELECT * FROM users WHERE email=$1 AND deleted_at IS NULL',[address]),u=r.rows[0];
    const valid=await withHash(()=>checkPassword(u?.password_hash??dummyHash,body.password));
    if (!valid || !u) fail(401,'invalid_credentials','Неверная почта или пароль');
    if (!u.verified_at) fail(403,'email_not_verified','Подтвердите почту');
    return db.tx(async tx=> {
      // Повторная проверка под блокировкой защищает от входа старым паролем одновременно со сбросом.
      const current=await tx.query('SELECT password_hash FROM users WHERE id=$1 AND deleted_at IS NULL FOR UPDATE',[u.id]);
      if (current.rows[0]?.password_hash!==u.password_hash) fail(401,'invalid_credentials','Повторите вход');
      const id=randomUUID(); await tx.query('INSERT INTO sessions(id,user_id,device_id,device_name) VALUES($1,$2,$3,$4)',[id,u.id,body.deviceId,body.deviceName]);
      return {...await issueTokens(tx,id),sessionId:id,user:{id:u.id,email:u.email}};
    });
  });
  app.post('/v1/auth/refresh',async request=> {
    const value=(request.body as any)?.refreshToken;
    requireValue(typeof value==='string' && value.length>=32 && value.length<=128);
    const owner=await db.pool.query('SELECT session_id FROM refresh_tokens WHERE hash=$1',[digest(value)]);
    await rateLimit(db,owner.rows[0]?`refresh-session:${owner.rows[0].session_id}`:`refresh-invalid:${digest(request.ip)}`,120,600);
    const result=await db.tx(async tx=> {
      // Блокируем сессию до токена, тот же порядок использует отзыв устройства.
      const lookup=await tx.query('SELECT session_id FROM refresh_tokens WHERE hash=$1',[digest(value)]);
      if (!lookup.rowCount) return null;
      const sr=await tx.query('SELECT s.*,u.deleted_at FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.id=$1 FOR UPDATE OF s',[lookup.rows[0].session_id]);
      const s=sr.rows[0];
      const tr=await tx.query('SELECT * FROM refresh_tokens WHERE hash=$1 FOR UPDATE',[digest(value)]),t=tr.rows[0];
      if (!s || !t || s.revoked_at || s.deleted_at || s.absolute_expires_at<=new Date() || s.idle_expires_at<=new Date() || t.expires_at<=new Date()) return null;
      if (t.used_at) { await tx.query('UPDATE sessions SET revoked_at=now() WHERE id=$1',[s.id]); return null; }
      await tx.query('UPDATE refresh_tokens SET used_at=now() WHERE hash=$1',[digest(value)]);
      await tx.query("UPDATE sessions SET last_used_at=now(),idle_expires_at=LEAST(absolute_expires_at,now()+interval '30 days') WHERE id=$1",[s.id]);
      return issueTokens(tx,s.id);
    });
    if (!result) fail(401,'unauthorized','Требуется повторный вход'); return result;
  });
  app.post('/v1/auth/logout',async request=> { const id=await authenticate(request); await db.pool.query('UPDATE sessions SET revoked_at=now() WHERE id=$1',[id.sessionId]); return {ok:true}; });
  app.get('/v1/me',async request=> { const id=await authenticate(request); return {id:id.userId,email:id.email,libraryId:id.libraryId}; });
  app.get('/v1/devices',async request=> {
    const id=await authenticate(request);
    const r=await db.pool.query('SELECT id,device_id AS "deviceId",device_name AS name,created_at AS "createdAt",last_used_at AS "lastUsedAt" FROM sessions WHERE user_id=$1 AND revoked_at IS NULL AND absolute_expires_at>now() AND idle_expires_at>now() ORDER BY created_at',[id.userId]);
    return {devices:r.rows,currentSessionId:id.sessionId};
  });
  app.delete('/v1/devices/:id',async request=> {
    const identity=await authenticate(request),id=(request.params as any).id; requireValue(uuid(id));
    const r=await db.pool.query('UPDATE sessions SET revoked_at=now() WHERE id=$1 AND user_id=$2 RETURNING id',[id,identity.userId]);
    if (!r.rowCount) fail(404,'not_found','Устройство не найдено'); return {ok:true};
  });
  app.delete('/v1/account',async request=> {
    const identity=await authenticate(request),body=request.body as any; password(body?.password);
    await limit(request,identity.email);
    const u=await db.pool.query('SELECT password_hash FROM users WHERE id=$1',[identity.userId]);
    if (!await withHash(()=>checkPassword(u.rows[0].password_hash,body.password))) fail(401,'invalid_credentials','Неверный пароль');
    await db.tx(async tx=> {
      await tx.query('SELECT id FROM libraries WHERE id=$1 FOR UPDATE',[identity.libraryId]);
      await tx.query('UPDATE users SET deleted_at=now() WHERE id=$1',[identity.userId]);
      await tx.query('UPDATE sessions SET revoked_at=now() WHERE user_id=$1',[identity.userId]);
    },true); return {ok:true};
  });
  return {authenticate};
}
