import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BindingStore } from '../store/BindingStore';

const TAG: string = 'ZCRemote';

/**
 * 启动分流页（壳优先重构 2026-11-11）：
 * 无业务 UI（背景色闪屏）。读绑定 → 有绑定进 WebStage（深度链接由 WebStage 自己消费）；
 * 无绑定进 BindPage。200ms 内完成分流。
 */
@Entry
@Component
struct Index {
  build() {
    Column() {
      Column({ space: 10 }) {
        Image($r('app.media.app_icon'))
          .width(64)
          .height(64)
          .borderRadius(16)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea()
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    BindingStore.load(ctx).then((info) => {
      if (info !== undefined) {
        hilog.info(0x0000, TAG, 'launch: bound sid=%{public}s → WebStage',
          info.deviceSid.substring(Math.max(0, info.deviceSid.length - 6)));
        router.replaceUrl({ url: 'pages/WebStage' });
      } else {
        hilog.info(0x0000, TAG, 'launch: unbound → BindPage');
        router.replaceUrl({ url: 'pages/BindPage' });
      }
    }).catch((e: Error) => {
      hilog.error(0x0000, TAG, 'launch: binding load failed: %{public}s → BindPage', e.message);
      router.replaceUrl({ url: 'pages/BindPage' });
    });
  }
}
