import { promptAction, router } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BindingStore } from '../store/BindingStore';
import { QrParser, QrParseResult } from '../store/QrParser';
import { BindingInfo, WebRouteParams } from '../model/Models';

const TAG: string = 'ZCRemote';

/**
 * 扫码绑定页（壳优先重构 2026-11-11）：
 *  双场景自适应——首次绑定（无任何绑定）与添加模式（从 WebStage 胶囊菜单/失效接管层进入，
 *  WebRouteParams.forceBind=true，右上角显示「添加新电脑」且保留返回网页退路）。
 */
@Entry
@Component
struct BindPage {
  @State bindError: string = '';
  @State devices: Array<BindingInfo> = [];
  @State addMode: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('pendingBindUrl') @Watch('onPendingBind') pendingBindUrl: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.addMode = params !== undefined && params['forceBind'] !== undefined
      && params['forceBind'] === true;
    this.refreshDevices();
    this.consumePendingBind();
  }

  onPageShow(): void {
    this.consumePendingBind();
  }

  private refreshDevices(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.loadAll(ctx).then((all) => {
      this.devices = all;
    }).catch(() => {
      // ignore
    });
  }

  private onPendingBind(): void {
    this.consumePendingBind();
  }

  /** 深度链接直绑（未绑定时的落地场景；已绑定时 WebStage 自己消费） */
  private consumePendingBind(): void {
    const url = this.pendingBindUrl;
    if (url.length === 0) {
      return;
    }
    AppStorage.setOrCreate('pendingBindUrl', '');
    this.applyBinding(url);
  }

  private async requestCamera(): Promise<boolean> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const mgr = abilityAccessCtrl.createAtManager();
      const result = await mgr.requestPermissionsFromUser(ctx, ['ohos.permission.CAMERA'] as Array<Permissions>);
      for (const r of result.authResults) {
        if (r === 0) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  private doScan(): void {
    this.requestCamera().then((granted: boolean) => {
      if (!granted) {
        this.bindError = '未授予相机权限，无法扫码；可改用粘贴链接方式';
        return;
      }
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      };
      const ctx = getContext(this) as common.Context;
      scanBarcode.startScanForResult(ctx, options).then((res: scanBarcode.ScanResult) => {
        this.applyBinding(res.originalValue);
      }).catch((e: Error) => {
        hilog.info(0x0000, TAG, 'scan cancelled: %{public}s', e.message);
      });
    });
  }

  private doPaste(): void {
    try {
      pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
        const text = data.getPrimaryText();
        if (text === undefined || text.length === 0) {
          this.bindError = '剪贴板为空；请先在桌面端复制「复制链接」的内容';
          return;
        }
        this.applyBinding(text);
      }).catch(() => {
        this.bindError = '读取剪贴板失败';
      });
    } catch (e) {
      this.bindError = '读取剪贴板失败';
    }
  }

  private applyBinding(text: string): void {
    const parsed: QrParseResult = QrParser.parse(text);
    if (!parsed.ok || parsed.info === undefined) {
      this.bindError = parsed.error;
      return;
    }
    const info: BindingInfo = parsed.info;
    promptAction.showDialog({
      title: this.addMode ? '绑定新电脑' : '确认绑定',
      message: `设备：${info.deviceName}\n服务器：${info.endpointOrigin}\n\n连接时需登录与桌面端相同的 ZCode 账号。`,
      buttons: [
        { text: '取消', color: '#9AA1B5' },
        { text: '确认绑定', color: '#3B6FE0' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      this.bindError = '';
      const ctx = getContext(this) as common.UIAbilityContext;
      BindingStore.save(ctx, info).then(() => {
        promptAction.showToast({ message: `已绑定 ${info.deviceName}`, duration: 2000 });
        router.replaceUrl({ url: 'pages/WebStage', params: new WebRouteParams(info.boundUrl) });
      }).catch((e: Error) => {
        this.bindError = '保存绑定失败: ' + e.message;
      });
    });
  }

  /** 返回网页（添加模式且有现存绑定时提供退路） */
  private backToWeb(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.load(ctx).then((info) => {
      if (info !== undefined) {
        router.replaceUrl({ url: 'pages/WebStage', params: new WebRouteParams(info.boundUrl) });
      } else {
        promptAction.showToast({ message: '暂无已绑定电脑', duration: 1800 });
      }
    }).catch(() => {
      // ignore
    });
  }

  build() {
    Column() {
      if (this.addMode) {
        Row() {
          Button() {
            Text('‹')
              .fontSize(20)
              .fontColor($r('app.color.text_primary'))
          }
          .width(40)
          .height(36)
          .backgroundColor($r('app.color.btn_secondary_bg'))
          .onClick(() => {
            this.backToWeb();
          })
          Text('添加新电脑')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
            .padding({ right: 8 })
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 8 })
      }

      Column({ space: 14 }) {
        Blank().layoutWeight(2)

        Image($r('app.media.app_icon'))
          .width(72)
          .height(72)
          .borderRadius(18)
        Row({ space: 10 }) {
          Text('Zcode Remote')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        Text('在手机上接管电脑上的 ZCode')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))

        Blank().layoutWeight(1)

        Text('扫码前，请在桌面端：\n1. 打开「远程控制」开关\n2. 保持二维码窗口打开')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .lineHeight(20)

        Button('扫码连接')
          .width('62%')
          .height(46)
          .backgroundColor($r('app.color.accent'))
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.doScan();
          })

        Text('粘贴链接绑定')
          .fontSize(13)
          .fontColor($r('app.color.accent'))
          .padding({ top: 6, bottom: 6, left: 16, right: 16 })
          .onClick(() => {
            this.doPaste();
          })

        if (this.bindError.length > 0) {
          Text(this.bindError)
            .fontSize(12)
            .fontColor($r('app.color.error_text'))
            .textAlign(TextAlign.Center)
            .width('86%')
        }

        Blank().layoutWeight(3)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.statusBarHeight })
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea()
  }
}
