import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { createServer } from 'node:http2';
import { mkdtemp, readFile, stat, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { APNSClient, makeProviderToken, notificationPayload } from './apns.mjs';
import { authorized, validateRegistration, routeMatches, noticeForEvent, SSEDecoder } from './protocol.mjs';
import { PushRelay, XbotClient } from './server.mjs';

const origin = 'https://xbot.example.com';
const token = 'ab'.repeat(32);
const registration = { server: origin, chat_id: 'chat', channel: 'web', device_token: token };
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const key = { teamId: 'TESTTEAM00', keyId: 'TESTKEY000', privateKey };

test('ES256 provider token uses APNs claims and a valid P1363 signature', () => {
  const jwt = makeProviderToken({ ...key, now: 123456 });
  const [header, payload, signature] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: key.keyId });
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url')), { iss: key.teamId, iat: 123456 });
  assert.equal(verify('sha256', Buffer.from(header + '.' + payload), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')), true);
});

test('registration validates origin, route and token; bearer authentication is exact', () => {
  assert.equal(authorized('Bearer secret', 'secret'), true);
  assert.equal(authorized('bearer secret', 'secret'), false);
  assert.equal(authorized(undefined, 'secret'), false);
  assert.equal(validateRegistration(registration, origin).id.length, 64);
  for (const mutation of [{ server: 'https://other.example.com' }, { device_token: 'bad' }, { chat_id: '' }, { channel: '' }]) {
    assert.throws(() => validateRegistration({ ...registration, ...mutation }, origin));
  }
  assert.equal(routeMatches({ chat_id: 'sub', route_chat_id: 'chat' }, registration), true);
  assert.equal(routeMatches({ chat_id: 'other' }, registration), false);
});

test('completion, AskUser and canceled event notification mapping', () => {
  assert.equal(noticeForEvent({ type: 'text', content: 'done' }).kind, 'completed');
  assert.equal(noticeForEvent({ type: 'text', content: 'done', cancelled: true }), null);
  assert.equal(noticeForEvent({ type: 'text', content: 'done', interrupted: true }), null);
  assert.equal(noticeForEvent({ type: 'text_delta', content: 'partial' }), null);
  assert.equal(noticeForEvent({ type: 'ask_user', progress: { questions: [{ question: 'which?' }] } }).body, 'which?');
  assert.equal(noticeForEvent({ type: 'ask_user', content: JSON.stringify({ questions: JSON.stringify([{ question: 'legacy?' }]) }) }).body, 'legacy?');
  assert.equal([...notificationPayload({ kind: 'completed', body: '😀'.repeat(300) }, registration).aps.alert.body].length, 240);
});

test('SSE framing handles BOM, chunked CRLF, comments and multiline data', () => {
  const decoder = new SSEDecoder();
  const result = [];
  for (const chunk of ['\uFEFF: hi\r', '\nid: 12\revent: text\r\ndata: one\r', '\ndata: two\r\n\r', '\n']) result.push(...decoder.push(chunk));
  assert.deepEqual(result, [{ id: '12', event: 'text', data: 'one\ntwo' }]);
});

test('APNs HTTP/2 request headers, payload, connection reuse and invalid token response', async t => {
  const server = createServer(); let requests = 0;
  server.on('stream', (stream, headers) => {
    requests++;
    assert.equal(headers[':method'], 'POST');
    assert.equal(headers[':path'], '/3/device/' + token);
    assert.equal(headers['apns-topic'], 'dev.xbot.ios');
    assert.equal(headers['apns-push-type'], 'alert');
    assert.equal(headers['apns-collapse-id'].length, 64);
    assert.ok(headers.authorization.startsWith('bearer '));
    let data = ''; stream.on('data', value => data += value);
    stream.on('end', () => {
      assert.equal(JSON.parse(data).chat_id, 'chat');
      stream.respond({ ':status': requests === 1 ? 200 : 410 });
      stream.end(requests === 1 ? '' : JSON.stringify({ reason: 'Unregistered' }));
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const sender = new APNSClient({ ...key, topic: 'dev.xbot.ios', testOrigin: 'http://127.0.0.1:' + server.address().port });
  t.after(() => { sender.close(); server.close(); });
  assert.deepEqual(await sender.send({ token }, { kind: 'completed', body: 'ok' }, registration, '1'), { accepted: true });
  assert.equal((await sender.send({ token }, { kind: 'question', body: '?' }, registration, '2')).invalidToken, true);
});

test('relay enforces session ownership, preserves cursor, deduplicates and removes subscriptions', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'xbot-relay-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  let sent = 0;
  const client = { async call() { return { sessions: [{ chat_id: 'chat', channel: 'web', children: [{ chat_id: 'child', channel: 'web' }] }] }; }, async history() { return { last_seq: 10 }; } };
  const relay = new PushRelay({ server: origin, secret: 's'.repeat(32), stateFile: join(directory, 'state.json'), client, sender: { async send() { sent++; return { accepted: true }; } } });
  relay.syncWatchers = () => {};
  const id = await relay.register(registration);
  await assert.rejects(relay.register({ ...registration, chat_id: 'not-owned' }));
  await relay.consume({ type: 'text', content: 'old' }, registration, 9);
  await relay.consume({ type: 'text', content: 'new' }, registration, 11);
  await relay.consume({ type: 'text', content: 'duplicate' }, registration, 11);
  await relay.register(registration);
  assert.equal(relay.devices[0].seq, 11);
  await relay.consume({ type: 'text', content: 'cancel', cancelled: true }, registration, 12);
  assert.equal(sent, 1);
  assert.equal((await stat(relay.stateFile)).mode & 0o777, 0o600);
  assert.equal(JSON.parse(await readFile(relay.stateFile)).devices.length, 1);
  await relay.register({ ...registration, chat_id: 'child' });
  assert.equal(relay.devices.length, 1);
  assert.equal(relay.devices[0].seq, 10);
  relay.sender.send = async () => ({ invalidToken: true });
  await relay.consume({ type: 'text', content: 'bad token' }, { ...registration, chat_id: 'child' }, 11);
  assert.equal(JSON.parse(await readFile(relay.stateFile)).devices.length, 0);
  await relay.unregister(id); assert.equal(relay.devices.length, 0);
});

test('relay HTTP binding requires bearer auth and supports explicit unbinding', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'xbot-relay-http-'));
  const relay = new PushRelay({ server: origin, secret: 's'.repeat(32), stateFile: join(directory, 'state.json'), client: { async call() { return { sessions: [{ chat_id: 'chat', channel: 'web' }] }; }, async history() { return { last_seq: 0 }; } }, sender: {} });
  relay.syncWatchers = () => {};
  const server = relay.httpServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { relay.close(); server.close(); await rm(directory, { recursive: true, force: true }); });
  const url = 'http://127.0.0.1:' + server.address().port;
  assert.equal((await fetch(url + '/devices', { method: 'POST', body: '{}' })).status, 401);
  const headers = { authorization: 'Bearer ' + 's'.repeat(32) };
  const response = await fetch(url + '/devices', { method: 'POST', headers, body: JSON.stringify(registration) });
  const result = await response.json(); assert.equal(result.ok, true);
  assert.equal((await fetch(url + '/devices/' + result.id, { method: 'DELETE', headers })).status, 200);
  assert.equal(relay.devices.length, 0);
});

test('resync recovers a missed completion and pending question without duplicates', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'xbot-resync-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const sent = [];
  const client = {
    async history() { return { last_seq: 2, processing: false, messages: [{ role: 'assistant', turn_id: 7, content: 'missed result' }] }; },
    async call() { return { request_id: 'new-question', questions: [{ question: 'continue?' }] }; },
  };
  const relay = new PushRelay({ server: origin, secret: 's'.repeat(32), stateFile: join(directory, 'state.json'), client,
    sender: { async send(device, notice) { sent.push(notice.kind); return { accepted: true }; } } });
  relay.syncWatchers = () => {};
  relay.devices = [{ ...validateRegistration(registration, origin), seq: 999, lastAssistantTurn: 6 }];
  await relay.resync(registration); await relay.resync(registration);
  assert.deepEqual(sent, ['completed', 'question']);
  assert.equal(relay.devices[0].seq, 2);
});

test('xbot client unwraps RPC responses and performs a single 401 relogin', async t => {
  const { createServer: httpServer } = await import('node:http');
  let logins = 0, calls = 0;
  const server = httpServer(async (req, res) => {
    for await (const ignored of req) {}
    res.setHeader('content-type', 'application/json');
    if (req.url === '/api/auth/login') { logins++; res.setHeader('set-cookie', 'session=test; HttpOnly'); res.end('{"ok":true}'); }
    else if (++calls === 1) { res.writeHead(401); res.end('{"ok":false}'); }
    else { assert.equal(req.headers.cookie, 'session=test'); res.end('{"ok":true,"data":{"last_seq":42}}'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const directory = await mkdtemp(join(tmpdir(), 'xbot-client-'));
  await writeFile(join(directory, 'credentials'), 'synthetic-user\nsynthetic-password\n', { mode: 0o600 });
  t.after(async () => { server.close(); await rm(directory, { recursive: true, force: true }); });
  const client = new XbotClient('http://127.0.0.1:' + server.address().port, join(directory, 'credentials'));
  assert.equal((await client.history(registration)).last_seq, 42);
  assert.equal(logins, 2); assert.equal(calls, 2);
});

test('authenticated SSE watcher delivers completion and AskUser once over real HTTP', async t => {
  const { createServer: httpServer } = await import('node:http');
  const directory = await mkdtemp(join(tmpdir(), 'xbot-watch-'));
  await writeFile(join(directory, 'credentials'), 'synthetic-user\nsynthetic-password\n', { mode: 0o600 });
  const sent = []; let complete;
  const delivered = new Promise(resolve => complete = resolve);
  const server = httpServer(async (req, res) => {
    for await (const ignored of req) {}
    if (req.url === '/api/auth/login') { res.setHeader('set-cookie', 'session=watch-test; HttpOnly'); res.end('{"ok":true}'); return; }
    assert.equal(req.headers.cookie, 'session=watch-test');
    if (req.url === '/api/session-tree') { res.end('{"ok":true,"sessions":[{"chat_id":"chat","channel":"web"}]}'); return; }
    if (req.url === '/api/history') { res.end('{"ok":true,"messages":[],"last_seq":0}'); return; }
    if (req.url.startsWith('/api/sse?')) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      const events = [
        { seq: 1, type: 'text', chat_id: 'other', content: 'ignore' },
        { seq: 2, type: 'text', chat_id: 'chat', content: 'done' },
        { seq: 2, type: 'text', chat_id: 'chat', content: 'duplicate' },
        { seq: 3, type: 'text', chat_id: 'chat', content: 'cancel', cancelled: true },
        { seq: 4, type: 'ask_user', progress: { request_id: 'q', questions: [{ question: 'choose?' }] } },
      ];
      for (const event of events) res.write(`id: ${event.seq}\r\ndata: ${JSON.stringify(event)}\r\n\r\n`);
      return;
    }
    res.writeHead(404); res.end('{}');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = 'http://127.0.0.1:' + server.address().port;
  const relay = new PushRelay({ server: address, secret: 's'.repeat(32), stateFile: join(directory, 'state.json'), client: new XbotClient(address, join(directory, 'credentials')),
    sender: { async send(device, notice) { sent.push(notice.kind); if (sent.length === 2) complete(); return { accepted: true }; } } });
  t.after(async () => { relay.close(); server.closeAllConnections(); server.close(); await relay.write; await rm(directory, { recursive: true, force: true }); });
  await relay.register({ ...registration, server: address });
  let timer;
  await Promise.race([delivered, new Promise((_, reject) => timer = setTimeout(() => reject(new Error('watch_timeout')), 3000))]);
  clearTimeout(timer);
  assert.deepEqual(sent, ['completed', 'question']);
});
