import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import notification from '@ohos.notification';
import { vibrator } from '@kit.SensorServiceKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ZCRemote';

/**
 * 本地通知 + 震动（自 WebPage.ets 抽出，2026-11-11 壳优先重构）。
 * 关键经验（十八期实测）：NotificationRequest 不设 slotType 时归 OTHER 槽位——
 * 静默躺在通知中心（isHeadsUp:false）。必须用 SOCIAL_COMMUNICATION 槽位才有横幅/铃声/震动。
 */
export class NotifyService {
  private static seq: number = 0;
  private static permissionAsked: boolean = false;

  /** 进主容器即申请（授权弹窗只出现一次，之后静默） */
  static ensurePermission(ctx: common.UIAbilityContext): void {
    if (NotifyService.permissionAsked) {
      return;
    }
    NotifyService.permissionAsked = true;
    try {
      notificationManager.isNotificationEnabled().then((on: boolean) => {
        hilog.info(0x0000, TAG, 'notification enabled=%{public}s', String(on));
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'isNotificationEnabled failed: %{public}s', e.message);
      });
      notificationManager.requestEnableNotification(ctx).then(() => {
        hilog.info(0x0000, TAG, 'notification permission granted');
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'notification permission denied: %{public}s', e.message);
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'requestEnableNotification exception');
    }
  }

  static vibrate(ms: number = 450): void {
    try {
      const eff: vibrator.VibrateTime = { type: 'time', duration: ms };
      vibrator.startVibration(eff, { usage: 'touch' }).catch(() => {
        // ignore
      });
    } catch (e) {
      // ignore
    }
  }

  static notify(head: string, text: string, idBase: number): void {
    try {
      const req: notificationManager.NotificationRequest = {
        id: idBase + (NotifyService.seq++ % 40),
        slotType: notification.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: head,
            text: text
          }
        }
      };
      notificationManager.publish(req).then(() => {
        hilog.info(0x0000, TAG, 'notification published: %{public}s', head);
      }).catch((e: Error) => {
        hilog.error(0x0000, TAG, 'notification publish failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.error(0x0000, TAG, 'notification publish exception');
    }
  }
}
