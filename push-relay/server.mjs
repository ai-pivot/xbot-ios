import { createServer } from 'node:http';
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { APNSClient } from './apns.mjs';
import { authorized, validateRegistration, routeMatches, noticeForEvent, SSEDecoder } from './protocol.mjs';

export class XbotClient {
  constructor(server, credentialsFile) { this.server = server.replace(/\/+$/, ''); this.credentialsFile = credentialsFile; this.cookie = ''; this.flight = null; }
  url(path) { return this.server + path; }
  async login() {
    if (this.flight) return this.flight;
    this.flight = (async () => {
      const lines = (await readFile(this.credentialsFile, 'utf8')).split(/\r?\n/);
      if (lines.length < 2) throw new Error('invalid_credentials_file');
      const response = await fetch(this.url('/api/auth/login'), { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20000), headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: lines[0].trim(), password: lines[1] }) });
      const result = await response.json();
      if (!response.ok || result.ok === false) throw new Error('xbot_login_failed');
      this.cookie = response.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
      if (!this.cookie) throw new Error('missing_session_cookie');
    })();
    try { await this.flight; } finally { this.flight = null; }
  }
  async call(path, body = {}, retried = false) {
    if (!this.cookie) await this.login();
    const response = await fetch(this.url(path), { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20000), headers: { cookie: this.cookie, 'content-type': 'application/json' }, body: JSON.stringify(body) });
    if (response.status === 401 && !retried) { await this.login(); return this.call(path, body, true); }
    const result = await response.json();
    if (!response.ok || result.ok === false) throw new Error('xbot_request_failed_' + response.status);
    return Object.hasOwn(result, 'data') && result.ok === true ? result.data : result;
  }
  history(context) { return this.call('/api/history', { chat_id: context.chat_id, channel: context.channel, limit: 40, before_id: 0 }); }
}

export class PushRelay {
  constructor({ server, secret, stateFile, client, sender }) {
    this.server = server.replace(/\/+$/, ''); this.secret = secret; this.stateFile = stateFile; this.client = client; this.sender = sender;
    this.devices = []; this.watchers = new Map(); this.write = Promise.resolve(); this.closed = false;
  }
  async load() {
    try { const value = JSON.parse(await readFile(this.stateFile, 'utf8')); this.devices = value.devices ?? []; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    this.syncWatchers();
  }
  async persist() {
    const content = JSON.stringify({ devices: this.devices });
    this.write = this.write.catch(() => {}).then(async () => {
      await mkdir(dirname(this.stateFile), { recursive: true, mode: 0o700 });
      const temporary = this.stateFile + '.tmp'; await writeFile(temporary, content, { mode: 0o600 }); await rename(temporary, this.stateFile);
    });
    return this.write;
  }
  async register(value) {
    const device = validateRegistration(value, this.server);
    const tree = await this.client.call('/api/session-tree');
    const owned = nodes => nodes.some(chat => (chat.chat_id === device.chat_id && (chat.channel || 'web') === device.channel) || owned(chat.children ?? []));
    if (!owned([...(tree.sessions ?? []), ...(tree.orphan_subagents ?? [])])) throw new Error('session_not_owned');
    const previous = this.devices.find(item => item.id === device.id);
    if (previous?.chat_id === device.chat_id && previous?.channel === device.channel) {
      Object.assign(previous, device);
    } else {
      const history = await this.client.history(device);
      device.seq = history.last_seq ?? 0;
      device.lastAssistantTurn = history.messages?.filter(message => message.role === "assistant").at(-1)?.turn_id ?? 0;
      this.devices = this.devices.filter(item => item.id !== device.id); this.devices.push(device);
    }
    await this.persist(); this.syncWatchers(); return device.id;
  }
  async unregister(id) { this.devices = this.devices.filter(item => item.id !== id); await this.persist(); this.syncWatchers(); }
  syncWatchers() {
    const contexts = new Map(this.devices.map(device => [JSON.stringify([device.channel, device.chat_id]), device]));
    for (const [key, abort] of this.watchers) { if (!contexts.has(key)) { abort.abort(); this.watchers.delete(key); } }
    if (this.closed) return;
    for (const [key, context] of contexts) if (!this.watchers.has(key)) {
      const abort = new AbortController(); this.watchers.set(key, abort);
      this.watch(context, abort.signal).catch(() => { if (!abort.signal.aborted) console.error('relay_watch_failed'); });
    }
  }
  async consume(event, context, sequence) {
    if (!routeMatches(event, context)) return;
    const notice = noticeForEvent(event);
    const targets = this.devices.filter(device => device.chat_id === context.chat_id && device.channel === context.channel);
    for (const device of targets) {
      if (sequence > 0 && sequence <= (device.seq ?? 0)) continue;
      if (notice) {
        const result = await this.sender.send(device, notice, context, String(sequence || event.request_id || event.progress?.request_id || event.type));
        if (result.invalidToken) { this.devices = this.devices.filter(item => item.id !== device.id); await this.persist(); continue; }
      }
      if (event.type === "text") device.lastAssistantTurn = Math.max(device.lastAssistantTurn ?? 0, event.turn_id ?? 0);
      if (event.type === "ask_user") device.lastQuestion = event.request_id || event.progress?.request_id || "";
      if (event.type === "ask_user_resolved") device.lastQuestion = "";
      if (sequence > 0) device.seq = sequence;
      await this.persist();
    }
    this.syncWatchers();
  }
  async resync(context) {
    const history = await this.client.history(context);
    const latest = history.messages?.filter(message => message.role === "assistant").at(-1);
    if (latest?.turn_id && !history.processing) {
      for (const device of this.devices.filter(item => item.chat_id === context.chat_id && item.channel === context.channel)) {
        if (latest.turn_id > (device.lastAssistantTurn ?? 0)) {
          const notice = noticeForEvent({ ...latest, type: "text" });
          if (notice) {
            const result = await this.sender.send(device, notice, context, "resync-" + latest.turn_id);
            if (result.invalidToken) this.devices = this.devices.filter(item => item.id !== device.id);
          }
          device.lastAssistantTurn = latest.turn_id;
        }
      }
    }
    const pending = await this.client.call('/api/rpc', { method: 'get_pending_ask_user', params: { chat_id: context.chat_id, channel: context.channel } });
    const notice = noticeForEvent({ type: 'ask_user', progress: pending });
    const question = pending?.request_id || (notice ? notice.body : '');
    for (const device of this.devices.filter(item => item.chat_id === context.chat_id && item.channel === context.channel)) {
      if (notice && question !== device.lastQuestion) {
        const result = await this.sender.send(device, notice, context, 'resync-ask-' + question);
        if (result.invalidToken) this.devices = this.devices.filter(item => item.id !== device.id);
      }
      device.lastQuestion = question;
    }
    for (const device of this.devices.filter(item => item.chat_id === context.chat_id && item.channel === context.channel)) device.seq = history.last_seq ?? 0;
    await this.persist(); this.syncWatchers();
  }
  async watch(context, outerSignal) {
    let attempt = 0;
    while (!outerSignal.aborted && !this.closed) {
      const watchdog = new AbortController(); let timer;
      const activity = () => { clearTimeout(timer); timer = setTimeout(() => watchdog.abort(), 55000); timer.unref(); };
      try {
        if (!this.client.cookie) await this.client.login();
        const devices = this.devices.filter(device => device.chat_id === context.chat_id && device.channel === context.channel);
        if (!devices.length) return;
        const sequence = Math.min(...devices.map(device => device.seq ?? 0));
        const url = new URL(this.client.url('/api/sse')); url.searchParams.set('chat_id', context.chat_id); url.searchParams.set('channel', context.channel);
        activity();
        const response = await fetch(url, { redirect: 'error', headers: { cookie: this.client.cookie, accept: 'text/event-stream', ...(sequence > 0 ? { 'last-event-id': String(sequence) } : {}) }, signal: AbortSignal.any([outerSignal, watchdog.signal]) });
        if (response.status === 401) { await this.client.login(); continue; }
        if (!response.ok || !response.headers.get('content-type')?.startsWith('text/event-stream')) throw new Error('sse_unavailable');
        const utf8 = new TextDecoder(), decoder = new SSEDecoder(); attempt = 0;
        for await (const chunk of response.body) {
          activity();
          for (const frame of decoder.push(utf8.decode(chunk, { stream: true }))) {
            if (frame.event === 'heartbeat') continue;
            let event; try { event = JSON.parse(frame.data); } catch { continue; }
            event.type ||= frame.event;
            if (event.type === 'resync_required') {
              await this.resync(context);
              watchdog.abort(); break;
            }
            await this.consume(event, context, Number(frame.id || event.seq || 0));
          }
        }
      } catch { if (outerSignal.aborted) return; console.error('relay_reconnecting'); }
      finally { clearTimeout(timer); watchdog.abort(); }
      try { await delay(Math.min(30000, 1000 * 2 ** Math.min(attempt++, 5)), undefined, { signal: outerSignal }); } catch { return; }
    }
  }
  httpServer() {
    return createServer(async (request, response) => {
      const reply = (status, body) => { response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); response.end(JSON.stringify(body)); };
      if (!authorized(request.headers.authorization, this.secret)) { reply(401, { ok: false }); return; }
      try {
        if (request.method === 'POST' && request.url === '/devices') {
          let raw = ''; for await (const chunk of request) { raw += chunk; if (raw.length > 8192) { reply(413, { ok: false }); return; } }
          const id = await this.register(JSON.parse(raw)); reply(200, { ok: true, id }); return;
        }
        if (request.method === 'DELETE' && /^\/devices\/[a-f0-9]{64}$/.test(request.url)) { await this.unregister(request.url.split('/').at(-1)); reply(200, { ok: true }); return; }
        reply(404, { ok: false });
      } catch { reply(400, { ok: false, error: 'registration_failed' }); }
    });
  }
  close() { this.closed = true; for (const controller of this.watchers.values()) controller.abort(); this.watchers.clear(); this.sender.close?.(); }
}

async function main() {
  const path = process.env.XBOT_PUSH_CONFIG;
  if (!path) throw new Error('Set XBOT_PUSH_CONFIG to a private config file');
  const config = JSON.parse(await readFile(path, 'utf8'));
  if (!config.secret || config.secret.length < 32) throw new Error('Relay secret must contain at least 32 characters');
  const client = new XbotClient(config.server, config.credentialsFile);
  const sender = new APNSClient({ teamId: config.teamId, keyId: config.keyId, privateKey: await readFile(config.apnsKeyFile, 'utf8'), topic: config.topic, sandbox: config.sandbox === true });
  const relay = new PushRelay({ server: config.server, secret: config.secret, stateFile: config.stateFile, client, sender });
  await relay.load(); const server = relay.httpServer(); server.listen(config.port ?? 18882, '127.0.0.1', () => console.log('push_relay_listening_on_loopback'));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { relay.close(); server.close(); });
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main().catch(() => { console.error('push_relay_startup_failed_check_private_config'); process.exitCode = 1; });
