import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function failure(status, message) { return Object.assign(new Error(message), { status }); }
function unwrap(result) { if (result?.ok === false) throw failure(401, 'authentication_failed'); return result?.ok === true && Object.hasOwn(result, 'data') ? result.data : result; }
function text(value, max, required = true) {
  if (typeof value !== 'string' || value.length > max || (required && !value.trim())) throw failure(400, 'invalid_request');
  return value;
}
function requestKey(body, identity, kind) {
  const id = text(body.request_id, 64);
  if (!/^[a-f0-9-]{32,64}$/i.test(id)) throw failure(400, 'invalid_request_id');
  return createHash('sha256').update(JSON.stringify([kind, identity, id])).digest('hex');
}
async function jsonBody(request) {
  let raw = ''; for await (const chunk of request) { raw += chunk; if (Buffer.byteLength(raw) > 32768) throw failure(413, 'request_too_large'); }
  try {
    const value = JSON.parse(raw || '{}');
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('object_required');
    return value;
  } catch { throw failure(400, 'invalid_json'); }
}
function publicPolicy(policy) {
  if (!policy) return null; // Self-hosted clients do not require a policy server.
  const secure = raw => { const url = new URL(raw); if (url.protocol !== 'https:' || url.username || url.password) throw new Error('Policy URLs must use HTTPS'); };
  for (const key of ['version', 'operator_name', 'retention']) if (!policy[key]?.trim()) throw new Error('Incomplete policy');
  secure(policy.privacy_url); secure(policy.support_url);
  if (!Array.isArray(policy.providers) || !Number.isInteger(policy.deletion_days) || policy.deletion_days < 1 || policy.deletion_days > 30) throw new Error('Incomplete policy');
  for (const provider of policy.providers) { if (!provider.name?.trim()) throw new Error('Missing provider'); secure(provider.privacy_url); }
  // This declaration is an operational commitment, not a moderation implementation.
  if (typeof policy.content_filtering !== 'boolean') throw new Error('Declare actual content filtering status');
  return {
    version: policy.version, operator_name: policy.operator_name, privacy_url: policy.privacy_url, support_url: policy.support_url,
    providers: policy.providers.map(provider => ({ name: provider.name, privacy_url: provider.privacy_url })),
    retention: policy.retention, deletion_days: policy.deletion_days, content_filtering: policy.content_filtering,
  };
}

export class ComplianceService {
  constructor({ upstream, stateDirectory, deletionDays = 7, policy = null }) {
    const url = new URL(upstream);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.search || url.hash ||
        (url.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))) throw new Error('Use HTTPS or a loopback upstream');
    if (!Number.isInteger(deletionDays) || deletionDays < 1 || deletionDays > 30) throw new Error('Invalid deletion deadline');
    this.upstream = url.href.replace(/\/+$/, ''); this.directory = resolve(stateDirectory); this.policy = publicPolicy(policy);
    this.days = policy?.deletion_days ?? deletionDays; this.queue = Promise.resolve(); this.rates = new Map();
  }
  async upstreamCall(path, { cookie, body }) {
    const response = await fetch(this.upstream + path, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(15000),
      headers: { 'content-type': 'application/json', ...(cookie ? { cookie } : {}) }, body: JSON.stringify(body ?? {}) });
    if (!response.ok) throw failure(response.status === 401 || response.status === 403 ? 401 : 502, 'upstream_request_failed');
    return { data: unwrap(await response.json()), cookies: response.headers.getSetCookie().map(value => value.split(';')[0]).join('; ') };
  }
  async persist(kind, key, value) {
    const work = this.queue.catch(() => {}).then(async () => {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const index = join(this.directory, `index-${key}.json`);
      try { const { id } = JSON.parse(await readFile(index, 'utf8')); return JSON.parse(await readFile(join(this.directory, `${id}.json`), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      const id = randomBytes(32).toString('hex'), created = new Date();
      const record = { id, kind, created: created.toISOString(), status: kind === 'deletion' ? 'pending' : 'received',
        deadline: new Date(created.getTime() + this.days * 86400000).toISOString(), ...value };
      const path = join(this.directory, `${id}.json`), temporary = path + '.tmp';
      await writeFile(temporary, JSON.stringify(record), { mode: 0o600 }); await rename(temporary, path);
      await writeFile(index, JSON.stringify({ id }), { mode: 0o600 });
      return record;
    });
    this.queue = work; return work;
  }
  receipt(record) { return { id: record.id, status: record.status, deadline: record.deadline, ...(record.completed ? { completed: record.completed } : {}) }; }
  async deleteAccount(body) {
    const username = text(body.username, 64).trim(), password = text(body.password, 128);
    const key = requestKey(body, username, 'deletion');
    const authenticated = await this.upstreamCall('/api/auth/login', { body: { username, password } });
    if (!authenticated.cookies || !Number.isSafeInteger(authenticated.data?.user_id) || authenticated.data.user_id <= 0) throw failure(401, 'authentication_failed');
    try {
      const record = await this.persist('deletion', key, { username });
      return this.receipt(record);
    } finally {
      // Never persist a password or Cookie. Reauthentication uses a short-lived
      // upstream session which is closed without altering the app's session.
      await this.upstreamCall('/api/auth/logout', { cookie: authenticated.cookies }).catch(() => {});
    }
  }
  async report(body, cookie) {
    if (!cookie) throw failure(401, 'authentication_required');
    const chat = text(body.chat_id, 1024), channel = text(body.channel, 128);
    const { data: tree } = await this.upstreamCall('/api/session-tree', { cookie });
    const owned = nodes => Array.isArray(nodes) && nodes.some(node => (node.chat_id === chat && (node.channel || 'web') === channel) || owned(node.children));
    if (!owned([...(tree.sessions ?? []), ...(tree.orphan_subagents ?? [])])) throw failure(403, 'session_not_accessible');
    const identity = createHash('sha256').update(cookie).digest('hex');
    const key = requestKey(body, identity, 'report');
    if (!Number.isSafeInteger(body.turn_id) || body.turn_id < 0) throw failure(400, 'invalid_turn');
    const value = { chat_id: chat, channel, turn_id: body.turn_id, reason: text(body.reason, 200), detail: text(body.detail ?? '', 1000, false) };
    if (Object.hasOwn(body, 'content')) value.content = text(body.content, 8000, false);
    return this.receipt(await this.persist('report', key, value));
  }
  httpServer() {
    return createServer(async (request, response) => {
      const reply = (status, data, message) => {
        response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
        response.end(JSON.stringify({ ok: status < 400, data: data ?? null, ...(message ? { error: { message } } : {}) }));
      };
      try {
        // No CORS. Reject cross-origin browser submissions even behind a proxy.
        if (request.headers.origin || request.headers['sec-fetch-site'] === 'cross-site') throw failure(403, 'native_client_only');
        if (request.method !== 'POST') throw failure(405, 'post_required');
        const now = Date.now(), peer = request.socket.remoteAddress;
        if (this.rates.size > 10000) for (const [key, rate] of this.rates) if (now - rate.at > 60000) this.rates.delete(key);
        const rate = this.rates.get(peer);
        if (!rate || now - rate.at > 60000) this.rates.set(peer, { at: now, count: 1 });
        else if (++rate.count > 120) throw failure(429, 'too_many_requests');
        const body = await jsonBody(request);
        if (request.url === '/api/mobile/policy' && this.policy) { reply(200, this.policy); return; }
        if (request.url === '/api/mobile/account-deletion') { reply(200, await this.deleteAccount(body)); return; }
        if (request.url === '/api/mobile/reports') { reply(200, await this.report(body, request.headers.cookie)); return; }
        if (request.url === '/api/mobile/status') {
          const id = text(body.id, 64); if (!/^[a-f0-9]{64}$/.test(id)) throw failure(404, 'not_found');
          let record; try { record = JSON.parse(await readFile(join(this.directory, `${id}.json`), 'utf8')); } catch { throw failure(404, 'not_found'); }
          reply(200, this.receipt(record)); return; // Receipt is an unguessable capability; no personal data is returned.
        }
        throw failure(404, 'not_found');
      } catch (error) { reply(error.status ?? 503, null, error.status ? error.message : 'service_unavailable'); }
    });
  }
}

async function main() {
  if (!process.env.XBOT_COMPLIANCE_CONFIG) throw new Error('Set XBOT_COMPLIANCE_CONFIG');
  const config = JSON.parse(await readFile(process.env.XBOT_COMPLIANCE_CONFIG, 'utf8'));
  const service = new ComplianceService(config), server = service.httpServer();
  server.listen(config.port ?? 18883, '127.0.0.1', () => console.log('compliance_listening_on_loopback'));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close());
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().catch(() => { console.error('compliance_startup_failed_check_private_config'); process.exitCode = 1; });
