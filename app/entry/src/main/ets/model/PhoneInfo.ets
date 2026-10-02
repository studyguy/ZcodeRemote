import deviceInfo from '@ohos.deviceInfo';
import { display } from '@kit.ArkUI';
import i18n from '@ohos.i18n';

/**
 * 本机（手机）设备信息：用于向桌面端上报连接设备身份，
 * 让桌面"已连接设备"显示真实手机名称而非回退指纹。
 */
export class PhoneInfo {
  private static phoneNameCache: string = '';
  private static ua: string = '';

  /** 手机显示名：优先 marketing 名（如 HUAWEI Pura X），回退 品牌+型号 */
  static phoneName(): string {
    if (PhoneInfo.phoneNameCache.length > 0) {
      return PhoneInfo.phoneNameCache;
    }
    try {
      // 机芯：优先市场别名（如 Pura X），回退产品型号（如 VDE-AL00）
      const alias = deviceInfo.productModelAlias;
      const model = deviceInfo.productModel;
      if (alias.length > 0 && alias !== model) {
        PhoneInfo.phoneNameCache = alias;
        return PhoneInfo.phoneNameCache;
      }
      if (model.length > 0) {
        PhoneInfo.phoneNameCache = model;
        return PhoneInfo.phoneNameCache;
      }
    } catch (e) {
      // ignore
    }
    try {
      if (deviceInfo.marketName.length > 0) {
        PhoneInfo.phoneNameCache = deviceInfo.marketName;
        return PhoneInfo.phoneNameCache;
      }
    } catch (e) {
      // ignore
    }
    PhoneInfo.phoneNameCache = 'HarmonyOS 设备';
    return PhoneInfo.phoneNameCache;
  }

  /** 构造与网页端 deviceInfo 同构的 userAgent（桌面据此显示连接设备） */
  static userAgent(appVersion: string): string {
    if (PhoneInfo.ua.length > 0) {
      return PhoneInfo.ua;
    }
    let model = '';
    try {
      model = deviceInfo.productModel;
    } catch (e) {
      // ignore
    }
    PhoneInfo.ua = `ZcodeRemote/${appVersion} (HarmonyOS; ${model.length > 0 ? model : 'unknown'})`;
    return PhoneInfo.ua;
  }

  /** 视口/屏幕信息（网页 deviceInfo 的 viewport/screen 字段） */
  static viewport(): Record<string, Object> {
    try {
      const d = display.getDefaultDisplaySync();
      return {
        'width': d.width,
        'height': d.height
      } as Record<string, Object>;
    } catch (e) {
      return { 'width': 0, 'height': 0 } as Record<string, Object>;
    }
  }

  static language(): string {
    try {
      return i18n.System.getSystemLanguage();
    } catch (e) {
      return 'zh-CN';
    }
  }
}
