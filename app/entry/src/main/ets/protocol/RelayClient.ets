import webSocket from '@ohos.net.webSocket';
import { BusinessError } from '@ohos.base';
import { hilog } from '@kit.PerformanceAnalysisKit';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { Bytes } from './Bytes';
import { jStr } from './Json';
import { BindingInfo } from '../model/Models';
import { PhoneInfo } from '../model/PhoneInfo';

const TAG: string = 'ZCRemote';

/**
 * 中继 WebSocket 客户端（role=terminal）
 *
 * 状态机: idle → connecting → authenticating → waiting|paired → error/closed
 * 鉴权: auth_init → auth_challenge → auth_response(HMAC-SHA256 证明) → auth_ack
 * 心跳: paired/waiting 后每 ~10s pair_status_query，30s 无 ack 重连
 * 重连: 指数退避 min(10s, 500*2^attempt)
 */
export const STATE_IDLE: string = 'idle';
export const STATE_CONNECTING: string = 'connecting';
export const STATE_AUTHENTICATING: string = 'authenticating';
export const STATE_WAITING: string = 'waiting';
export const STATE_PAIRED: string = 'paired';
export const STATE_RECONNECTING: string = 'reconnecting';
export const STATE_ERROR: string = 'error';
export const STATE_CLOSED: string = 'closed';

export type PayloadHandler = (payload: Record<string, Object>) => void;
export type StateHandler = (state: string, detail: string) => void;

export class RelayClient {
  private binding: BindingInfo;
  private ws: webSocket.WebSocket | undefined = undefined;
  private _state: string = STATE_IDLE;
  private detail: string = '';
  private manuallyClosed: boolean = false;
  private attempt: number = 0;
  private generation: number = 0;
  private lastAckAt: number = 0;
  private heartbeatTimer: number = -1;
  private watchdogTimer: number = -1;
  private reconnectTimer: number = -1;

  onPayload: PayloadHandler | undefined = undefined;
  onState: StateHandler | undefined = undefined;

  constructor(binding: BindingInfo) {
    this.binding = binding;
  }

  get state(): string {
    return this._state;
  }

  start(): void {
    this.manuallyClosed = false;
    this.attempt = 0;
    this.connect();
  }

  stop(): void {
    this.manuallyClosed = true;
    this.clearTimers();
    const sock = this.ws;
    this.ws = undefined;
    if (sock !== undefined) {
      try {
        sock.close((err: BusinessError, value: boolean) => {
        });
      } catch (e) {
        // ignore
      }
    }
    this.setState(STATE_CLOSED, '');
  }

  sendPayloadJson(jsonText: string): boolean {
    if (this._state !== STATE_PAIRED || this.ws === undefined) {
      return false;
    }
    // 中继协议: 应用 payload 必须包在 {type:"data", payload} 帧里
    let payloadObj: Record<string, Object>;
    try {
      payloadObj = JSON.parse(jsonText) as Record<string, Object>;
    } catch (e) {
      hilog.error(0x0000, TAG, '[relay] sendPayloadJson parse failed');
      return false;
    }
    const frame: Record<string, Object> = {
      'type': 'data',
      'payload': payloadObj,
      'client_ts': Date.now()
    };
    this.sendText(JSON.stringify(frame));
    return true;
  }

  private sendText(text: string): void {
    if (this.ws === undefined) {
      return;
    }
    this.ws.send(text, (err: BusinessError, value: boolean) => {
      if (err !== undefined && err.code !== undefined && err.code !== 0) {
        hilog.error(0x0000, TAG, '[relay] ws send failed code=%{public}d', err.code);
        // 发送失败说明链路已坏：立即退避重连，避免依赖 30s 心跳看门狗
        this.stopHeartbeat();
        this.reconnectWithBackoff();
      }
    });
  }

  private connect(): void {
    this.clearReconnect();
    this.generation += 1;
    this.lastAckAt = Date.now();
    this.setState(STATE_CONNECTING, `第 ${this.attempt + 1} 次尝试`);

    let url = this.binding.relayWsUrl;
    if (this.binding.deviceMid.length > 0) {
      url = url + '?mid=' + encodeURIComponent(this.binding.deviceMid);
    }

    const sock = webSocket.createWebSocket();
    this.ws = sock;
    sock.on('open', (err: BusinessError, value: Object) => {
      if (this.ws !== sock) {
        return;
      }
      this.doAuth(sock);
    });
    sock.on('message', (err: BusinessError, value: String | ArrayBuffer) => {
      if (this.ws !== sock) {
        return;
      }
      if (typeof value === 'string') {
        this.handleText(value as string);
      } else if (value instanceof ArrayBuffer) {
        this.handleText(Bytes.toStr(new Uint8Array(value)));
      }
    });
    sock.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (this.ws !== sock) {
        return;
      }
      hilog.warn(0x0000, TAG, `[relay] ws close code=%{public}d reason=%{public}s state=%{public}s`,
        value !== undefined ? value.code : 0, value !== undefined ? value.reason : '', this._state);
      this.stopHeartbeat();
      if (!this.manuallyClosed) {
        this.scheduleReconnect(0);
      }
    });
    sock.on('error', (err: BusinessError) => {
      if (this.ws !== sock) {
        return;
      }
      const msg = err !== undefined && err.message !== undefined ? err.message : '';
      hilog.error(0x0000, TAG, '[relay] ws error code=%{public}d msg=%{public}s state=%{public}s',
        err !== undefined ? err.code : 0, msg, this._state);
      this.stopHeartbeat();
      if (this._state !== STATE_PAIRED) {
        this.setState(STATE_RECONNECTING, msg.length > 0 ? msg : '连接失败，即将重试');
      }
    });

    sock.connect(url, (err: BusinessError) => {
      if (err !== undefined && err.code !== undefined && err.code !== 0) {
        if (this.ws === sock && !this.manuallyClosed) {
          this.stopHeartbeat();
          this.scheduleReconnect(0);
        }
      }
    });
  }

  private async doAuth(sock: webSocket.WebSocket): Promise<void> {
    this.setState(STATE_AUTHENTICATING, '');
    // 鉴权看门狗：10s 内未进入 waiting/paired 视为协议异常，退避重连
    this.armAuthWatchdog(sock);
    const init: Record<string, Object> = {
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': this.binding.deviceSid,
      'meta': {
        'platform': 'web',
        'version': this.binding.appVersion,
        'name': PhoneInfo.phoneName(),
        'userAgent': PhoneInfo.userAgent(this.binding.appVersion)
      } as Record<string, Object>,
      'client_ts': Date.now()
    };
    this.sendText(JSON.stringify(init));
  }

  private handleText(text: string): void {
    let msg: Record<string, Object> | undefined = undefined;
    try {
      msg = JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      hilog.warn(0x0000, TAG, '[relay] non-json frame len=%{public}d', text.length);
      return;
    }
    if (msg === undefined) {
      return;
    }
    const type = jStr(msg, 'type');
    hilog.info(0x0000, TAG, '[relay] recv type=%{public}s pair=%{public}s code=%{public}s',
      type, jStr(msg, 'pair_status'), jStr(msg, 'code'));
    if (type === 'auth_challenge') {
      const nonce = jStr(msg, 'nonce');
      this.respondChallenge(nonce);
      return;
    }
    if (type === 'auth_ack' || type === 'pair_status_ack') {
      this.lastAckAt = Date.now();
      const pairStatus = jStr(msg, 'pair_status');
      this.applyPairStatus(pairStatus);
      return;
    }
    if (type === 'data') {
      const payload: Object | undefined = msg['payload'];
      if (payload !== undefined && typeof payload === 'object' && !Array.isArray(payload)) {
        const rec = payload as Record<string, Object>;
        if (this.onPayload !== undefined) {
          this.onPayload(rec);
        }
      }
      return;
    }
    if (type === 'error') {
      const code = jStr(msg, 'code');
      const message = jStr(msg, 'message');
      this.handleRelayError(code, message);
      return;
    }
  }

  private respondChallenge(nonce: string): void {
    calculateProof(this.binding.passHash, nonce, 'terminal', this.binding.deviceSid)
      .then((proof: string) => {
        hilog.info(0x0000, TAG, '[relay] proof computed len=%{public}d', proof.length);
        const resp: Record<string, Object> = {
          'type': 'auth_response',
          'device_sid': this.binding.deviceSid,
          'proof': proof,
          'client_ts': Date.now()
        };
        if (this.ws !== undefined) {
          this.sendText(JSON.stringify(resp));
        }
      })
      .catch((e: Object) => {
        const emsg = e instanceof Error ? (e as Error).message : JSON.stringify(e);
        hilog.error(0x0000, TAG, '[relay] HMAC calculateProof FAILED: %{public}s', emsg);
        this.setState(STATE_ERROR, 'HMAC 计算失败: ' + emsg);
      });
  }

  private applyPairStatus(pairStatus: string): void {
    if (this.authWatchdogTimer !== -1) {
      clearTimeout(this.authWatchdogTimer);
      this.authWatchdogTimer = -1;
    }
    this.armWatchdog();
    if (pairStatus === 'waiting') {
      this.attempt = 0;
      this.setState(STATE_WAITING, '等待桌面端配对（请确认桌面端已开启远程控制）');
      this.startHeartbeat();
      return;
    }
    if (pairStatus === 'matched') {
      this.attempt = 0;
      this.setState(STATE_PAIRED, '');
      this.startHeartbeat();
      return;
    }
  }

  private handleRelayError(code: string, message: string): void {
    hilog.error(0x0000, TAG, '[relay] relay ERROR code=%{public}s message=%{public}s state=%{public}s',
      code, message, this._state);
    if (code === 'DEVICE_OFFLINE') {
      // 桌面暂时离线，走重连等待
      this.setState(STATE_WAITING, '桌面端暂时离线，等待恢复');
      this.startHeartbeat();
      return;
    }
    if (code === 'KICKED') {
      this.setState(STATE_ERROR, '会话被顶掉（桌面端可能重置了配对），请重新扫码绑定');
      this.stopHeartbeat();
      return;
    }
    if (code === 'AUTH_FAILED' || code === 'WRONG_PARAM') {
      this.setState(STATE_ERROR, '凭证失效，请重新扫码绑定');
      this.stopHeartbeat();
      return;
    }
    // INTERNAL 等：走指数退避重连，避免服务端持续报错时形成紧循环
    this.setState(STATE_RECONNECTING, message.length > 0 ? message : '中继内部错误，重连中');
    this.reconnectWithBackoff();
  }

  private authWatchdogTimer: number = -1;

  private armAuthWatchdog(sock: webSocket.WebSocket): void {
    if (this.authWatchdogTimer !== -1) {
      clearTimeout(this.authWatchdogTimer);
    }
    this.authWatchdogTimer = setTimeout(() => {
      this.authWatchdogTimer = -1;
      if (this.ws === sock && (this._state === STATE_AUTHENTICATING || this._state === STATE_CONNECTING)) {
        hilog.error(0x0000, TAG, '[relay] auth watchdog fired, reconnecting');
        this.reconnectNow();
      }
    }, 10000);
  }

  /** 带退避的重连（保留 attempt 计数） */
  private reconnectWithBackoff(): void {
    this.stopHeartbeat();
    const sock = this.ws;
    this.ws = undefined;
    if (sock !== undefined) {
      try {
        sock.close((err: BusinessError, value: boolean) => {
        });
      } catch (e) {
        // ignore
      }
    }
    this.scheduleReconnect(0);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.armWatchdog();
    this.heartbeatTimer = setInterval(() => {
      const q: Record<string, Object> = {
        'type': 'pair_status_query',
        'device_sid': this.binding.deviceSid,
        'client_ts': Date.now()
      };
      if (this.ws !== undefined) {
        this.sendText(JSON.stringify(q));
      }
    }, 10000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    if (this.watchdogTimer !== -1) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
    if (this.authWatchdogTimer !== -1) {
      clearTimeout(this.authWatchdogTimer);
      this.authWatchdogTimer = -1;
    }
  }

  private armWatchdog(): void {
    if (this.watchdogTimer !== -1) {
      clearTimeout(this.watchdogTimer);
    }
    this.watchdogTimer = setTimeout(() => {
      const staleMs = Date.now() - this.lastAckAt;
      if (staleMs > 28000 && this.ws !== undefined) {
        this.reconnectNow();
      }
    }, 30000);
  }

  private reconnectNow(): void {
    this.stopHeartbeat();
    const sock = this.ws;
    this.ws = undefined;
    if (sock !== undefined) {
      try {
        sock.close((err: BusinessError, value: boolean) => {
        });
      } catch (e) {
        // ignore
      }
    }
    this.connect();
  }

  private scheduleReconnect(_unused: number): void {
    if (this.manuallyClosed) {
      return;
    }
    this.clearReconnect();
    const delay = Math.min(10000, 500 * Math.pow(2, this.attempt));
    this.attempt += 1;
    if (this._state !== STATE_RECONNECTING) {
      this.setState(STATE_RECONNECTING, '连接断开，即将重试');
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connect();
    }, delay);
  }

  private clearReconnect(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private clearTimers(): void {
    this.stopHeartbeat();
    this.clearReconnect();
  }

  private setState(state: string, detail: string): void {
    if (this._state === state && this.detail === detail) {
      return;
    }
    hilog.info(0x0000, TAG, '[relay] state %{public}s -> %{public}s (%{public}s)',
      this._state, state, detail);
    this._state = state;
    this.detail = detail;
    if (this.onState !== undefined) {
      this.onState(state, detail);
    }
  }
}

/** HMAC-SHA256(key=passHash, msg=`${nonce}|${role}|${deviceSid}`) → base64url */
export async function calculateProof(passHash: string, nonce: string, role: string,
  deviceSid: string): Promise<string> {
  const keyGen = cryptoFramework.createSymKeyGenerator('HMAC');
  const keyBlob: cryptoFramework.DataBlob = { data: Bytes.utf8(passHash) };
  const symKey: cryptoFramework.SymKey = await keyGen.convertKey(keyBlob);
  const mac = cryptoFramework.createMac('SHA256');
  await mac.init(symKey);
  const msgBytes = Bytes.utf8(`${nonce}|${role}|${deviceSid}`);
  await mac.update({ data: msgBytes });
  const out: cryptoFramework.DataBlob = await mac.doFinal();
  return Bytes.base64Url(out.data);
}
