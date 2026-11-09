import pg, { type PoolClient } from 'pg';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { fail } from './errors.js';
export type Tx = PoolClient;
export class Database {
  readonly pool: pg.Pool;
  constructor(url: string) { this.pool = new pg.Pool({ connectionString: url, max: 10, connectionTimeoutMillis: 10000, statement_timeout: 30000 }); }
  async tx<T>(fn: (tx: Tx) => Promise<T>, write = false): Promise<T> {
    const tx = await this.pool.connect();
    try {
      await tx.query('BEGIN');
      if (write) {
        await tx.query('SELECT pg_advisory_xact_lock_shared(917403)');
        const r = await tx.query("SELECT value FROM settings WHERE key='maintenance'");
        if (r.rows[0]?.value === true) fail(503, 'maintenance', 'Сервер временно обслуживается');
      }
      const result = await fn(tx);
      await tx.query('COMMIT');
      return result;
    } catch (error) { await tx.query('ROLLBACK'); throw error; }
    finally { tx.release(); }
  }
  async migrate() {
    const dir = fileURLToPath(new URL('../migrations/', import.meta.url));
    const tx = await this.pool.connect();
    try {
      await tx.query('SELECT pg_advisory_lock(917402)');
      await tx.query('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
      for (const name of (await readdir(dir)).filter(x => /^\d+.*\.sql$/.test(x)).sort()) {
        if ((await tx.query('SELECT 1 FROM schema_migrations WHERE name=$1', [name])).rowCount) continue;
        await tx.query('BEGIN');
        try { await tx.query(await readFile(`${dir}/${name}`, 'utf8')); await tx.query('INSERT INTO schema_migrations(name) VALUES($1)', [name]); await tx.query('COMMIT'); }
        catch (error) { await tx.query('ROLLBACK'); throw error; }
      }
    } finally { await tx.query('SELECT pg_advisory_unlock(917402)'); tx.release(); }
  }
  async maintenance(enabled: boolean) {
    return this.tx(async tx => {
      await tx.query('SELECT pg_advisory_xact_lock(917403)');
      await tx.query("UPDATE settings SET value=$1::jsonb WHERE key='maintenance'", [JSON.stringify(enabled)]);
    });
  }
  async close() { await this.pool.end(); }
}
