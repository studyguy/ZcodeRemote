import { promptAction, router, window, display } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BindingStore } from '../store/BindingStore';
import { QrParser, QrParseResult } from '../store/QrParser';
import { PhoneInfo } from '../model/PhoneInfo';
import { BindingInfo, WebRouteParams } from '../model/Models';
import { ShellBridge, buildInjectScript, compatUrl } from '../bridge/ShellBridge';
import { AuthMirror } from '../service/AuthMirror';
import { NotifyService } from '../service/NotifyService';

const TAG: string = 'ZCRemote';
const TRUSTED_ORIGIN: string = 'https://zcode.z.ai';
const TRUSTED_HOSTS: Array<string> = ['zcode.z.ai', 'chat.z.ai', 'z.ai', 'bigmodel.cn', 'dev.bigmodel.cn', 'zcode.chatglm.site'];

/**
 * 主容器页（壳优先重构 2026-11-11 的产品核心）：
 *  官方网页 = 业务引擎（全屏沉浸，状态栏取色融合）；
 *  原生层 = 状态胶囊（状态机唯一出口）+ 通知横幅队列 + 异常接管层（加载失败/绑定失效）。
 * 能力自 WebPage.ets 逐项搬运：主题联动、auth 镜像、通知提醒、断网退避重连、
 * 返回手势接管、多设备切换、防截屏、深度链接、进度条、权限自动授予。
 */

/** 横幅队列项（@State 数组元素必须是类实例） */
class BannerItem {
  key: string = '';
  text: string = '';
}

/** 网页视图类型（注入脚本 view 探测）→ 胶囊状态 */
const VIEW_LABELS: Map<string, string> = new Map([
  ['login', '请登录 ZCode 账号'],
  ['connecting', '连接中…'],
  ['waiting', '等待桌面端配对'],
  ['list', '已连接'],
  ['session', '已连接'],
  ['unknown', '已打开']
]);

@Entry
@Component
struct WebStage {
  @State targetUrl: string = '';
  @State loadError: boolean = false;
  @State webDark: boolean = true;
  @State webTopColor: string = '#0D1117';
  @State progress: number = 0;
  @State netOk: boolean = true;
  @State privacyOn: boolean = false;
  @State pairingInvalid: boolean = false;
  @State viewKind: string = 'unknown';
  @State attentionOn: boolean = false;
  @State runningTasks: Array<string> = [];
  @State statsSheetShow: boolean = false;
  @State banners: Array<BannerItem> = [];
  @State devices: Array<BindingInfo> = [];
  @State sheetShow: boolean = false;
  @State deviceName: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('appForeground') appForeground: number = 1;
  @StorageProp('pendingBindUrl') @Watch('onPendingBind') pendingBindUrl: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: ShellBridge = new ShellBridge();
  private netConn: connection.NetConnection | undefined = undefined;
  private retryAttempts: number = 0;
  private retryTimer: number = -1;
  private disposed: boolean = false;
  private bannerSeq: number = 0;
  private authToken: string = '';
  private authProvider: string = '';
  /** taskDone 冷却表（标题→上次上报时刻），防 spinner 抖动重复通知 */
  private doneSeen: Map<string, number> = new Map();

  aboutToAppear(): void {
    this.disposed = false;
    // 生产壳默认不开放 WebView DevTools，避免网页内部状态可被本机调试端口读取。
    this.initTheme();
    this.initBridge();
    this.loadAuthMirror();
    NotifyService.ensurePermission(getContext(this) as common.UIAbilityContext);
    this.applyPrivacyPref();
    this.watchNetwork();
    this.refreshDevices();
    this.resolveTargetUrl();
    this.consumePendingBind();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /** 系统返回/侧滑：网页能后退则后退网页历史；无历史时交系统默认 */
  onBackPress(): boolean {
    try {
      const can = this.controller.accessBackward();
      hilog.info(0x0000, TAG, 'back: canBack=%{public}s url=%{public}s', String(can),
        this.targetUrl.substring(0, 40));
      if (can) {
        this.controller.backward();
        return true;
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'back: controller not ready');
    }
    return false;
  }

  /** ============ 入口 URL 解析（路由参数 → 内存绑定 → 存储） ============ */

  /** Only official ZCode and OAuth hosts may be loaded in the shell WebView. */
  private isTrustedUrl(url: string): boolean {
    if (url.indexOf('https://') !== 0) {
      return false;
    }
    const rest = url.substring('https://'.length);
    const slash = rest.indexOf('/');
    const host = (slash >= 0 ? rest.substring(0, slash) : rest).toLowerCase();
    // 拒绝 userinfo / 端口仿冒（如 https://zcode.z.ai.evil.com 与 https://user@zcode.z.ai:8080）
    if (host.indexOf('@') >= 0 || host.indexOf(':') >= 0) {
      return false;
    }
    return TRUSTED_HOSTS.includes(host);
  }

  private resolveTargetUrl(): void {
    const params = router.getParams() as Record<string, Object>;
    const url = params !== undefined && params['url'] !== undefined ? params['url'] as string : '';
    if (url.length > 0) {
      if (this.isTrustedUrl(url)) {
        this.setTargetUrl(url);
      } else {
        this.rejectUntrustedUrl();
      }
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.load(ctx).then((loaded) => {
      if (loaded !== undefined) {
        this.setTargetUrl(loaded.boundUrl);
      }
    }).catch(() => {
      // ignore
    });
  }

  private rejectUntrustedUrl(): void {
    this.loadError = true;
    this.pairingInvalid = false;
    promptAction.showToast({ message: '为保护账号登录态，已拒绝非官方网页地址', duration: 2500 });
  }

  private setTargetUrl(url: string): void {
    if (!this.isTrustedUrl(url)) {
      this.rejectUntrustedUrl();
      return;
    }
    // SPA 主题参数 theme=system：官方网页随系统深浅渲染，载入前后壳侧配色保持一致。
    let finalUrl = compatUrl(url);
    if (finalUrl.indexOf('theme=') < 0) {
      finalUrl += (finalUrl.indexOf('?') >= 0 ? '&' : '?') + 'theme=system';
    }
    this.targetUrl = finalUrl;
    const parsed: QrParseResult = QrParser.parse(finalUrl);
    this.deviceName = parsed.ok && parsed.info !== undefined ? parsed.info.deviceName : '';
    this.updateCapsule();
  }

  /** ============ 消息桥 v2 事件分发 ============ */

  private initBridge(): void {
    this.bridge.onEvent = (tag: string, payload: string) => {
      this.onBridgeEvent(tag, payload);
    };
  }

  private onBridgeEvent(tag: string, payload: string): void {
    if (this.disposed) {
      return;
    }
    if (tag === 'theme') {
      this.onWebTheme(payload);
      return;
    }
    if (tag === 'auth') {
      try {
        const o = JSON.parse(payload) as Record<string, string>;
        this.onAuthState(o['t'] !== undefined ? o['t'] as string : '',
          o['p'] !== undefined ? o['p'] as string : '');
      } catch (e) {
        // ignore
      }
      return;
    }
    if (tag === 'view') {
      try {
        const o = JSON.parse(payload) as Record<string, string>;
        const kind = o['kind'] !== undefined ? o['kind'] as string : 'unknown';
        if (kind !== this.viewKind) {
          this.viewKind = kind;
          if (kind === 'invalid') {
            this.pairingInvalid = true;
          } else if (this.pairingInvalid) {
            this.pairingInvalid = false;
          }
          this.updateCapsule();
        }
      } catch (e) {
        // ignore
      }
      return;
    }
    if (tag === 'attention') {
      this.onAttention(payload === '1');
      return;
    }
    if (tag === 'taskStats') {
      try {
        const o = JSON.parse(payload) as Record<string, Object>;
        const arr = o['titles'];
        if (Array.isArray(arr)) {
          const titles: Array<string> = [];
          for (const t of arr as Array<Object>) {
            if (typeof t === 'string' && (t as string).length > 0) {
              titles.push(t as string);
            }
          }
          this.runningTasks = titles;
        }
      } catch (e) {
        // ignore
      }
      return;
    }
    if (tag === 'taskDone') {
      try {
        const o = JSON.parse(payload) as Record<string, string>;
        this.onTaskDone(o['title'] !== undefined ? o['title'] as string : '',
          o['status'] !== undefined ? o['status'] as string : '');
      } catch (e) {
        // ignore
      }
      return;
    }
    if (tag === 'pairInvalid') {
      const on = payload === '1';
      if (on !== this.pairingInvalid) {
        this.pairingInvalid = on;
        this.updateCapsule();
        if (on && this.appForeground !== 1) {
          NotifyService.vibrate();
          NotifyService.notify('ZCode 绑定已失效', '桌面端可能已更新或重置配对，请重新扫码绑定', 2002);
        }
      }
      return;
    }
  }

  /** ============ 状态胶囊（状态机唯一出口） ============ */

  private updateCapsule(): void {
    // 由状态字段在 build 中推导；此处仅处理设备名等副产物
  }

  private capsuleDotColor(): string {
    if (!this.netOk) {
      return '#E5484D';
    }
    if (this.loadError) {
      return '#E5484D';
    }
    if (this.pairingInvalid) {
      return '#E8710A';
    }
    if (this.progress > 0 && this.progress < 100) {
      return '#F5A623';
    }
    if (this.viewKind === 'login') {
      return '#3B6FE0';
    }
    if (this.viewKind === 'connecting' || this.viewKind === 'waiting') {
      return '#F5A623';
    }
    if (this.viewKind === 'list' || this.viewKind === 'session') {
      return '#34C759';
    }
    return this.webDark ? '#8B93A7' : '#6B7280';
  }

  private capsuleText(): string {
    if (!this.netOk) {
      return '网络不可用';
    }
    if (this.loadError) {
      return '加载失败';
    }
    if (this.pairingInvalid) {
      return '绑定已失效';
    }
    const label = VIEW_LABELS.get(this.viewKind);
    const base = label !== undefined ? label : '已打开';
    if ((this.viewKind === 'list' || this.viewKind === 'session' || this.viewKind === 'unknown') &&
      this.deviceName.length > 0) {
      return base + ' · ' + this.deviceName;
    }
    return base;
  }

  /** ============ 主题联动（网页取色 → 状态栏/胶囊配色） ============ */

  private initTheme(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.webDark = ctx.config.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } catch (e) {
      this.webDark = true;
    }
    this.webTopColor = this.webDark ? '#0D1117' : '#FFFFFF';
    this.applyStatusBarContent(this.webDark);
  }

  private onWebTheme(info: string): void {
    const segs = info.split('|');
    const dark = segs.length > 0 && segs[0] === '1';
    const bodyBg = segs.length > 1 ? segs[1] : '';
    const topRaw = segs.length > 2 ? segs[2] : '';
    const hexOf = (rgb: string): string => {
      const parts = this.parseColorNums(rgb);
      if (parts.length < 3) {
        return '';
      }
      const hex = (v: number): string => v.toString(16).padStart(2, '0');
      return '#' + hex(parts[0]) + hex(parts[1]) + hex(parts[2]);
    };
    this.webDark = dark;
    this.webTopColor = hexOf(topRaw).length > 0 ? hexOf(topRaw)
      : (hexOf(bodyBg).length > 0 ? hexOf(bodyBg) : (dark ? '#0D1117' : '#FFFFFF'));
    this.applyStatusBarContent(dark);
  }

  private parseColorNums(s: string): Array<number> {
    const out: Array<number> = [];
    let v = '';
    for (let i = 0; i < s.length; i++) {
      const c = s.charAt(i);
      if (c >= '0' && c <= '9') {
        v += c;
      } else if (v.length > 0) {
        out.push(parseInt(v));
        v = '';
      }
    }
    if (v.length > 0) {
      out.push(parseInt(v));
    }
    return out;
  }

  private applyStatusBarContent(dark: boolean): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(ctx).then((w) => {
        const props: window.SystemBarProperties = {
          statusBarContentColor: dark ? '#F2F4F8' : '#232A38'
        };
        w.setWindowSystemBarProperties(props);
      }).catch(() => {
        // ignore
      });
    } catch (e) {
      // ignore
    }
  }

  /** ============ 登录态镜像 ============ */

  private loadAuthMirror(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const data = AuthMirror.load(ctx);
    this.authToken = data.t;
    this.authProvider = data.p;
  }

  private onAuthState(token: string, provider: string): void {
    if (token === this.authToken && provider === this.authProvider) {
      return;
    }
    this.authToken = token;
    this.authProvider = provider;
    const ctx = getContext(this) as common.UIAbilityContext;
    AuthMirror.save(ctx, token, provider);
  }

  /** ============ 提醒（前台横幅 / 后台通知） ============ */

  private onAttention(on: boolean): void {
    this.attentionOn = on;
    if (!on) {
      return;
    }
    if (this.appForeground === 1) {
      this.pushBanner('桌面任务有待处理的确认或提问');
      return;
    }
    NotifyService.vibrate();
    NotifyService.notify('ZCode 需要你的确认', '桌面任务有待处理的确认或提问，点按打开查看。', 2001);
  }

  private onTaskDone(title: string, status: string): void {
    // 冷却去重：spinner 抖动会对同一标题重复上报，8 分钟内只认第一次
    const now = Date.now();
    const last = this.doneSeen.get(title);
    if (last !== undefined && now - last < 480000) {
      return;
    }
    this.doneSeen.set(title, now);
    if (this.appForeground === 1) {
      this.pushBanner(`任务${status}：${title}`);
      return;
    }
    NotifyService.vibrate();
    const head = status === '失败' ? 'ZCode 任务失败'
      : status === '已取消' ? 'ZCode 任务已取消' : 'ZCode 任务已完成';
    NotifyService.notify(head, '有 ZCode 任务状态更新，点按打开查看。', 2200);
  }

  private pushBanner(text: string): void {
    const item = new BannerItem();
    item.key = 'b' + (this.bannerSeq++);
    item.text = text;
    const next = this.banners.slice();
    next.push(item);
    this.banners = next;
    setTimeout(() => {
      this.banners = this.banners.filter((b: BannerItem): boolean => b.key !== item.key);
    }, 3000);
  }

  /** ============ 网络 / 加载 / 重试 ============ */

  private watchNetwork(): void {
    try {
      this.netConn = connection.createNetConnection();
      this.netConn.on('netLost', () => {
        if (this.disposed) {
          return;
        }
        this.netOk = false;
        this.updateCapsule();
      });
      this.netConn.on('netAvailable', () => {
        if (this.disposed) {
          return;
        }
        const wasDown = !this.netOk;
        this.netOk = true;
        if (wasDown && this.loadError) {
          this.retryAttempts = 0;
          this.loadError = false;
          this.loadTarget();
        }
        this.updateCapsule();
      });
      connection.hasDefaultNet().then((ok) => {
        this.netOk = ok;
      }).catch(() => {
        // ignore
      });
    } catch (e) {
      // ignore
    }
  }

  private scheduleRetry(): void {
    if (this.retryTimer >= 0) {
      return;
    }
    const delays: Array<number> = [1500, 4000, 9000];
    const idx = Math.min(this.retryAttempts, delays.length - 1);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      if (this.disposed) {
        return;
      }
      this.retryAttempts += 1;
      this.loadError = false;
      this.loadTarget();
    }, delays[idx]);
  }

  private loadTarget(): void {
    try {
      this.controller.loadUrl(this.targetUrl);
      this.loadError = false;
      this.progress = 1;
    } catch (e) {
      this.loadError = true;
    }
    this.updateCapsule();
  }

  private doRefresh(): void {
    try {
      this.controller.refresh();
    } catch (e) {
      this.loadTarget();
    }
  }

  /** ============ 深度链接（桌面端分享的 remote/v4 链接） ============ */

  private onPendingBind(): void {
    this.consumePendingBind();
  }

  private consumePendingBind(): void {
    const url = this.pendingBindUrl;
    if (url.length === 0) {
      return;
    }
    AppStorage.setOrCreate('pendingBindUrl', '');
    const parsed: QrParseResult = QrParser.parse(url);
    if (!parsed.ok || parsed.info === undefined) {
      promptAction.showToast({ message: '链接无效：' + parsed.error, duration: 2500 });
      return;
    }
    const info = parsed.info;
    if (this.targetUrl.indexOf('sid=' + info.deviceSid) >= 0) {
      // 同一台设备：静默刷新
      this.setTargetUrl(url);
      this.loadTarget();
      return;
    }
    promptAction.showDialog({
      title: '绑定新电脑',
      message: `设备：${info.deviceName}\n服务器：${info.endpointOrigin}\n\n将保存为新的绑定并切换过去。`,
      buttons: [
        { text: '取消', color: '#9AA1B5' },
        { text: '绑定', color: '#3B6FE0' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      BindingStore.save(ctx, info).then(() => {
        this.refreshDevices();
        this.setTargetUrl(info.boundUrl);
        this.loadTarget();
        promptAction.showToast({ message: `已绑定 ${info.deviceName}`, duration: 2000 });
      }).catch(() => {
        promptAction.showToast({ message: '保存绑定失败', duration: 2000 });
      });
    });
  }

  /** ============ 多设备 / 壳操作 ============ */

  private refreshDevices(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.loadAll(ctx).then((all) => {
      this.devices = all;
    }).catch(() => {
      // ignore
    });
  }

  private currentSid(): string {
    const parsed: QrParseResult = QrParser.parse(this.targetUrl);
    return parsed.ok && parsed.info !== undefined ? parsed.info.deviceSid : '';
  }

  private switchDevice(sid: string): void {
    this.sheetShow = false;
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.setActive(ctx, sid).then((info) => {
      if (info !== undefined) {
        this.setTargetUrl(info.boundUrl);
        this.retryAttempts = 0;
        this.loadTarget();
        promptAction.showToast({ message: `已切换到 ${info.deviceName}`, duration: 1800 });
      }
    }).catch(() => {
      promptAction.showToast({ message: '切换失败', duration: 1800 });
    });
  }

  private copyLink(): void {
    this.sheetShow = false;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.targetUrl);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '链接已复制', duration: 1800 });
      }).catch(() => {
        // ignore
      });
    } catch (e) {
      // ignore
    }
  }

  private applyPrivacyPref(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.privacyOn = BindingStore.getPrivacyMode(ctx);
    this.applyPrivacy(this.privacyOn);
  }

  private applyPrivacy(on: boolean): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(ctx).then((w) => {
        w.setWindowPrivacyMode(on).catch(() => {
          // ignore
        });
      }).catch(() => {
        // ignore
      });
    } catch (e) {
      // ignore
    }
  }

  /** 移除当前电脑绑定 → 回扫码页（其他绑定保留，可在胶囊菜单切回） */
  private removeCurrentBinding(): void {
    this.sheetShow = false;
    const sid = this.currentSid();
    promptAction.showDialog({
      title: '移除当前电脑绑定',
      message: '将清除本机保存的该电脑绑定，需要重新扫码。其他已绑定电脑不受影响。',
      buttons: [
        { text: '取消', color: '#9AA1B5' },
        { text: '移除', color: '#C0392B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const job = sid.length > 0 ? BindingStore.removeDevice(ctx, sid) : BindingStore.clear(ctx);
      job.then(() => {
        router.replaceUrl({ url: 'pages/BindPage' });
      }).catch(() => {
        // ignore
      });
    });
  }

  /** ============ UI ============ */

  build() {
    Stack() {
      // 主列：胶囊行 + 网页区
      Column() {
        this.capsuleRow()
        Stack() {
          if (this.loadError) {
            this.errorView()
          } else {
            Web({ src: this.targetUrl, controller: this.controller })
              .domStorageAccess(true)
              .javaScriptAccess(true)
              .onlineImageAccess(true)
              .zoomAccess(false)
              .fileAccess(false)
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(false)
              .javaScriptOnDocumentStart([{
                script: buildInjectScript(PhoneInfo.phoneName(), this.authToken, this.authProvider, true),
                scriptRules: [TRUSTED_ORIGIN]
              }])
              .javaScriptProxy({
                object: this.bridge,
                name: 'zrNative',
                methodList: ['post'],
                controller: this.controller
              })
              .javaScriptProxy({
                object: this.bridge,
                name: 'zrNative',
                methodList: ['post'],
                controller: this.controller
              })
              .onProgressChange((event: OnProgressChangeEvent) => {
                this.progress = event.newProgress;
              })
              .onPageEnd(() => {
                this.retryAttempts = 0;
                this.progress = 100;
              })
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
            const requestUrl = event.data.getRequestUrl();
            if (this.isTrustedUrl(requestUrl)) {
              return false;
            }
            hilog.warn(0x0000, TAG, 'blocked WebView navigation outside trusted host');
            return true;
          })
          .onPermissionRequest((event: OnPermissionRequestEvent) => {
            // Web 权限仅授予官方 ZCode origin；任何外部/恶意子页一律拒绝。
            const req = event.request;
            if (req.getOrigin() !== TRUSTED_ORIGIN) {
              hilog.warn(0x0000, TAG, 'denied WebView permission for untrusted origin');
              req.deny();
              return;
            }
            const allowed: string[] = [];
            for (const resource of req.getAccessibleResource()) {
              if (resource === 'TYPE_VIDEO_CAPTURE' || resource === 'TYPE_AUDIO_CAPTURE') {
                allowed.push(resource);
              }
            }
            if (allowed.length > 0) {
              req.grant(allowed);
            } else {
              req.deny();
            }
          })
              .onErrorReceive((event: OnErrorReceiveEvent) => {
                // 主文档失败才进错误态（子资源忽略），并自动退避重试
                const failedUrl = event.request.getRequestUrl();
                if (failedUrl === this.targetUrl || failedUrl.indexOf('/remote/v4') >= 0) {
                  this.loadError = true;
                  this.scheduleRetry();
                }
              })
              .width('100%')
              .height('100%')
          }

          // 通知横幅队列（网页区顶部）
          Column({ space: 6 }) {
            ForEach(this.banners, (b: BannerItem) => {
              Row({ space: 8 }) {
                Circle({ width: 6, height: 6 }).fill($r('app.color.accent'))
                Text(b.text)
                  .fontSize(12)
                  .fontColor(this.webDark ? '#E7ECF5' : '#232A38')
                  .maxLines(2)
              }
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(18)
              .backgroundColor(this.webDark ? '#E62A3040' : '#E6F2F4F8')
            }, (b: BannerItem) => {
              return b.key;
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
          .alignItems(HorizontalAlign.Start)

          // 加载进度条
          Row()
            .width(this.progress + '%')
            .height(2)
            .backgroundColor($r('app.color.accent'))
            .position({ x: 0, y: 0 })
            .visibility(this.progress > 0 && this.progress < 100 ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .layoutWeight(1)
        .alignContent(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      // 异常接管层（覆盖全屏：绑定失效 / 加载失败）
      if (this.pairingInvalid || (this.loadError && !this.netOk)) {
        this.takeoverPairing()
      } else if (this.loadError) {
        this.takeoverLoadError()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.statusBarHeight })
    .backgroundColor(this.webTopColor)
  }

  /** 状态胶囊行（状态机唯一出口；左=胶囊→设备菜单，右=运行任务徽章→任务面板；上下等距） */
  @Builder
  capsuleRow() {
    Row() {
      Row({ space: 6 }) {
        Circle({ width: 6, height: 6 })
          .fill(this.capsuleDotColor())
        Text(this.capsuleText())
          .fontSize(11)
          .fontColor(this.webDark ? '#C9D1E0' : '#3A4154')
          .maxLines(1)
        Text('▾')
          .fontSize(9)
          .fontColor(this.webDark ? '#8B93A7' : '#9AA1B5')
      }
      .padding({ left: 10, right: 8, top: 4, bottom: 4 })
      .borderRadius(14)
      .backgroundColor(this.webDark ? '#992A3040' : '#99F2F4F8')
      .onClick(() => {
        this.refreshDevices();
        this.sheetShow = true;
      })
      Blank()
      if (this.runningTasks.length > 0 || this.attentionOn) {
        Row({ space: 6 }) {
          Circle({ width: 6, height: 6 })
            .fill(this.attentionOn ? '#F5A623' : '#34C759')
          Text(this.statsBadgeText())
            .fontSize(11)
            .fontColor(this.webDark ? '#C9D1E0' : '#3A4154')
        }
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(14)
        .backgroundColor(this.webDark ? '#992A3040' : '#99F2F4F8')
        .onClick(() => {
          this.statsSheetShow = true;
        })
        .bindSheet(this.statsSheetShow, this.statsSheetBuilder(), {
          height: 260,
          blurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
          showClose: false,
          dragBar: false,
          onDisappear: () => {
            this.statsSheetShow = false;
          }
        })
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 5 })
    .alignItems(VerticalAlign.Top)
    .bindSheet(this.sheetShow, this.sheetBuilder(), {
      height: 430,
      blurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
      showClose: false,
      dragBar: false,
      onDisappear: () => {
        this.sheetShow = false;
      }
    })
  }

  private statsBadgeText(): string {
    const running = this.runningTasks.length;
    if (running > 0 && this.attentionOn) {
      return `运行 ${running} · 待确认`;
    }
    if (running > 0) {
      return `运行 ${running}`;
    }
    return '待确认';
  }

  /** 运行任务面板（右侧徽章点击展开） */
  @Builder
  statsSheetBuilder() {
    Column() {
      Column({ space: 8 }) {
        Text(`运行中 ${this.runningTasks.length} · ${this.attentionOn ? '待确认' : '无待确认'}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .padding({ left: 6, top: 4 })
        if (this.runningTasks.length === 0) {
          Text('当前没有运行中的任务')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ left: 6, top: 6 })
        }
        ForEach(this.runningTasks, (t: string) => {
          Row({ space: 8 }) {
            Circle({ width: 6, height: 6 }).fill($r('app.color.chip_running'))
            Text(t)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 6, right: 6, top: 8, bottom: 8 })
          .borderRadius(10)
          .backgroundColor($r('app.color.bg_card'))
        }, (t: string) => {
          return t;
        })
        if (this.attentionOn) {
          Row({ space: 8 }) {
            Circle({ width: 6, height: 6 }).fill('#F5A623')
            Text('有待确认的审批/提问，请在网页中处理')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ left: 6, right: 6, top: 8, bottom: 8 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 16 })
    }
    .width('100%')
    .height('100%')
  }

  /** 加载失败态（网页区内的错误视图；接管层另有覆盖） */
  @Builder
  errorView() {
    Column({ space: 10 }) {
      Text('页面加载失败')
        .fontSize(14)
        .fontColor(this.webDark ? '#E7ECF5' : '#232A38')
      Text('请检查网络；恢复后将自动重连')
        .fontSize(12)
        .fontColor(this.webDark ? '#8B93A7' : '#6B7280')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /** Shell → Web 命令（桥 v2 receive 通道） */
  private sendWebCommand(cmd: Record<string, string>): void {
    try {
      this.controller.runJavaScript('window.__zrReceive&&window.__zrReceive(' + JSON.stringify(cmd) + ')');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'sendWebCommand failed');
    }
  }

  /** 异常接管层：绑定失效（主按钮=账号设备选择器；次=重新扫码） */
  @Builder
  takeoverPairing() {
    Column({ space: 14 }) {
      Text('⚠')
        .fontSize(40)
      Text('网页连接已失效')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.webDark ? '#E7ECF5' : '#232A38')
      Text('可在网页的账号设备列表中选择这台电脑重新连接；\n或重新扫码绑定。')
        .fontSize(13)
        .fontColor(this.webDark ? '#8B93A7' : '#6B7280')
        .textAlign(TextAlign.Center)
      Button('打开设备选择器')
        .width('58%')
        .height(42)
        .backgroundColor($r('app.color.accent'))
        .fontColor(Color.White)
        .onClick(() => {
          this.pairingInvalid = false;
          this.sendWebCommand({ 'cmd': 'click', 'text': '选择其他设备' } as Record<string, string>);
        })
      Row({ space: 24 }) {
        Text('重新扫码')
          .fontSize(13)
          .fontColor($r('app.color.accent'))
          .padding(10)
          .onClick(() => {
            router.replaceUrl({ url: 'pages/BindPage' });
          })
        Text('重试连接')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding(10)
          .onClick(() => {
            this.pairingInvalid = false;
            this.loadTarget();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.webTopColor)
  }

  /** 异常接管层：页面加载失败（自动退避重连进行中） */
  @Builder
  takeoverLoadError() {
    Column({ space: 14 }) {
      Text('📡')
        .fontSize(40)
      Text('页面加载失败')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.webDark ? '#E7ECF5' : '#232A38')
      Text(this.netOk ? '服务无响应，将自动重试' : '网络不可用，恢复后自动重连')
        .fontSize(13)
        .fontColor(this.webDark ? '#8B93A7' : '#6B7280')
        .textAlign(TextAlign.Center)
      Button('立即重试')
        .width('55%')
        .height(42)
        .backgroundColor($r('app.color.accent'))
        .fontColor(Color.White)
        .onClick(() => {
          this.retryAttempts = 0;
          this.loadError = false;
          this.loadTarget();
        })
      Text('回到扫码页')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .padding(10)
        .onClick(() => {
          router.replaceUrl({ url: 'pages/BindPage' });
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.webTopColor)
  }

  /** ============ 设备菜单（胶囊 bindSheet） ============ */

  @Builder
  sheetSectionLabel(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: 6, top: 8, bottom: 2 })
  }

  @Builder
  sheetActionRow(label: string, right: string, labelAccent: boolean, onTap: () => void) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(15)
        .fontColor(labelAccent ? $r('app.color.accent') : $r('app.color.text_primary'))
        .layoutWeight(1)
      if (right.length > 0) {
        Text(right)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: 8, right: 8 })
    .borderRadius(12)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  sheetBuilder() {
    Column() {
      Scroll() {
        Column() {
          this.sheetSectionLabel('网页')
          this.sheetActionRow('刷新页面', '', false, (): void => {
            this.sheetShow = false;
            this.doRefresh();
          })
          this.sheetActionRow('复制页面链接', '', false, (): void => {
            this.copyLink();
          })

          this.sheetSectionLabel(`电脑${this.devices.length > 0 ? ' · ' + this.devices.length : ''}`)
          ForEach(this.devices, (d: BindingInfo) => {
            this.sheetActionRow(d.deviceName,
              d.deviceSid === this.currentSid() ? '✓' : '', false,
              (): void => {
                if (d.deviceSid !== this.currentSid()) {
                  this.switchDevice(d.deviceSid);
                } else {
                  this.sheetShow = false;
                }
              })
          }, (d: BindingInfo) => {
            return d.deviceSid;
          })
          this.sheetActionRow('扫码添加新电脑', '', true, (): void => {
            this.sheetShow = false;
            router.replaceUrl({ url: 'pages/BindPage' });
          })

          this.sheetSectionLabel('更多')
          this.sheetActionRow('设置与设备管理', '', false, (): void => {
            this.sheetShow = false;
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
          this.sheetActionRow('账号重新登录', '', false, (): void => {
            this.sheetShow = false;
            router.pushUrl({ url: 'pages/LoginWebViewPage' });
          })
          Row({ space: 10 }) {
            Text('移除当前电脑绑定')
              .fontSize(15)
              .fontColor($r('app.color.error_text'))
              .layoutWeight(1)
          }
          .width('100%')
          .height(44)
          .padding({ left: 8, right: 8 })
          .borderRadius(12)
          .onClick(() => {
            this.removeCurrentBinding();
          })
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 16, bottom: 10 })
    .borderRadius({ topLeft: 24, topRight: 24 })
  }
}
