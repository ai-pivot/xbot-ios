import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ComplianceService } from './server.mjs';

async function listen(server) { await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); return `http://127.0.0.1:${server.address().port}`; }
async function setup(t, policy = null, legacy = false) {
  const directory = await mkdtemp(join(tmpdir(), 'xbot-compliance-test-'));
  const upstream = createServer(async (request, response) => {
    let raw = ''; for await (const chunk of request) raw += chunk;
    const body = JSON.parse(raw || '{}');
    let data = {}, status = 200;
    if (request.url === '/api/auth/login') {
      if (body.username !== 'fixture-user' || body.password !== 'fixture-password') status = 401;
      else { data = { user_id: 1 }; response.setHeader('set-cookie', 'fixture=temporary-secret; Path=/; HttpOnly'); }
    } else if (request.url === '/api/session-tree') {
      if (request.headers.cookie !== 'fixture=session-secret') status = 401;
      else data = { sessions: [{ chat_id: 'owned', channel: 'web', children: [{ chat_id: 'child', channel: 'web' }] }] };
    }
    response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(legacy ? { ok: status === 200, ...data } : { ok: status === 200, data }));
  });
  const origin = await listen(upstream), service = new ComplianceService({ upstream: origin, stateDirectory: directory, policy });
  const server = service.httpServer(), base = await listen(server);
  t.after(async () => { server.closeAllConnections(); upstream.closeAllConnections(); await Promise.all([new Promise(resolve => server.close(resolve)), new Promise(resolve => upstream.close(resolve))]); await rm(directory, { recursive: true, force: true }); });
  async function call(path, body = {}, headers = {}) {
    const response = await fetch(base + '/api/mobile/' + path, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });
    return { status: response.status, value: await response.json() };
  }
  return { directory, call };
}

test('deletion reauthenticates, returns pending receipt, deduplicates and never stores passwords or cookies', async t => {
  const { directory, call } = await setup(t);
  const body = { username: 'fixture-user', password: 'fixture-password', request_id: randomUUID() };
  assert.equal((await call('account-deletion', { ...body, password: 'wrong' })).status, 401);
  const attempts = await Promise.all([call('account-deletion', body), call('account-deletion', body)]);
  assert.equal(attempts[0].status, 200); assert.equal(attempts[0].value.data.status, 'pending');
  assert.equal(attempts[0].value.data.id, attempts[1].value.data.id);
  const receipt = attempts[0].value.data;
  assert.ok(Date.parse(receipt.deadline) > Date.now());
  assert.deepEqual((await call('status', { id: receipt.id })).value.data, receipt);
  let stored = ''; for (const path of await readdir(directory)) stored += await readFile(join(directory, path), 'utf8');
  for (const secret of ['fixture-password', 'temporary-secret', 'session-secret']) assert.equal(stored.includes(secret), false);
  assert.equal((await call('status', { id: '../private' })).status, 404);
});

test('reports require an authenticated accessible session and omit content by default', async t => {
  const { directory, call } = await setup(t);
  const body = { request_id: randomUUID(), chat_id: 'owned', channel: 'web', turn_id: 1, reason: 'unsafe content', detail: '' };
  assert.equal((await call('reports', body)).status, 401);
  assert.equal((await call('reports', { ...body, chat_id: 'foreign' }, { cookie: 'fixture=session-secret' })).status, 403);
  const result = await call('reports', body, { cookie: 'fixture=session-secret' });
  assert.equal(result.value.data.status, 'received');
  const record = JSON.parse(await readFile(join(directory, result.value.data.id + '.json'), 'utf8'));
  assert.equal(Object.hasOwn(record, 'content'), false); assert.equal(Object.hasOwn(record, 'cookie'), false);
  const explicit = await call('reports', { ...body, request_id: randomUUID(), chat_id: 'child', content: 'User explicitly opted in' }, { cookie: 'fixture=session-secret' });
  assert.equal(explicit.status, 200);
  assert.equal(JSON.parse(await readFile(join(directory, explicit.value.data.id + '.json'), 'utf8')).content, 'User explicitly opted in');
});

test('cross-origin requests, malformed bodies and oversized requests are rejected', async t => {
  const { call } = await setup(t);
  assert.equal((await call('reports', {}, { origin: 'https://evil.test' })).status, 403);
  assert.equal((await call('reports', { detail: 'x'.repeat(40000) })).status, 413);
  assert.equal((await call('policy')).status, 404); // Optional, no fabricated operator or providers.
  assert.equal((await call('policy', null)).status, 400);
});

test('public policy only publishes declared fields, never accidental configuration secrets', async t => {
  const { call } = await setup(t, { version: '1', operator_name: 'Fixture', privacy_url: 'https://example.test/privacy', support_url: 'https://example.test/support',
    providers: [{ name: 'Fixture local model', privacy_url: 'https://example.test/model-privacy', api_key: 'DO_NOT_PUBLISH' }], retention: '7 days', deletion_days: 7, content_filtering: false, password: 'DO_NOT_PUBLISH' });
  const response = await call('policy'); assert.equal(response.status, 200);
  assert.equal(JSON.stringify(response.value).includes('DO_NOT_PUBLISH'), false);
});

test('upstream credentials cannot be sent to plaintext public hosts', () => {
  assert.throws(() => new ComplianceService({ upstream: 'http://public.test', stateDirectory: '/tmp/unused' }));
  assert.throws(() => new ComplianceService({ upstream: 'https://user:pass@public.test', stateDirectory: '/tmp/unused' }));
});

test('legacy unwrapped xbot authentication remains supported', async t => {
  const { call } = await setup(t, null, true);
  const result = await call('account-deletion', { username: 'fixture-user', password: 'fixture-password', request_id: randomUUID() });
  assert.equal(result.status, 200); assert.equal(result.value.data.status, 'pending');
});

test('completion stays pending without explicit operator acknowledgement and status exposes no account data', async t => {
  const { call, directory } = await setup(t);
  const result = await call('account-deletion', { username: 'fixture-user', password: 'fixture-password', request_id: randomUUID() });
  const id = result.value.data.id, cli = fileURLToPath(new URL('./manage.mjs', import.meta.url));
  assert.throws(() => execFileSync(process.execPath, [cli, directory, 'complete-deletion', id], { stdio: 'pipe' }));
  assert.equal((await call('status', { id })).value.data.status, 'pending');
  execFileSync(process.execPath, [cli, directory, 'complete-deletion', id, '--confirm-erasure'], { stdio: 'pipe' });
  const status = (await call('status', { id })).value.data;
  assert.equal(status.status, 'deleted'); assert.equal(Object.hasOwn(status, 'username'), false);
  const record = JSON.parse(await readFile(join(directory, `${id}.json`), 'utf8'));
  assert.equal(Object.hasOwn(record, 'username'), false);
});
