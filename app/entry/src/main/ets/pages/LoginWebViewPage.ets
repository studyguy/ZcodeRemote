import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ZcodeService } from '../service/ZcodeService';
import { AuthMirror } from '../service/AuthMirror';

const TAG: string = 'ZCRemote';

/**
 * V2 账号登录页：
 *  加载官方 /web-remote 登录门（选 Z.ai / BigModel → OAuth → 回调后网页把 JWT 写入
 *  localStorage['zcodejwttoken']），注入脚本轮询捕获后经 zrAuth 桥回传本页，
 *  交 ZcodeService.onLoginSuccess 持久化并立即连接。
 *  仅做登录捕获，不做任何业务承载（业务在原生页面）。
 */
const LOGIN_URL: string = 'https://zcode.z.ai/web-remote';
const LOGIN_HOSTS: Array<string> = ['zcode.z.ai', 'chat.z.ai', 'z.ai', 'bigmodel.cn', 'dev.bigmodel.cn', 'zcode.chatglm.site'];

function isTrustedLoginUrl(url: string): boolean {
  if (url.indexOf('https://') !== 0) {
    return false;
  }
  const rest = url.substring('https://'.length);
  const slash = rest.indexOf('/');
  const host = (slash >= 0 ? rest.substring(0, slash) : rest).toLowerCase();
  if (host.indexOf('@') >= 0 || host.indexOf(':') >= 0) {
    return false;
  }
  return LOGIN_HOSTS.includes(host);
}

const AUTH_INJECT: string = `
(function(){
  if (window.__zrAuthInstalled) return;
  window.__zrAuthInstalled = true;
  var last = '';
  setInterval(function(){
    try {
      var t = window.localStorage.getItem('zcodejwttoken') || '';
      if (t && t !== last && t.length > 40) {
        last = t;
        if (window.zrAuth) {
          window.zrAuth.report(t, window.localStorage.getItem('oauth:active_provider') || '');
        }
      }
    } catch (e) {}
  }, 1200);
})();
`;

/** javaScriptProxy 桥：网页 → 壳 */
class AuthBridge {
  private onReport: (jwt: string, provider: string) => void;

  constructor(onReport: (jwt: string, provider: string) => void) {
    this.onReport = onReport;
  }

  report(jwt: string, provider: string): void {
    this.onReport(jwt, provider);
  }
}

@Entry
@Component
struct LoginWebViewPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @State progress: number = 0;
  @State loadError: boolean = false;
  private reported: boolean = false;
  private bridge: AuthBridge = new AuthBridge((jwt: string, provider: string) => {
    this.handleReport(jwt, provider);
  });

  private handleReport(jwt: string, provider: string): void {
    if (this.reported || jwt.length < 40) {
      return;
    }
    this.reported = true;
    hilog.info(0x0000, TAG, '[login] jwt captured provider=%{public}s len=%{public}d', provider, jwt.length);
    // 双写：BindingStore JWT（原生栈资产，休眠）+ AuthMirror（壳方案网页登录态，WebStage 注入用）
    const ctx = getContext(this) as common.UIAbilityContext;
    AuthMirror.save(ctx, jwt, provider);
    ZcodeService.getInstance().onLoginSuccess(jwt).then(() => {
      promptAction.showToast({ message: '登录成功', duration: 1500 });
      router.back();
    }).catch((e: Error) => {
      this.reported = false;
      hilog.error(0x0000, TAG, '[login] save jwt failed: %{public}s', e.message);
      promptAction.showToast({ message: '登录态保存失败：' + e.message, duration: 2500 });
    });
  }

  /** 兜底：onPageEnd 时主动读一次 localStorage（防注入轮询异常） */
  private pollJwtOnce(): void {
    try {
      this.controller.runJavaScript(
        `(window.localStorage.getItem('zcodejwttoken') || '')`,
        (err, value) => {
          if (!err && typeof value === 'string') {
            let jwt = value as string;
            if (jwt.length >= 2 && jwt.startsWith('"')) {
              try {
                jwt = JSON.parse(jwt) as string;
              } catch (e) {
                // keep raw
              }
            }
            this.handleReport(jwt, '');
          }
        });
    } catch (e) {
      // 页面未就绪等，忽略
    }
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 10 }) {
        Button() {
          Text('‹')
            .fontSize(20)
            .fontColor($r('app.color.text_primary'))
        }
        .width(40)
        .height(36)
        .backgroundColor($r('app.color.btn_secondary_bg'))
        .onClick(() => {
          router.back();
        })
        Text('登录 ZCode 账号')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: this.statusBarHeight + 8, bottom: 10 })

      Stack() {
        Web({ src: LOGIN_URL, controller: this.controller })
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .onlineImageAccess(true)
          .zoomAccess(false)
          .fileAccess(false)
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(false)
          .javaScriptOnDocumentStart([{ script: AUTH_INJECT, scriptRules: ['https://zcode.z.ai'] }])
          .javaScriptProxy({
            object: this.bridge,
            name: 'zrAuth',
            methodList: ['report'],
            controller: this.controller
          })
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
            return !isTrustedLoginUrl(event.data.getRequestUrl());
          })
          .onPermissionRequest((event: OnPermissionRequestEvent) => {
            const req = event.request;
            if (req.getOrigin() !== 'https://zcode.z.ai') {
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
          .onProgressChange((event: OnProgressChangeEvent) => {
            this.progress = event.newProgress;
          })
          .onPageEnd(() => {
            // JWT 捕获只在受信任主站由 documentStart 脚本完成；不从 OAuth provider 页面读取存储。
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            const failedUrl = event.request.getRequestUrl();
            if (failedUrl.indexOf('zcode.z.ai') >= 0 || failedUrl.indexOf('bigmodel') >= 0) {
              this.loadError = true;
            }
          })
          .width('100%')
          .height('100%')

        if (this.progress < 100 && !this.loadError) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color($r('app.color.accent'))
        }
        if (this.loadError) {
          Column({ space: 12 }) {
            Text('页面加载失败')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            Text('请检查手机网络后重试')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Button('重新加载')
              .onClick(() => {
                this.loadError = false;
                this.progress = 0;
                try {
                  this.controller.refresh();
                } catch (e) {
                  // ignore
                }
              })
          }
          .width('100%')
          .padding({ top: 60 })
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
