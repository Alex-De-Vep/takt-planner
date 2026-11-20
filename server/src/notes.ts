import type { FastifyInstance } from 'fastify';
import type { AuthService } from './auth.js';
import type { Config } from './config.js';
import type { Database, Tx } from './db.js';
import { fail, requireValue } from './errors.js';
import { digest } from './security.js';
import { NOTES_CHANGED } from './syncEvents.js';
import { lockLibrary } from './sync.js';

export const NOTE_FORMAT_VERSION = 1;
export const MAX_NOTE_BYTES = 8 * 1024 * 1024;
const MAX_NOTES = 10_000;
const TRASH_RETENTION_SECONDS = 30 * 24 * 60 * 60;
const FOUNDATION_EPOCH = 978_307_200;

function trashCutoff(): number {
  return Date.now() / 1000 - FOUNDATION_EPOCH - TRASH_RETENTION_SECONDS;
}

interface StoredNoteData {
  deletedAt?: unknown;
  purged?: unknown;
  text?: unknown;
  title?: unknown;
  document?: unknown;
  richText?: unknown;
  lastVoiceTranscriptID?: unknown;
}

function parseNote(bytes: Buffer): StoredNoteData | null {
  // Earlier clients and integrations could store arbitrary opaque payloads.
  try {
    const body: unknown = JSON.parse(bytes.toString('utf8'));
    return body && typeof body === 'object' ? body : null;
  } catch {
    return null;
  }
}

// Called under the same library lock that protects note writes.
export async function purgeExpiredNotes(tx: Tx, libraryID: string) {
  const expired = await tx.query<{ id: string; deleted_at: number; format_version: number }>(
    'SELECT id,deleted_at,format_version FROM notes WHERE library_id=$1 AND NOT purged AND deleted_at<=$2',
    [libraryID, trashCutoff()]
  );
  for (const { id, deleted_at, format_version } of expired.rows) {
    const data = Buffer.from(JSON.stringify({
      id, folder: 'inbox', title: '', text: '', document: '', pinned: false,
      createdAt: deleted_at, updatedAt: deleted_at, deletedAt: deleted_at, purged: true,
      ...(format_version === NOTE_FORMAT_VERSION ? { richText: { version: NOTE_FORMAT_VERSION, spans: [] } } : {})
    }));
    await tx.query('UPDATE notes SET data=$3,revision=$4,purged=true WHERE library_id=$1 AND id=$2',
      [libraryID, id, data, digest(data)]);
  }
  if (expired.rowCount) await tx.query('SELECT pg_notify($1,$2)', [NOTES_CHANGED, libraryID]);
}

function noteFormat(body: StoredNoteData | null): number {
  if (body?.richText == null) return 0;
  const rich = body.richText;
  if (typeof rich !== 'object' || !('version' in rich) || rich.version !== NOTE_FORMAT_VERSION) {
    fail(400, 'note_format_unsupported', 'Формат заметки не поддерживается');
  }
  requireValue('spans' in rich && Array.isArray(rich.spans)
    && 'text' in body && typeof body.text === 'string'
    && 'document' in body && body.document === '');
  return NOTE_FORMAT_VERSION;
}

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
      const note = parseNote(bytes);
      const format = noteFormat(note);
      const deletedAt = typeof note?.deletedAt === 'number' && Number.isFinite(note.deletedAt) ? note.deletedAt : null;
      const purged = note?.purged === true;
      if (purged) {
        requireValue(deletedAt !== null && note.title === '' && note.text === '' && note.document === ''
          && note.lastVoiceTranscriptID == null && (note.richText == null ||
            (note.richText as { spans: unknown[] }).spans.length === 0));
      }
      const revision = digest(bytes);
      return db.tx(async tx => {
        await lockLibrary(tx, identity);
        const current = await tx.query(
          'SELECT revision,format_version,purged,deleted_at,octet_length(data) AS bytes FROM notes WHERE library_id=$1 AND id=$2',
          [identity.libraryId, id]
        );
        const previous = current.rows[0];
        if (previous?.revision === revision) return { revision };
        if (previous?.purged || (previous?.deleted_at != null && previous.deleted_at <= trashCutoff() && !purged)
            || (previous?.revision ?? null) !== baseRevision) {
          fail(409, 'note_conflict', 'Заметка изменилась на другом устройстве');
        }
        if (previous && previous.format_version > format) {
          fail(409, 'note_format_requires_update', 'Обновите приложение, чтобы сохранить форматирование заметки');
        }
        const usage = (await tx.query(
          'SELECT count(*)::int AS count,COALESCE(sum(octet_length(data)),0) AS bytes FROM notes WHERE library_id=$1',
          [identity.libraryId]
        )).rows[0];
        const totalBytes = Number(usage.bytes) - (previous?.bytes ?? 0) + bytes.length;
        if ((!previous && usage.count >= MAX_NOTES) || totalBytes > Math.min(config.quotaBytes, 100 * 1024 * 1024)) {
          fail(409, 'note_quota', 'Закончилось облачное место для заметок');
        }
        await tx.query(`INSERT INTO notes(library_id,id,revision,data,format_version,deleted_at,purged) VALUES($1,$2,$3,$4,$5,$6,$7)
          ON CONFLICT(library_id,id) DO UPDATE SET
            revision=EXCLUDED.revision,data=EXCLUDED.data,format_version=EXCLUDED.format_version,
            deleted_at=EXCLUDED.deleted_at,purged=EXCLUDED.purged`,
          [identity.libraryId, id, revision, bytes, format, deletedAt, purged]);
        await tx.query('SELECT pg_notify($1,$2)', [NOTES_CHANGED, `${identity.libraryId}:${identity.sessionId}`]);
        return { revision };
      }, true);
    }
  );
}
