import type { FastifyInstance } from 'fastify';
import type { AuthService } from './auth.js';
import type { Config } from './config.js';
import type { Database } from './db.js';
import { ApiError, fail, requireValue } from './errors.js';
import { digest, queueMail } from './security.js';

interface Submission {
  submissionId: string;
  subject?: string;
  message: string;
  replyEmail?: string;
  platform: 'android' | 'macos' | 'windows';
  appVersion: string;
  appBuild: string;
  osVersion: string;
  deviceTime: string;
}

function receipt(number: string, receivedAt: Date) {
  return { code: `TAKT-${number.padStart(6, '0')}`, receivedAt: receivedAt.toISOString() };
}

export function installSupport(app: FastifyInstance, db: Database, auth: AuthService, config: Config) {
  app.post<{ Body: Submission }>('/v1/support/requests', { bodyLimit: 32768 }, async request => {
    const { userId } = await auth.authenticate(request);
    const { submissionId, replyEmail, platform, appVersion, appBuild, osVersion, deviceTime } = request.body;
    const subject = request.body.subject?.trim();
    const message = request.body.message.trim();
    requireValue(subject !== '', 'invalid_support_subject', 'Укажите тему обращения');
    requireValue(message && !message.includes('\0'), 'invalid_support_message', 'Опишите проблему');
    const content = [message, platform, appVersion, appBuild, osVersion, deviceTime];
    // Keep the fingerprint for retries of requests accepted before subject and replyEmail were introduced.
    if (subject !== undefined || replyEmail !== undefined) content.push(subject ?? '', replyEmail ?? '');
    const contentDigest = digest(JSON.stringify(content));
    return db.tx(async tx => {
      // Serialize new requests and retries for this account without blocking other accounts.
      const user = (await tx.query('SELECT email FROM users WHERE id=$1 AND deleted_at IS NULL FOR NO KEY UPDATE', [userId])).rows[0];
      if (!user) fail(401, 'sign_in_required', 'Войдите в аккаунт');
      const existing = (await tx.query(
        'SELECT number, content_digest, received_at FROM support_requests WHERE user_id=$1 AND submission_id=$2',
        [userId, submissionId],
      )).rows[0];
      if (existing) {
        if (existing.content_digest !== contentDigest) fail(409, 'submission_reused', 'Это обращение уже принято с другими данными');
        return receipt(existing.number, existing.received_at);
      }
      const recipient = config.supportEmail;
      if (!recipient) fail(503, 'support_unavailable', 'Канал поддержки пока недоступен');
      const recent = (await tx.query(`
        SELECT GREATEST(1, ceil(extract(epoch FROM min(received_at) + interval '1 hour' - now())))::integer AS wait
        FROM support_requests WHERE user_id=$1 AND received_at>now()-interval '1 hour'
        HAVING count(*) >= 5
      `, [userId])).rows[0];
      if (recent) throw new ApiError(429, 'rate_limited', 'Слишком много обращений. Попробуйте позже', recent.wait);
      const saved = (await tx.query(`
        INSERT INTO support_requests (user_id, submission_id, content_digest)
        VALUES ($1, $2, $3) RETURNING number, received_at
      `, [userId, submissionId, contentDigest])).rows[0];
      const result = receipt(saved.number, saved.received_at);
      const text = [
        `Код обращения: ${result.code}`,
        `Адрес для ответа: ${replyEmail ?? user.email}`,
        `Версия Takt: ${appVersion} (сборка ${appBuild})`,
        `ОС: ${platform} ${osVersion}`,
        `Время на устройстве: ${deviceTime}`,
        `Получено сервером: ${result.receivedAt}`,
        '',
        message,
      ].join('\n');
      const mailSubject = `[${result.code}] ${subject ?? 'Обращение в поддержку Takt'}`;
      await queueMail(tx, config.authSecret, recipient, mailSubject, text, undefined, userId, replyEmail);
      return result;
    }, true);
  });
}
