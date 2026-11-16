import type { FastifyInstance } from 'fastify';
import type { AuthService } from './auth.js';
import type { Config } from './config.js';
import type { Database } from './db.js';
import { fail, requireValue } from './errors.js';
import { digest } from './security.js';
import { lockLibrary } from './sync.js';

export const MAX_NOTE_BYTES = 8 * 1024 * 1024;
const MAX_NOTES = 10_000;

export function installNotes(app: FastifyInstance, db: Database, auth: AuthService, config: Config) {
  app.get('/v1/notes', async request => {
    const identity = await auth.authenticate(request);
    const result = await db.pool.query('SELECT id,revision FROM notes WHERE library_id=$1 ORDER BY id', [identity.libraryId]);
    return { notes: result.rows };
  });

  app.get<{ Params: { id: string } }>('/v1/notes/:id', async request => {
    const identity = await auth.authenticate(request);
    const result = await db.pool.query('SELECT revision,data FROM notes WHERE library_id=$1 AND id=$2', [identity.libraryId, request.params.id]);
    if (!result.rowCount) fail(404, 'not_found', 'Заметка не найдена');
    const { revision, data } = result.rows[0];
    return { revision, data: data.toString('base64') };
  });

  app.put<{ Params: { id: string }, Body: { baseRevision: string | null, data: string } }>(
    '/v1/notes/:id', { bodyLimit: Math.ceil(MAX_NOTE_BYTES / 3) * 4 + 256 }, async request => {
      const identity = await auth.authenticate(request);
      const id = request.params.id;
      const { baseRevision, data } = request.body;
      const bytes = Buffer.from(data, 'base64');
      requireValue(bytes.length > 0 && bytes.toString('base64') === data);
      if (bytes.length > MAX_NOTE_BYTES) fail(413, 'note_too_large', 'Заметка слишком большая для синхронизации');
      const revision = digest(bytes);
      return db.tx(async tx => {
        await lockLibrary(tx, identity);
        const current = await tx.query(
          'SELECT revision,octet_length(data) AS bytes FROM notes WHERE library_id=$1 AND id=$2',
          [identity.libraryId, id]
        );
        const previous = current.rows[0];
        if (previous?.revision === revision) return { revision };
        if ((previous?.revision ?? null) !== baseRevision) {
          fail(409, 'note_conflict', 'Заметка изменилась на другом устройстве');
        }
        const usage = (await tx.query(
          'SELECT count(*)::int AS count,COALESCE(sum(octet_length(data)),0) AS bytes FROM notes WHERE library_id=$1',
          [identity.libraryId]
        )).rows[0];
        const totalBytes = Number(usage.bytes) - (previous?.bytes ?? 0) + bytes.length;
        if ((!previous && usage.count >= MAX_NOTES) || totalBytes > Math.min(config.quotaBytes, 100 * 1024 * 1024)) {
          fail(409, 'note_quota', 'Закончилось облачное место для заметок');
        }
        await tx.query(`INSERT INTO notes(library_id,id,revision,data) VALUES($1,$2,$3,$4)
          ON CONFLICT(library_id,id) DO UPDATE SET revision=EXCLUDED.revision,data=EXCLUDED.data`,
          [identity.libraryId, id, revision, bytes]);
        return { revision };
      }, true);
    }
  );
}
