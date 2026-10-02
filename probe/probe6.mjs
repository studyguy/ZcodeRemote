// probe6: 验证 usage-stats 通道 getEntitlementSnapshot
import { createHash, createHmac, createDecipheriv } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, userInfo, platform as osPlatform } from 'node:os';

const V2 = join(homedir(), '.zcode', 'v2');
const RELAY = 'wss://zcode.z.ai/ws';
const OUT = join(import.meta.dirname, '..', 'research', 'samples');
mkdirSync(OUT, { recursive: true });
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const settings = JSON.parse(readFileSync(join(V2, 'setting.json'), 'utf8'));
const sid = settings.webRemoteControlExternalRelayDevice.deviceSid;
const creds = JSON.parse(readFileSync(join(V2, 'credentials.json'), 'utf8'));
const enc = creds['web-remote-control:external-relay:pass_hash'];
const secret = `zcode-credential-fallback:${osPlatform()}:${homedir()}:${userInfo().username}`;
const key = createHash('sha256').update(secret).digest();
const [iv, tag, data] = enc.slice(7).split('.').map(x => Buffer.from(x, 'base64url'));
const dd = createDecipheriv('aes-256-gcm', key, iv); dd.setAuthTag(tag);
const passHash = Buffer.concat([dd.update(data), dd.final()]).toString('utf8');
const telemetry = JSON.parse(readFileSync(join(V2, 'telemetry-state.json'), 'utf8'));
let mid = telemetry.deviceMid || telemetry.mid || '';
if (!mid) for (const v of Object.values(telemetry)) if (typeof v === 'string' && /^[0-9a-f-]{36}$/.test(v)) { mid = v; break; }

const WT = { UNDEF: 0, STRING: 1, BUFFER: 2, VSB: 3, ARRAY: 4, OBJECT: 5, INT: 6 };
class BW {
  constructor(cap) { this.buf = Buffer.alloc(cap || 64); this.len = 0; }
  ensure(n) { if (this.len + n <= this.buf.length) return; let c = this.buf.length * 2; while (c < this.len + n) c *= 2; const nb = Buffer.alloc(c); this.buf.copy(nb, 0, 0, this.len); this.buf = nb; }
  wb(b) { this.ensure(1); this.buf[this.len++] = b & 0xff; }
  wv(v) { let x = v; for (;;) { let b = x & 0x7f; x = Math.floor(x / 128); if (x) b |= 0x80; this.wb(b); if (!x) break; } }
  wstr(s2) { const b = Buffer.from(s2, 'utf8'); this.wb(WT.STRING); this.wv(b.length); this.wb2(b); }
  wb2(b) { this.ensure(b.length); b.copy(this.buf, this.len); this.len += b.length; }
  out() { return this.buf.subarray(0, this.len); }
}
class BR {
  constructor(buf) { this.buf = buf; this.pos = 0; }
  rb() { if (this.pos >= this.buf.length) throw new Error('eof'); return this.buf[this.pos++]; }
  rbytes(n) { if (this.pos + n > this.buf.length) throw new Error('eof'); const o = this.buf.subarray(this.pos, this.pos + n); this.pos += n; return o; }
  rv() { let r = 0, sh = 0; for (;;) { const b = this.rb(); r += (b & 0x7f) * Math.pow(2, sh); if (!(b & 0x80)) break; sh += 7; if (sh > 49) throw new Error('varint'); } return r; }
}
function wVal(w, v) {
  if (v === undefined) { w.wb(WT.UNDEF); return; }
  if (typeof v === 'number' && Number.isInteger(v)) { w.wb(WT.INT); w.wv(v); return; }
  if (typeof v === 'string') { w.wstr(v); return; }
  if (Buffer.isBuffer(v) || v instanceof Uint8Array) { const b = Buffer.from(v); w.wb(WT.BUFFER); w.wv(b.length); w.wb2(b); return; }
  if (Array.isArray(v)) { w.wb(WT.ARRAY); w.wv(v.length); for (const x of v) wVal(w, x); return; }
  const js = JSON.stringify(v); const b = Buffer.from(js, 'utf8');
  w.wb(WT.OBJECT); w.wv(b.length); w.wb2(b);
}
function rVal(r) {
  const t = r.rb();
  switch (t) {
    case WT.UNDEF: return undefined;
    case WT.INT: return r.rv();
    case WT.STRING: return r.rbytes(r.rv()).toString('utf8');
    case WT.BUFFER: case WT.VSB: return r.rbytes(r.rv());
    case WT.ARRAY: { const n = r.rv(); const a = []; for (let i = 0; i < n; i++) a.push(rVal(r)); return a; }
    case WT.OBJECT: return JSON.parse(r.rbytes(r.rv()).toString('utf8'));
    default: throw new Error('bad wire type ' + t);
  }
}
function encodeRequest(rt, id, ch, method, args) { const w = new BW(256); wVal(w, [rt, id, ch, method]); wVal(w, args); return w.out(); }
function decodePair(bytes) { const r = new BR(bytes); const head = rVal(r); const data = r.pos < r.buf.length ? rVal(r) : undefined; return { head, data }; }
function crc32hex(b) { let t = 4294967295; for (const n of b) { t ^= n; for (let i = 0; i < 8; i++) t = t >>> 1 ^ (t & 1 ? 3988292384 : 0); } return ((t ^ 4294967295) >>> 0).toString(16).padStart(8, '0'); }
const CHUNK = 200 * 1024;
function encodeFrames(msg, bsid, firstSeq, msgSeq) {
  const count = Math.ceil(msg.length / CHUNK); const cs = crc32hex(msg); const frames = [];
  for (let i = 0; i < count; i++) {
    const chunk = msg.subarray(i * CHUNK, Math.min(msg.length, (i + 1) * CHUNK));
    frames.push({ zcode_type: 'rpc-frame', bridgeSessionId: bsid, bridgeGeneration: 1, seq: firstSeq + i, messageSeq: msgSeq, fragmentIndex: i, fragmentCount: count, messageBytes: msg.length, checksum: { algorithm: 'crc32', value: cs }, dataBase64: chunk.toString('base64') });
  }
  return frames;
}
class Assembler {
  constructor(onDone) { this.expSeq = 1; this.expMsg = 1; this.reset(); this.onDone = onDone; this.acks = []; }
  reset() { this.frags = []; this.recv = 0; this.msgLen = 0; this.msgSeq = 0; this.fragCount = 0; }
  accept(p) {
    if (p.messageSeq < this.expMsg) { this.acks.push(this.expMsg - 1); return; }
    if (p.seq !== this.expSeq) return;
    const dd2 = Buffer.from(p.dataBase64, 'base64');
    if (this.recv === 0) { this.reset(); this.msgLen = p.messageBytes; this.msgSeq = p.messageSeq; this.fragCount = p.fragmentCount; }
    if (p.fragmentIndex !== this.recv) return;
    this.frags.push(dd2); this.recv++; this.expSeq = p.seq + 1;
    if (this.recv === this.fragCount) {
      const full = Buffer.concat(this.frags);
      if (crc32hex(full) !== p.checksum.value) return;
      const done = this.msgSeq; this.reset(); this.expMsg = done + 1; this.acks.push(done); this.onDone(full, done);
    }
  }
}

const dataHandlers = [];
const bootstrapPromise = new Promise((res) => {
  const h = (p) => { if (p.zcode_type === 'bootstrap-response' && p.success) res(p.result); };
  dataHandlers.push(h);
});
let bridgeSessionId = null;
let assembler = null;
let reqId = 100;
const pending = new Map();
function send(obj) { ws.send(JSON.stringify(obj)); }
function sendApp(payload) { send({ type: 'data', payload, client_ts: Date.now() }); }
const txSeq = { next: 1, msg: 1 };
function sendFrameBytes(bytes) {
  const frames = encodeFrames(bytes, bridgeSessionId, txSeq.next, txSeq.msg);
  txSeq.msg += 1; txSeq.next += frames.length;
  for (const f of frames) sendApp(f);
}
function request(ch, method, args, timeoutMs = 25000) {
  const id = ++reqId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, timer: setTimeout(() => { pending.delete(id); reject(new Error('timeout')); }, timeoutMs) });
    sendFrameBytes(encodeRequest(100, id, ch, method, args));
  });
}
const ws = new WebSocket(RELAY + '?mid=' + mid);
ws.addEventListener('open', () => {
  log('ws open');
  send({ type: 'auth_init', role: 'terminal', device_sid: sid, meta: { platform: 'web', version: '3.14.4', name: 'probe6' }, client_ts: Date.now() });
});
ws.addEventListener('message', async (ev) => {
  let msg; try { msg = JSON.parse(typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data).toString()); } catch { return; }
  switch (msg.type) {
    case 'auth_challenge':
      send({ type: 'auth_response', device_sid: sid, proof: createHmac('sha256', passHash).update(`${msg.nonce}|terminal|${sid}`).digest('base64url'), client_ts: Date.now() });
      break;
    case 'auth_ack': case 'pair_status_ack':
      log('pair_status =', msg.pair_status);
      if (msg.pair_status === 'matched') start();
      break;
    case 'data': {
      const p = msg.payload;
      if (!p || typeof p !== 'object') return;
      if (p.zcode_type === 'rpc-frame' && assembler) {
        assembler.accept(p);
        if (assembler.acks.length) for (const a of assembler.acks.splice(0)) sendApp({ zcode_type: 'rpc-frame-ack', bridgeSessionId, ackMessageSeq: a });
        return;
      }
      if (p.zcode_type === 'rpc-frame-ack') return;
      for (const h of dataHandlers) h(p);
      return;
    }
  }
});
ws.addEventListener('error', (e) => log('ws error', e.message || e));
ws.addEventListener('close', (e) => log('ws close', e.code, e.reason || ''));

async function start() {
  sendApp({ zcode_type: 'bootstrap-request', requestId: 'p6-' + Date.now() });
  const bs = await bootstrapPromise;
  log('bootstrap ok');
  const ws0 = (bs.workspaces || [])[0];
  const identityOf = (w) => (w.workspaceIdentity?.trim() || w.workspacePath);
  bridgeSessionId = 'probe6-' + Date.now().toString(36);
  const readyPromise = new Promise((res, rej) => {
    const h = (p) => {
      if (p.zcode_type === 'workspace-bridge-ready' && p.bridgeSessionId === bridgeSessionId) res(p);
      if (p.zcode_type === 'workspace-bridge-error' && p.bridgeSessionId === bridgeSessionId) rej(new Error(p.error));
    };
    dataHandlers.push(h);
  });
  sendApp({ zcode_type: 'workspace-bridge-open', requestId: 'b', bridgeSessionId, bridgeGeneration: 1, workspaceKey: identityOf(ws0) });
  await Promise.race([readyPromise, new Promise((_, rej) => setTimeout(() => rej(new Error('bridge timeout')), 20000))]);
  log('桥就绪');
  assembler = new Assembler((full) => {
    try { const { head, data } = decodePair(full); const w = pending.get(head?.[1]); if (w) { clearTimeout(w.timer); pending.delete(head[1]); w.resolve(data); } } catch { }
  });
  await new Promise((r) => setTimeout(r, 4000));

  // 先取 model-selection 视图拿 preferredProviderId
  let providerId = '';
  try {
    const mv = await request('model-selection', 'getView', [{ workspacePath: identityOf(ws0) }], 20000);
    providerId = mv?.preferredSelection?.providerId || mv?.providers?.[0]?.providerId || '';
    log('preferredProviderId =', providerId);
  } catch (e) { log('model view 失败:', e.message); }

  const aa = (family, planKind) => ({ type: 'zhipu-account', family, planKind });
  for (const argsVariant of [
    [{ includeSubscription: true, preferredProviderId: providerId, accountAccess: aa('bigmodel', 'individual-coding-plan') }],
    [{ includeSubscription: true, preferredProviderId: providerId, accountAccess: aa('zai', 'individual-coding-plan') }],
    [{ includeSubscription: true, preferredProviderId: providerId, accountAccess: aa('bigmodel', 'start-plan') }],
  ]) {
    try {
      const snap = await request('usage-stats', 'getEntitlementSnapshot', argsVariant, 25000);
      log('getEntitlementSnapshot 成功');
      const quota = snap?.quota;
      if (quota?.limits?.length) {
        for (const l of quota.limits) {
          console.log(`  limit type=${l.type} unit=${l.unit} number=${l.number ?? '-'} pct=${l.percentage ?? '-'} remaining=${l.remaining ?? '-'} nextReset=${l.nextResetTime ?? '-'}`);
        }
      } else {
        console.log('  quota:', JSON.stringify(quota)?.slice(0, 200));
      }
      if (snap?.remaining) console.log('  remaining:', JSON.stringify(snap.remaining));
      writeFileSync(join(OUT, 'entitlement-sample.json'), JSON.stringify(snap, null, 2));
      break;
    } catch (e) {
      log('失败 (args=' + JSON.stringify(argsVariant).slice(0, 60) + '):', e.message);
    }
  }
  log('完成，5s 后退出');
  setTimeout(() => process.exit(0), 5000);
}
setTimeout(() => process.exit(1), 45000);
