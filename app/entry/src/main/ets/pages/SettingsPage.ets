import { promptAction, router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BindingStore } from '../store/BindingStore';
import { BindingInfo } from '../model/Models';

const TAG: string = 'ZCRemote';

/**
 * 设置与设备管理（壳优先重构 2026-11-11 简版）：
 * 电脑列表（当前✓/切换/移除）、扫码添加、防截屏、解绑全部。
 * 数据全部来自 BindingStore；返回 WebStage 后由其自行的绑定读取生效（切换设备后
 * 用户从胶囊菜单重新进入网页即可，或直接返回时 WebStage 仍持有旧 URL——切换动作
 * 同时会提示用户）。
 */
@Entry
@Component
struct SettingsPage {
  @State devices: Array<BindingInfo> = [];
  @State currentSid: string = '';
  @State privacyOn: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  onPageShow(): void {
    this.refresh();
  }

  private refresh(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.load(ctx).then((active) => {
      this.currentSid = active !== undefined ? active.deviceSid : '';
      return BindingStore.loadAll(ctx);
    }).then((all) => {
      this.devices = all;
      this.privacyOn = BindingStore.getPrivacyMode(getContext(this) as common.UIAbilityContext);
    }).catch(() => {
      // ignore
    });
  }

  private switchDevice(sid: string): void {
    if (sid === this.currentSid) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.setActive(ctx, sid).then((info) => {
      if (info !== undefined) {
        promptAction.showToast({ message: `已切换到 ${info.deviceName}`, duration: 1800 });
        this.refresh();
      }
    }).catch(() => {
      promptAction.showToast({ message: '切换失败', duration: 1800 });
    });
  }

  private togglePrivacy(on: boolean): void {
    BindingStore.setPrivacyMode(getContext(this) as common.UIAbilityContext, on);
    this.privacyOn = on;
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
    promptAction.showToast({
      message: on ? '已开启防截屏：截屏/录屏/任务中心预览将被系统遮挡' : '已关闭防截屏',
      duration: 2200
    });
  }

  private removeDevice(sid: string): void {
    const target = this.devices.find((d: BindingInfo): boolean => d.deviceSid === sid);
    promptAction.showDialog({
      title: '移除电脑',
      message: `将清除「${target !== undefined ? target.deviceName : sid}」的绑定，需要重新扫码。`,
      buttons: [
        { text: '取消', color: '#9AA1B5' },
        { text: '移除', color: '#C0392B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      BindingStore.removeDevice(ctx, sid).then(() => {
        hilog.info(0x0000, TAG, 'settings: device removed sid=%{public}s', sid);
        this.refresh();
      }).catch(() => {
        // ignore
      });
    });
  }

  private unbindAll(): void {
    promptAction.showDialog({
      title: '解绑全部电脑',
      message: '将清除本机所有绑定记录（账号登录态保留），需要重新扫码。',
      buttons: [
        { text: '取消', color: '#9AA1B5' },
        { text: '解绑', color: '#C0392B' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      BindingStore.clear(ctx).then(() => {
        router.replaceUrl({ url: 'pages/BindPage' });
      }).catch(() => {
        // ignore
      });
    });
  }

  build() {
    Column() {
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
        Text('设置与设备管理')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: this.statusBarHeight + 8, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          // 电脑列表
          Column({ space: 6 }) {
            Text(`已绑定的电脑 · ${this.devices.length}`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, top: 2 })
            if (this.devices.length === 0) {
              Text('暂无绑定，请扫码添加')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ left: 4, top: 6, bottom: 6 })
            }
            ForEach(this.devices, (d: BindingInfo) => {
              Row({ space: 10 }) {
                Text(d.deviceName)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (d.deviceSid === this.currentSid) {
                  Text('✓ 当前')
                    .fontSize(11)
                    .fontColor($r('app.color.accent'))
                } else {
                  Text('点击切换')
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                }
                Text('移除')
                  .fontSize(12)
                  .fontColor($r('app.color.error_text'))
                  .padding({ left: 10, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.removeDevice(d.deviceSid);
                  })
              }
              .width('100%')
              .padding(12)
              .borderRadius(12)
              .backgroundColor($r('app.color.bg_card'))
              .onClick(() => {
                this.switchDevice(d.deviceSid);
              })
            }, (d: BindingInfo) => {
              return d.deviceSid;
            })
            Button('扫码添加新电脑')
              .width('100%')
              .height(42)
              .backgroundColor($r('app.color.btn_secondary_bg'))
              .fontColor($r('app.color.accent'))
              .fontSize(14)
              .onClick(() => {
                router.replaceUrl({ url: 'pages/BindPage', params: { 'forceBind': true } as Record<string, Object> });
              })
          }
          .alignItems(HorizontalAlign.Start)
          .padding(10)
          .borderRadius(12)
          .backgroundColor($r('app.color.bg_card'))
          .width('100%')

          // 偏好
          Column({ space: 8 }) {
            Text('偏好')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, top: 2 })
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('防截屏')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                Text('开启后本应用画面无法被截屏、录屏或任务中心预览')
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.privacyOn })
                .selectedColor($r('app.color.accent'))
                .onChange((on: boolean) => {
                  this.togglePrivacy(on);
                })
            }
            .width('100%')
            Text('外观跟随系统（网页内主题由官方网页自行控制）')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ left: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .padding(10)
          .borderRadius(12)
          .backgroundColor($r('app.color.bg_card'))
          .width('100%')

          Button('解绑全部电脑')
            .width('100%')
            .height(44)
            .backgroundColor($r('app.color.btn_danger_bg'))
            .fontColor($r('app.color.btn_danger_text'))
            .onClick(() => {
              this.unbindAll();
            })

          Text('说明\n· 绑定 = 扫码 + 登录同一 ZCode 账号双重校验\n· 登录态与绑定保存在本机，卸载应用后失效\n· 网页业务随官方自动更新，本应用只做宿主增强')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(18)
            .padding({ bottom: 20 })
        }
        .padding(14)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
