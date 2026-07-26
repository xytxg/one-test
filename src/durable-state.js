import { route } from './router.js';
import { listProfiles } from './repositories/repository.js';
import { checkAndMerge } from './services/profile-service.js';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS profiles (id TEXT PRIMARY KEY,name TEXT NOT NULL,upstream_url TEXT NOT NULL,access_token TEXT,merge_policy TEXT NOT NULL DEFAULT '{}',enabled INTEGER NOT NULL DEFAULT 1,interval_minutes INTEGER NOT NULL DEFAULT 30,current_version_id TEXT,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS versions (id TEXT PRIMARY KEY,profile_id TEXT NOT NULL,remote_hash TEXT,local_hash TEXT,merged_hash TEXT,added_count INTEGER DEFAULT 0,modified_count INTEGER DEFAULT 0,deleted_count INTEGER DEFAULT 0,conflict_count INTEGER DEFAULT 0,status TEXT NOT NULL,error_message TEXT,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS conflicts (id TEXT PRIMARY KEY,version_id TEXT NOT NULL,section TEXT,item_key TEXT,previous_value TEXT,remote_value TEXT,local_value TEXT,resolution TEXT,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,resolved_at TEXT);
CREATE TABLE IF NOT EXISTS merge_logs (id INTEGER PRIMARY KEY AUTOINCREMENT,profile_id TEXT,level TEXT NOT NULL,message TEXT NOT NULL,details TEXT,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS audit_logs (id INTEGER PRIMARY KEY AUTOINCREMENT,action TEXT NOT NULL,ip_hash TEXT,user_agent TEXT,details TEXT,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE INDEX IF NOT EXISTS idx_versions_profile ON versions(profile_id,created_at DESC);
CREATE INDEX IF NOT EXISTS idx_conflicts_version ON conflicts(version_id);
CREATE INDEX IF NOT EXISTS idx_logs_profile ON merge_logs(profile_id,created_at DESC);
`;

class StatementCompat {
  constructor(sqlApi, query) {
    this.sqlApi = sqlApi;
    this.query = query;
    this.params = [];
  }
  bind(...params) {
    this.params = params;
    return this;
  }
  _rows() {
    return this.sqlApi.exec(this.query, ...this.params).toArray();
  }
  async first(column) {
    const row = this._rows()[0] ?? null;
    return column && row ? row[column] ?? null : row;
  }
  async all() {
    return { success: true, results: this._rows() };
  }
  async run() {
    const cursor = this.sqlApi.exec(this.query, ...this.params);
    cursor.toArray();
    return {
      success: true,
      meta: {
        changes: Number(cursor.rowsWritten || 0),
        rows_read: Number(cursor.rowsRead || 0),
        rows_written: Number(cursor.rowsWritten || 0)
      }
    };
  }
}

class D1Compat {
  constructor(sqlApi) {
    this.sqlApi = sqlApi;
  }
  prepare(query) {
    return new StatementCompat(this.sqlApi, query);
  }
}

class KVCompat {
  constructor(storage) {
    this.storage = storage;
  }
  _key(key) {
    return `blob:${key}`;
  }
  async get(key, options = undefined) {
    const record = await this.storage.get(this._key(key));
    if (record == null) return null;
    if (record.expiresAt && record.expiresAt <= Date.now()) {
      await this.storage.delete(this._key(key));
      return null;
    }
    const value = record.value;
    if (options?.type === 'json') {
      try { return JSON.parse(value); } catch { return null; }
    }
    return value;
  }
  async put(key, value, options = {}) {
    const ttl = Number(options.expirationTtl || 0);
    await this.storage.put(this._key(key), {
      value: typeof value === 'string' ? value : String(value),
      expiresAt: ttl > 0 ? Date.now() + ttl * 1000 : null
    });
  }
  async delete(key) {
    await this.storage.delete(this._key(key));
  }
}

export class AppState {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.ready = ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(SCHEMA);
    });
  }

  runtimeEnv() {
    return {
      ...this.env,
      DB: new D1Compat(this.ctx.storage.sql),
      CONFIG_STORE: new KVCompat(this.ctx.storage)
    };
  }

  async fetch(request) {
    await this.ready;
    const url = new URL(request.url);
    const env = this.runtimeEnv();

    if (url.pathname === '/__internal/cron') {
      if (request.headers.get('x-internal-cron') !== '1') {
        return new Response('Forbidden', { status: 403 });
      }
      const results = [];
      for (const profile of await listProfiles(env.DB)) {
        if (!profile.enabled) continue;
        try {
          results.push({ id: profile.id, result: await checkAndMerge(profile.id, env) });
        } catch (error) {
          await env.DB.prepare('INSERT INTO merge_logs(profile_id,level,message,details,created_at) VALUES(?,?,?,?,CURRENT_TIMESTAMP)')
            .bind(profile.id, 'error', '定时更新失败', JSON.stringify({ message: error.message }))
            .run();
          results.push({ id: profile.id, error: error.message });
        }
      }
      return Response.json({ ok: true, results });
    }

    try {
      return await route(request, env);
    } catch (error) {
      console.error('Unhandled application error', error);
      return Response.json(
        { ok: false, error: { code: 'INTERNAL_ERROR', message: '服务器内部错误' } },
        { status: 500 }
      );
    }
  }
}
