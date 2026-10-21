import { createPrivateKey, sign, createHash } from 'node:crypto';
import { connect } from 'node:http2';

export function makeProviderToken({ teamId, keyId, privateKey, now = Math.floor(Date.now() / 1000) }) {
  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: keyId })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ iss: teamId, iat: now })).toString('base64url');
  const unsigned = `${header}.${claims}`;
  const signature = sign('sha256', Buffer.from(unsigned), { key: typeof privateKey === 'string' ? createPrivateKey(privateKey) : privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${unsigned}.${signature}`;
}

export function notificationPayload(notice, context) {
  return {
    aps: { alert: { title: notice.kind === 'question' ? 'xbot 需要你的回答' : 'xbot 已完成', body: [...notice.body].slice(0, 240).join('') }, sound: 'default' },
    chat_id: context.chat_id, channel: context.channel, server: context.server,
  };
}

export class APNSClient {
  constructor({ teamId, keyId, privateKey, topic, sandbox = false, testOrigin }) {
    this.config = { teamId, keyId, privateKey }; this.topic = topic;
    this.origin = testOrigin ?? (sandbox ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com');
    this.session = null; this.jwt = ''; this.jwtAt = 0;
  }
  async send(device, notice, context, eventKey) {
    if (!/^[a-f0-9]{32,512}$/i.test(device.token) || device.token.length % 2) throw new Error('invalid_device_token');
    const now = Math.floor(Date.now() / 1000);
    if (!this.jwt || now - this.jwtAt > 45 * 60) { this.jwt = makeProviderToken({ ...this.config, now }); this.jwtAt = now; }
    if (!this.session || this.session.closed || this.session.destroyed) {
      this.session = connect(this.origin); this.session.on('error', () => {});
    }
    const collapse = createHash('sha256').update(context.channel + ':' + context.chat_id + ':' + eventKey).digest('hex');
    const headers = { ':method': 'POST', ':path': '/3/device/' + device.token, authorization: 'bearer ' + this.jwt,
      'apns-topic': this.topic, 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': String(now + 3600), 'apns-collapse-id': collapse };
    const session = this.session;
    return new Promise((resolve, reject) => {
      const request = session.request(headers); let status = 0, body = '';
      request.setTimeout(15000, () => { request.close(); reject(new Error('apns_timeout')); });
      request.on('response', response => { status = Number(response[':status']); });
      request.setEncoding('utf8'); request.on('data', chunk => { if (body.length < 4096) body += chunk; });
      request.on('error', () => reject(new Error('apns_transport_error')));
      request.on('end', () => {
        if (status === 200) { resolve({ accepted: true }); return; }
        let reason = ''; try { reason = JSON.parse(body).reason; } catch {}
        if (status === 410 || ['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'].includes(reason)) { resolve({ accepted: false, invalidToken: true }); return; }
        reject(new Error('apns_rejected_' + status));
      });
      request.end(JSON.stringify(notificationPayload(notice, context)));
    });
  }
  close() { this.session?.close(); this.session = null; }
}
