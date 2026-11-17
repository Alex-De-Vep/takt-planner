import { PassThrough } from 'node:stream';
import type { FastifyInstance } from 'fastify';
import type { Identity, AuthService } from './auth.js';
import type { Database, Tx } from './db.js';
import { fail } from './errors.js';

export const NOTES_CHANGED = 'takt_notes_changed';
export const TASKS_CHANGED = 'takt_tasks_changed';
type ChangeEvent = 'notes.changed' | 'tasks.changed';
const SESSION_CLOSED = 'takt_note_session_closed';

interface Subscription {
  libraryId: Identity['libraryId'];
  close(): void;
  changed(event: ChangeEvent): void;
}

export function installSyncEvents(app: FastifyInstance, db: Database, auth: AuthService) {
  const subscriptions = new Map<string, Subscription>();
  let listener: Tx | undefined;
  let connecting: Promise<void> | undefined;
  let stopping = false;

  async function listen() {
    const client = await db.pool.connect();
    const disconnect = () => {
      if (listener !== client) return;
      listener = undefined;
      for (const subscription of subscriptions.values()) subscription.close();
      client.release(true);
    };
    listener = client;
    client.on('error', disconnect);
    client.on('end', disconnect);
    client.on('notification', ({ channel, payload }) => {
      if (listener !== client || !payload) return;
      if (channel === SESSION_CLOSED) {
        subscriptions.get(payload)?.close();
      } else if (channel === NOTES_CHANGED || channel === TASKS_CHANGED) {
        const event = channel === NOTES_CHANGED ? 'notes.changed' : 'tasks.changed';
        const [libraryId, sessionId] = payload.split(':');
        for (const [subscribedSession, subscription] of subscriptions) {
          if (subscription.libraryId === libraryId && subscribedSession !== sessionId) {
            subscription.changed(event);
          }
        }
      }
    });
    try {
      await client.query(`LISTEN ${NOTES_CHANGED}; LISTEN ${TASKS_CHANGED}; LISTEN ${SESSION_CLOSED}`);
      if (stopping || listener !== client) throw new Error('Sync listener disconnected');
    } catch (error) {
      disconnect();
      throw error;
    }
  }

  app.addHook('preClose', async () => {
    stopping = true;
    for (const subscription of subscriptions.values()) subscription.close();
    await connecting?.catch(() => {});
    const client = listener;
    listener = undefined;
    client?.release(true);
  });

  app.get('/v1/notes/events', async (request, reply) => {
    const identity = await auth.authenticate(request);
    if (stopping) fail(503, 'server_unavailable', 'Сервер временно недоступен');
    if (!listener || connecting) {
      connecting ??= listen().finally(() => { connecting = undefined; });
      await connecting;
    }

    const stream = new PassThrough();
    const sessionId = identity.sessionId;
    let active = false;
    let closed = false;
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    let expiry: ReturnType<typeof setTimeout> | undefined;
    const send = (frame: string) => {
      if (!stream.write(frame)) subscription.close();
    };
    const subscription: Subscription = {
      libraryId: identity.libraryId,
      changed(event) {
        if (active && !closed) send(`event: ${event}\ndata: {}\n\n`);
      },
      close() {
        if (closed) return;
        closed = true;
        clearInterval(heartbeat);
        clearTimeout(expiry);
        reply.raw.off('close', subscription.close);
        if (subscriptions.get(sessionId) === subscription) subscriptions.delete(sessionId);
        stream.end();
      }
    };

    if (stopping || !listener) fail(503, 'server_unavailable', 'Сервер временно недоступен');
    if (reply.raw.destroyed) return;
    // Register before revalidating so revocation also reaches a subscription during setup.
    const previous = subscriptions.get(sessionId);
    previous?.close();
    subscriptions.set(sessionId, subscription);
    reply.raw.once('close', subscription.close);

    try {
      const confirmed = await auth.authenticate(request, true);
      if (reply.raw.destroyed) return;
      const remaining = confirmed.expiresAt.getTime() - Date.now();
      if (stopping || !listener) fail(503, 'server_unavailable', 'Сервер временно недоступен');
      if (closed || remaining <= 0) fail(401, 'unauthorized', 'Требуется повторный вход');
      active = true;
      heartbeat = setInterval(() => send(': keep-alive\n\n'), 10_000).unref();
      expiry = setTimeout(subscription.close, remaining).unref();
      send('event: ready\ndata: {}\n\n');
      return reply.type('text/event-stream; charset=utf-8').header('X-Accel-Buffering', 'no').send(stream);
    } catch (error) {
      subscription.close();
      throw error;
    }
  });
}
