export { AppState } from './durable-state.js';

function appStub(env) {
  const id = env.APP_STATE.idFromName('global');
  return env.APP_STATE.get(id);
}

export default {
  async fetch(request, env) {
    return appStub(env).fetch(request);
  },

  async scheduled(_event, env, ctx) {
    const request = new Request('https://internal.invalid/__internal/cron', {
      method: 'POST',
      headers: { 'x-internal-cron': '1' }
    });
    ctx.waitUntil(appStub(env).fetch(request));
  }
};
