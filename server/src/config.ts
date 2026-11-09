import { resolve } from 'node:path';
import { isIP } from 'node:net';

export interface Config {
  databaseUrl: string; dataDir: string; publicBaseUrl: string; port: number; authSecret: string;
  allowedEmails: string[]; publicRegistration: boolean; quotaBytes: number; maxFileBytes: number;
  smtpHost: string; smtpPort: number; smtpSecure: boolean; smtpUser: string; smtpPassword: string; mailFrom: string;
  test: boolean;
  trustedProxyCIDRs: string[]; userRequestsPerMinute: number; publicRequestsPerMinute: number;
}
function trustedProxies(value = '') {
  const list = value.split(',').map(x => x.trim()).filter(Boolean);
  for (const entry of list) {
    const [ip, prefix, extra] = entry.split('/');
    const family = isIP(ip || '');
    if (!family || extra !== undefined || (prefix !== undefined && (!/^\d+$/.test(prefix) || Number(prefix) < 1 || Number(prefix) > (family === 4 ? 32 : 128)))) {
      throw new Error('TRUSTED_PROXY_CIDRS must contain explicit IPs/CIDRs; wildcard trust is forbidden');
    }
  }
  return list;
}
function integer(value: string | undefined, fallback: number, min: number, max: number) {
  const n = value === undefined || value === '' ? fallback : Number(value);
  if (!Number.isSafeInteger(n) || n < min || n > max) throw new Error('Invalid numeric configuration');
  return n;
}
export function loadConfig(env = process.env): Config {
  const test = env.NODE_ENV === 'test';
  const databaseUrl = env.DATABASE_URL || '';
  const authSecret = env.AUTH_SECRET || '';
  const publicBaseUrl = env.PUBLIC_BASE_URL || '';
  if (!databaseUrl || authSecret.length < 64) throw new Error('DATABASE_URL and a random AUTH_SECRET (64+ characters) are required');
  const url = new URL(publicBaseUrl);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/' || (!test && url.protocol !== 'https:')) {
    throw new Error('PUBLIC_BASE_URL must be an HTTPS origin');
  }
  const allowedEmails = (env.ALLOWED_REGISTRATION_EMAILS || '').split(',').map(x => x.trim().toLowerCase()).filter(Boolean);
  const publicRegistration = env.ALLOW_PUBLIC_REGISTRATION === 'true';
  const smtpHost = env.SMTP_HOST || '';
  const mailFrom = env.MAIL_FROM || '';
  if (!test && (!smtpHost || !mailFrom)) throw new Error('SMTP_HOST and MAIL_FROM are required');
  if (!test && env.SMTP_SECURE !== 'true') throw new Error('Production SMTP must use implicit TLS (SMTP_SECURE=true)');
  return {
    databaseUrl, authSecret, publicBaseUrl: url.origin, test,
    trustedProxyCIDRs: trustedProxies(env.TRUSTED_PROXY_CIDRS),
    userRequestsPerMinute: integer(env.USER_REQUESTS_PER_MINUTE, 300, 1, 100000),
    publicRequestsPerMinute: integer(env.PUBLIC_REQUESTS_PER_MINUTE, 300, 1, 100000),
    dataDir: resolve(env.DATA_DIR || './data'), port: integer(env.PORT, 3030, 1, 65535),
    allowedEmails, publicRegistration,
    quotaBytes: integer(env.ACCOUNT_QUOTA_BYTES, 1073741824, 1048576, Number.MAX_SAFE_INTEGER),
    maxFileBytes: integer(env.MAX_FILE_BYTES, 104857600, 1, 104857600),
    smtpHost, smtpPort: integer(env.SMTP_PORT, 465, 1, 65535), smtpSecure: env.SMTP_SECURE === 'true',
    smtpUser: env.SMTP_USER || '', smtpPassword: env.SMTP_PASSWORD || '', mailFrom,
  };
}
