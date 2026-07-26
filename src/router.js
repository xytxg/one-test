import { ok, error, securityHeaders } from './utils/responses.js';
import { requireJson } from './security.js';
import { setupAuth, verifyPassword, createSession, getSession, destroySession, clearCookie } from './auth.js';
import { listProfiles, upsertProfile, getProfile } from './repositories/repository.js';
import { validateConfig } from './merge/validators.js';
import { checkAndMerge, k } from './services/profile-service.js';
import { appHtml } from './pages/app.js';
import { sha256 } from './utils/crypto.js';

const DEFAULT_PASSWORD = '11111111';

async function guard(request, env, csrf = false) {
  const session = await getSession(request, env);
  if (!session) return { response: error('未登录', 401) };
  if (csrf && request.headers.get('x-csrf-token') !== session.csrf) {
    return { response: error('CSRF 校验失败', 403) };
  }
  return { session };
}

function sessionResponse(session) {
  return new Response(JSON.stringify({ ok: true, session: { csrf: session.csrf } }), {
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'set-cookie': session.cookie,
      ...securityHeaders()
    }
  });
}

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

  if (path === '/api/auth/setup' && method === 'POST') {
    const body = await requireJson(request);
    if (body.response) return body.response;
    if (await env.DB.prepare("SELECT value FROM settings WHERE key='auth'").first()) {
      return error('系统已初始化', 409);
    }
    if ((body.data.password || '').length < 8) return error('密码至少 8 位');
    await setupAuth(env, body.data.password);
    return sessionResponse(await createSession(env));
  }

  if (path === '/api/auth/login' && method === 'POST') {
    const body = await requireJson(request);
    if (body.response) return body.response;
    const password = body.data.password || '';
    const authExists = await env.DB.prepare("SELECT value FROM settings WHERE key='auth'").first();

    // 新部署首次登录：使用默认密码自动初始化，不再弹出无效确认框。
    if (!authExists) {
      if (password !== DEFAULT_PASSWORD) return error('首次登录默认密码为 11111111', 401);
      await setupAuth(env, DEFAULT_PASSWORD);
      return sessionResponse(await createSession(env));
    }

    if (!await verifyPassword(env, password)) return error('密码错误', 401);
    return sessionResponse(await createSession(env));
  }

  if (path === '/api/auth/session' && method === 'GET') {
    const session = await getSession(request, env);
    return ok({ session: session ? { csrf: session.csrf } : null });
  }

  if (path === '/api/auth/logout' && method === 'POST') {
    await destroySession(request, env);
    return new Response('{"ok":true}', {
      headers: { 'content-type': 'application/json', 'set-cookie': clearCookie() }
    });
  }

  if (path === '/api/auth/password' && method === 'PUT') {
    const access = await guard(request, env, true);
    if (access.response) return access.response;
    const body = await requireJson(request);
    if (body.response) return body.response;
    const currentPassword = body.data.currentPassword || '';
    const newPassword = body.data.newPassword || '';
    if (!await verifyPassword(env, currentPassword)) return error('当前密码错误', 401);
    if (newPassword.length < 8) return error('新密码至少 8 位', 400);
    if (currentPassword === newPassword) return error('新密码不能与当前密码相同', 400);
    await setupAuth(env, newPassword);
    await destroySession(request, env);
    return new Response(JSON.stringify({ ok: true }), {
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'set-cookie': clearCookie(),
        ...securityHeaders()
      }
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

  const access = await guard(request, env, !['GET', 'HEAD'].includes(method));
  if (access.response) return access.response;

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
