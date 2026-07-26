import { ok, error, securityHeaders } from './utils/responses.js';
import { requireJson } from './security.js';
import { listProfiles, upsertProfile, getProfile } from './repositories/repository.js';
import { validateConfig } from './merge/validators.js';
import { checkAndMerge, k } from './services/profile-service.js';
import { appHtml } from './pages/app.js';
import { sha256 } from './utils/crypto.js';

export async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (!path.startsWith('/api/') && !path.startsWith('/profile/')) {
    return new Response(appHtml(), {
      headers: securityHeaders({
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store'
      })
    });
  }

  if (/^\/profile\/[^/]+\/config$/.test(path)) {
    const id = path.split('/')[2];
    const profile = await getProfile(env.DB, id);
    if (!profile) return new Response('Profile not found', { status: 404 });
    if (profile.access_token && url.searchParams.get('token') !== profile.access_token) {
      return new Response('Unauthorized', { status: 401 });
    }
    const content = await env.CONFIG_STORE.get(k(id, 'merged'));
    if (!content) return new Response('No published profile', { status: 404 });
    const etag = '"' + await sha256(content) + '"';
    if (request.headers.get('if-none-match') === etag) {
      return new Response(null, { status: 304, headers: { etag } });
    }
    const managed = `#!MANAGED-CONFIG ${url.origin}${path}${profile.access_token ? `?token=${encodeURIComponent(profile.access_token)}` : ''} interval=${Math.max(60, (profile.interval_minutes || 30) * 60)} strict=true\n` + content.replace(/^\s*#!MANAGED-CONFIG.*\n?/gmi, '');
    return new Response(managed, {
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        etag,
        'cache-control': 'private, no-cache',
        'x-content-type-options': 'nosniff'
      }
    });
  }

  if (path === '/api/dashboard') {
    const [a, b, c, d] = await Promise.all([
      env.DB.prepare('SELECT COUNT(*) n FROM profiles').first(),
      env.DB.prepare("SELECT COUNT(*) n FROM versions WHERE status='published'").first(),
      env.DB.prepare('SELECT COUNT(*) n FROM conflicts WHERE resolution IS NULL').first(),
      env.DB.prepare('SELECT COUNT(*) n FROM merge_logs').first()
    ]);
    return ok({ stats: { profiles: a.n, versions: b.n, conflicts: c.n, logs: d.n } });
  }

  if (path === '/api/profiles' && method === 'GET') return ok({ profiles: await listProfiles(env.DB) });
  if (path === '/api/profiles' && method === 'POST') {
    const body = await requireJson(request);
    if (body.response) return body.response;
    const profile = await upsertProfile(env.DB, {
      ...body.data,
      merge_policy: JSON.stringify(body.data.merge_policy || {})
    });
    return ok({ profile });
  }

  const local = path.match(/^\/api\/profiles\/([^/]+)\/local$/);
  if (local && method === 'GET') return ok({ content: await env.CONFIG_STORE.get(k(local[1], 'local')) || '' });
  if (local && method === 'PUT') {
    const body = await requireJson(request, Number(env.MAX_PROFILE_BYTES || 2097152));
    if (body.response) return body.response;
    const validation = validateConfig(body.data.content || '');
    if (validation.valid) await env.CONFIG_STORE.put(k(local[1], 'local'), body.data.content);
    return ok({ validation });
  }

  const check = path.match(/^\/api\/profiles\/([^/]+)\/check$/);
  if (check && method === 'POST') {
    try { return ok(await checkAndMerge(check[1], env)); }
    catch (cause) { return error(cause.message, 502); }
  }

  if (path === '/api/versions') {
    const rows = (await env.DB.prepare('SELECT * FROM versions ORDER BY created_at DESC LIMIT 100').all()).results || [];
    return ok({ versions: rows });
  }

  return error('接口不存在', 404);
}
