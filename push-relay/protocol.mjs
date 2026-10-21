import { createHash, timingSafeEqual } from 'node:crypto';

export function authorized(header, secret) {
  const provided = Buffer.from(header ?? ''); const expected = Buffer.from('Bearer ' + secret);
  return provided.length === expected.length && timingSafeEqual(provided, expected);
}
export function validateRegistration(value, origin) {
  if (value.server !== origin || typeof value.device_token !== 'string' || !/^[a-f0-9]{32,512}$/i.test(value.device_token) || value.device_token.length % 2 ||
      typeof value.chat_id !== 'string' || !value.chat_id || value.chat_id.length > 1024 || typeof value.channel !== 'string' || !value.channel || value.channel.length > 128) throw new Error('invalid_registration');
  return { id: createHash('sha256').update(value.device_token.toLowerCase()).digest('hex'), token: value.device_token.toLowerCase(), chat_id: value.chat_id, channel: value.channel, server: origin };
}
export function routeMatches(event, context) {
  const chat = event.route_chat_id || event.chat_id || event.session?.chat_id;
  const channel = event.route_channel || event.channel || event.session?.channel;
  return (!chat || chat === context.chat_id) && (!channel || channel === context.channel);
}
export function noticeForEvent(event) {
  if (event.type === 'text' && !event.cancelled && !event.interrupted && event.content?.trim()) return { kind: 'completed', body: event.content };
  if (event.type === 'ask_user') {
    let questions = event.progress?.questions;
    if (!questions?.length) {
      try { const content = JSON.parse(event.content); questions = typeof content.questions === 'string' ? JSON.parse(content.questions) : content.questions; } catch {}
    }
    if (questions?.length) return { kind: 'question', body: questions[0].question || 'Agent 需要你的回答' };
  }
  return null;
}
export class SSEDecoder {
  constructor() { this.line = ''; this.data = []; this.id = ''; this.event = ''; this.cr = false; this.first = true; }
  push(text) {
    const frames = [];
    for (const character of text) {
      if (this.cr) { this.cr = false; if (character === '\n') continue; }
      if (character === '\n' || character === '\r') {
        if (character === '\r') this.cr = true;
        let line = this.line; this.line = '';
        if (this.first) { this.first = false; line = line.replace(/^\uFEFF/, ''); }
        if (!line) {
          if (this.data.length) frames.push({ id: this.id, event: this.event, data: this.data.join('\n') });
          this.data = []; this.id = ''; this.event = ''; continue;
        }
        if (line.startsWith(':')) continue;
        const index = line.indexOf(':'); const key = index < 0 ? line : line.slice(0, index);
        const value = index < 0 ? '' : line.slice(index + 1).replace(/^ /, '');
        if (key === 'data') this.data.push(value);
        if (key === 'event') this.event = value;
        if (key === 'id' && !value.includes('\0')) this.id = value;
      } else { this.line += character; if (this.line.length > 16 * 1024 * 1024) throw new Error('sse_frame_too_large'); }
    }
    return frames;
  }
}
