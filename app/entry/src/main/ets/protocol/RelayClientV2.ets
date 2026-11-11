import webSocket from '@ohos.net.webSocket';
import { BusinessError } from '@ohos.base';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Bytes } from './Bytes';
import { jStr } from './Json';
import { BindingInfo } from '../model/Models';
import { PhoneInfo } from '../model/PhoneInfo';

const TAG: string = 'ZCRemote';

/**
 * 中继 WebSocket 客户端 V2（桌面 3.16+，/api/v1/remote/ws2）
 *
 * 与 V1 的区别（逆向自桌面 3.17.2 asar，2026-11 探针实测）:
 *  - 鉴权 = 账号 JWT 换发的短时 token（expires_in=60s，每次连接前现取），不再有 HMAC 挑战应答
 *  - token 以 URL 参数携带: wss://<host>/api/v1/remote/ws2?token=<tok>&mid=<phoneMid>
 *  - auth_init 精简为 {device_sid, meta:{platform,version,name}, client_ts(秒)}（无 role 字段）
 *  - 心跳 {type:'pair_status_query', client_ts}（无 device_sid）
 *
 * 状态机: idle → connecting → authenticating → waiting|paired → error/closed
 * 错误码: AUTH_FAILED（重取 token 重试一次）/ WRONG_PARAM / KICKED / INTERNAL / DEVICE_OFFLINE
 */
export const STATE_IDLE: string = 'idle';
export const STATE_CONNECTING: string = 'connecting';
export const STATE_AUTHENTICATING: string = 'authenticating';
export const STATE_WAITING: string = 'waiting';
export const STATE_PAIRED: string = 'paired';
export const STATE_RECONNECTING: string = 'reconnecting';
export const STATE_ERROR: string = 'error';
export const STATE_CLOSED: string = 'closed';

/** APP 自身版本（auth_init meta.version：连接方身份，用桌面版本字段位上报自己） */
const APP_VERSION: string = '1.0.0';

export type PayloadHandler = (payload: Record<string, Object>) => void;
export type StateHandler = (state: string, detail: string) => void;
/** 短时终端 token 提供方（每次连接前调用，内部走账号 JWT → /api/v1/remote/token） */
export type TokenProvider = () => Promise<string>;

export class RelayClientV2 {
  private binding: BindingInfo;
  private tokenProvider: TokenProvider;
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
  /** AUTH_FAILED 后自动重取 token 重试一次（防止 token 服务端瞬时不一致导致死循环） */
  private authRetried: boolean = false;

  onPayload: PayloadHandler | undefined = undefined;
  onState: StateHandler | undefined = undefined;

  constructor(binding: BindingInfo, tokenProvider: TokenProvider) {
    this.binding = binding;
    this.tokenProvider = tokenProvider;
  }

  get state(): string {
    return this._state;
  }

  start(): void {
    this.manuallyClosed = false;
    this.attempt = 0;
    this.authRetried = false;
    this.connect();
  }

  stop(): void {
    this.manuallyClosed = true;
    this.clearTimers();
    this.closeSocket();
    this.setState(STATE_CLOSED, '');
  }

  sendPayloadJson(jsonText: string): boolean {
    if (this._state !== STATE_PAIRED || this.ws === undefined) {
      return false;
    }
    // 中继协议: 应用 payload 必须包在 {type:"data", payload, client_ts} 帧里
    let payloadObj: Record<string, Object>;
    try {
      payloadObj = JSON.parse(jsonText) as Record<string, Object>;
    } catch (e) {
      hilog.error(0x0000, TAG, '[relay2] sendPayloadJson parse failed');
      return false;
    }
    const frame: Record<string, Object> = {
      'type': 'data',
      'payload': payloadObj,
      'client_ts': nowSec()
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
        hilog.error(0x0000, TAG, '[relay2] ws send failed code=%{public}d', err.code);
        // 发送失败说明链路已坏：立即退避重连，避免依赖 30s 心跳看门狗
        this.reconnectWithBackoff();
      }
    });
  }

  private connect(): void {
    if (this.manuallyClosed) {
      return;
    }
    this.clearReconnect();
    this.generation += 1;
    const gen = this.generation;
    this.lastAckAt = Date.now();
    this.setState(STATE_CONNECTING, this.attempt > 0 ? `第 ${this.attempt + 1} 次尝试` : '');
    // 短时 token（60s）每次连接前现取；取 token 失败视同连接失败走退避
    this.tokenProvider()
      .then((token: string) => {
        if (this.manuallyClosed || gen !== this.generation) {
          return;
        }
        this.openSocket(token, gen);
      })
      .catch((e: Object) => {
        if (this.manuallyClosed || gen !== this.generation) {
          return;
        }
        const detail = e instanceof Error ? (e as Error).message : '获取连接令牌失败';
        hilog.error(0x0000, TAG, '[relay2] token provider failed: %{public}s', detail);
        if (detail.indexOf('登录') >= 0) {
          // 账号登录缺失/过期：停止重试，交由上层引导重新登录
          this.setState(STATE_ERROR, detail);
        } else {
          this.setState(STATE_RECONNECTING, '网络异常，即将重试');
          this.scheduleReconnect(0);
        }
      });
  }

  private openSocket(token: string, gen: number): void {
    const origin = this.binding.endpointOrigin.replace(/\/$/, '');
    let host = origin;
    if (host.startsWith('https://')) {
      host = 'wss://' + host.substring(8);
    } else if (host.startsWith('http://')) {
      host = 'ws://' + host.substring(7);
    }
    let url = host + '/api/v1/remote/ws2?token=' + encodeURIComponent(token);
    // 关键：mid 必须用二维码里的桌面 deviceMid（中继靠它把终端关联到设备并完成配对）。
    // 实测 2026-11-11：带桌面 mid → 设备上线即 matched；带自造 mid → 永不配对且引发互踢循环。
    const mid = this.binding.deviceMid.length > 0 ? this.binding.deviceMid : this.binding.phoneMid;
    if (mid.length > 0) {
      url += '&mid=' + encodeURIComponent(mid);
    }

    const sock = webSocket.createWebSocket();
    this.ws = sock;
    sock.on('open', (err: BusinessError, value: Object) => {
      if (this.ws !== sock || gen !== this.generation) {
        return;
      }
      this.doAuth(sock);
    });
    sock.on('message', (err: BusinessError, value: String | ArrayBuffer) => {
      if (this.ws !== sock || gen !== this.generation) {
        return;
      }
      if (typeof value === 'string') {
        this.handleText(value as string);
      } else if (value instanceof ArrayBuffer) {
        this.handleText(Bytes.toStr(new Uint8Array(value)));
      }
    });
    sock.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (this.ws !== sock || gen !== this.generation) {
        return;
      }
      hilog.warn(0x0000, TAG, '[relay2] ws close code=%{public}d state=%{public}s',
        value !== undefined ? value.code : 0, this._state);
      this.stopHeartbeat();
      // 关键：终态错误（KICKED/鉴权失败等）后严禁自动重连——
      // 中继按 sid 槽位管理会话，被顶后立刻重连会把刚接管的桌面/其他端又顶掉，形成互踢死循环
      if (!this.manuallyClosed && this._state !== STATE_ERROR && this._state !== STATE_CLOSED) {
        this.scheduleReconnect(0);
      }
    });
    sock.on('error', (err: BusinessError) => {
      if (this.ws !== sock || gen !== this.generation) {
        return;
      }
      const msg = err !== undefined && err.message !== undefined ? err.message : '';
      hilog.error(0x0000, TAG, '[relay2] ws error code=%{public}d msg=%{public}s state=%{public}s',
        err !== undefined ? err.code : 0, msg, this._state);
      this.stopHeartbeat();
      if (this._state !== STATE_PAIRED) {
        this.setState(STATE_RECONNECTING, msg.length > 0 ? '网络异常，即将重试' : '连接失败，即将重试');
      }
    });

    sock.connect(url, (err: BusinessError) => {
      if (err !== undefined && err.code !== undefined && err.code !== 0) {
        if (this.ws === sock && gen === this.generation && !this.manuallyClosed) {
          this.stopHeartbeat();
          this.scheduleReconnect(0);
        }
      }
    });
  }

  /** V2 无挑战应答：连接建立即发 auth_init（token 已在 URL 里完成身份认证） */
  private doAuth(sock: webSocket.WebSocket): void {
    this.setState(STATE_AUTHENTICATING, '');
    this.armAuthWatchdog(sock);
    const init: Record<string, Object> = {
      'type': 'auth_init',
      'device_sid': this.binding.deviceSid,
      'meta': {
        'platform': 'harmonyos',
        'version': APP_VERSION,
        'name': PhoneInfo.phoneName()
      } as Record<string, Object>,
      'client_ts': nowSec()
    };
    this.sendText(JSON.stringify(init));
  }

  private handleText(text: string): void {
    let msg: Record<string, Object> | undefined = undefined;
    try {
      msg = JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      hilog.warn(0x0000, TAG, '[relay2] non-json frame len=%{public}d', text.length);
      return;
    }
    if (msg === undefined) {
      return;
    }
    const type = jStr(msg, 'type');
    if (type === 'auth_challenge') {
      // V2 不应出现；出现说明桌面/中继版本回退——无法应答，报错交上层
      hilog.error(0x0000, TAG, '[relay2] unexpected auth_challenge (V1 relay?)');
      this.setState(STATE_ERROR, '中继要求 V1 鉴权（桌面端可能已回退版本）');
      return;
    }
    if (type === 'auth_ack' || type === 'pair_status_ack') {
      this.lastAckAt = Date.now();
      this.clearAuthWatchdog();
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
      this.handleRelayError(jStr(msg, 'code'), jStr(msg, 'message'));
      return;
    }
  }

  private applyPairStatus(pairStatus: string): void {
    this.armWatchdog();
    if (pairStatus === 'waiting') {
      this.attempt = 0;
      this.setState(STATE_WAITING, '等待桌面端开启远程控制');
      this.startHeartbeat();
      return;
    }
    if (pairStatus === 'matched') {
      this.attempt = 0;
      this.authRetried = false;
      this.setState(STATE_PAIRED, '');
      this.startHeartbeat();
      return;
    }
  }

  private handleRelayError(code: string, message: string): void {
    hilog.error(0x0000, TAG, '[relay2] relay ERROR code=%{public}s message=%{public}s state=%{public}s',
      code, message, this._state);
    if (code === 'DEVICE_OFFLINE') {
      this.setState(STATE_WAITING, '桌面端暂时离线，等待恢复');
      this.startHeartbeat();
      return;
    }
    if (code === 'KICKED') {
      this.setState(STATE_ERROR, '连接被顶掉（其他设备接管了此绑定）');
      this.stopHeartbeat();
      return;
    }
    if (code === 'AUTH_FAILED') {
      if (!this.authRetried) {
        // 重取一次 token 再连（token 60s 过期/瞬时不一致）
        this.authRetried = true;
        hilog.warn(0x0000, TAG, '[relay2] AUTH_FAILED, retry with fresh token');
        this.reconnectNow();
        return;
      }
      this.setState(STATE_ERROR, '账号鉴权失败，请重新登录或重新扫码绑定');
      this.stopHeartbeat();
      return;
    }
    if (code === 'WRONG_PARAM') {
      this.setState(STATE_ERROR, '连接参数被拒（协议不匹配），请重新扫码绑定');
      this.stopHeartbeat();
      return;
    }
    // INTERNAL 等：走指数退避重连，避免服务端持续报错时形成紧循环
    this.setState(STATE_RECONNECTING, message.length > 0 ? '服务异常，重连中' : '中继内部错误，重连中');
    this.reconnectWithBackoff();
  }

  private authWatchdogTimer: number = -1;

  private armAuthWatchdog(sock: webSocket.WebSocket): void {
    this.clearAuthWatchdog();
    this.authWatchdogTimer = setTimeout(() => {
      this.authWatchdogTimer = -1;
      if (this.ws === sock && (this._state === STATE_AUTHENTICATING || this._state === STATE_CONNECTING)) {
        hilog.error(0x0000, TAG, '[relay2] auth watchdog fired, reconnecting');
        this.reconnectNow();
      }
    }, 10000);
  }

  private clearAuthWatchdog(): void {
    if (this.authWatchdogTimer !== -1) {
      clearTimeout(this.authWatchdogTimer);
      this.authWatchdogTimer = -1;
    }
  }

  /** 带退避的重连（保留 attempt 计数） */
  private reconnectWithBackoff(): void {
    this.stopHeartbeat();
    this.closeSocket();
    this.scheduleReconnect(0);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.armWatchdog();
    // waiting 态立即发一次心跳：中继靠终端的 pair_status_query 触发与桌面会话的匹配
    this.sendPairStatusQuery();
    this.heartbeatTimer = setInterval(() => {
      this.sendPairStatusQuery();
    }, 10000);
  }

  /**
   * 终端心跳：必须带 device_sid（V1 同款）。实测桌面会话在 waiting_terminal 时，
   * 终端心跳是中继执行"终端↔设备"匹配的触发器；不带 sid 时中继匹配行为异常
   * （表现为桌面会话被 KICKED 而非配对成功，2026-11-11 真机实测）。
   */
  private sendPairStatusQuery(): void {
    const q: Record<string, Object> = {
      'type': 'pair_status_query',
      'device_sid': this.binding.deviceSid,
      'client_ts': nowSec()
    };
    if (this.ws !== undefined) {
      this.sendText(JSON.stringify(q));
    }
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
    this.closeSocket();
    this.connect();
  }

  private closeSocket(): void {
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
    this.clearAuthWatchdog();
    this.clearReconnect();
  }

  private setState(state: string, detail: string): void {
    if (this._state === state && this.detail === detail) {
      return;
    }
    hilog.info(0x0000, TAG, '[relay2] state %{public}s -> %{public}s (%{public}s)',
      this._state, state, detail);
    this._state = state;
    this.detail = detail;
    if (this.onState !== undefined) {
      this.onState(state, detail);
    }
  }
}

/** V2 帧时间戳用秒（桌面端 Math.floor(Date.now()/1e3) 同款） */
function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}
