import { asset } from '@kit.AssetStoreKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';
import { BindingInfo } from '../model/Models';

const TAG: string = 'ZCRemote';

/**
 * 绑定凭证存储 v3（V2 账号协议）:
 *  - 每台电脑一条记录：元数据（sid/name/mid/版本/端点）存 Preferences 的 device_list
 *    （\u001E 分隔记录、\u001F 分隔字段，均为控制字符，字段值写入前过滤）
 *  - V2 配对无 URL 级机密（配对 = sid + 同账号 JWT 双重校验），账号 JWT 存
 *    AssetStoreKit 加密资产（alias zcode_jwt），失败回退 Preferences（jwt_fb），
 *    并随 device_list 一起进 filesDir 文件镜像
 *  - phone_mid：本机中继连接标识（一次生成持久复用）
 *  - active_sid 指向当前使用设备；旧版单设备数据首次读取时自动迁移
 */
export class BindingStore {
  private static readonly PREF_NAME: string = 'zcode_binding';
  private static readonly KEY_DEVICE_LIST: string = 'device_list';
  private static readonly KEY_ACTIVE_SID: string = 'active_sid';
  private static readonly KEY_PRIVACY: string = 'privacy_mode';
  private static readonly KEY_COLOR_MODE: string = 'color_mode_pref';
  private static readonly KEY_PHONE_MID: string = 'phone_mid';
  private static readonly KEY_JWT: string = 'jwt';
  private static readonly KEY_JWT_FB: string = 'jwt_fb';
  // 旧版单设备字段（仅迁移读取）
  private static readonly KEY_SID: string = 'device_sid';
  private static readonly KEY_MID: string = 'device_mid';
  private static readonly KEY_NAME: string = 'device_name';
  private static readonly KEY_VER: string = 'app_version';
  private static readonly KEY_ORIGIN: string = 'endpoint_origin';
  private static readonly KEY_BOUND_URL: string = 'bound_url';
  private static readonly JWT_ASSET_ALIAS: string = 'zcode_jwt';
  private static readonly REC_SEP: string = '\u001E';
  private static readonly FLD_SEP: string = '\u001F';

  private static enc(s: string): Uint8Array {
    return new util.TextEncoder().encodeInto(s);
  }

  private static dec(b: Uint8Array): string {
    return new util.TextDecoder('utf-8').decodeToString(b);
  }

  private static fbKey(sid: string): string {
    return 'url_fb_' + sid;
  }

  /** 文件镜像：preferences 落盘不可靠时的最后兜底（filesDir 直写） */
  private static mirrorPath(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/binding_mirror.json';
  }

  private static writeMirror(ctx: common.UIAbilityContext, list: string, active: string, jwt: string): void {
    try {
      const f = fs.openSync(BindingStore.mirrorPath(ctx),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify({ list: list, active: active, jwt: jwt }));
      fs.closeSync(f);
      hilog.info(0x0000, TAG, 'mirror saved len=%{public}s', String(list.length));
    } catch (e) {
      hilog.error(0x0000, TAG, 'mirror write failed: %{public}s', e instanceof Error ? (e as Error).message : '?');
    }
  }

  /** 返回 [list, active, jwt]，无镜像时为 ['','',''] */
  private static readMirror(ctx: common.UIAbilityContext): Array<string> {
    try {
      const p = BindingStore.mirrorPath(ctx);
      if (!fs.accessSync(p)) {
        return ['', '', ''];
      }
      const obj = JSON.parse(fs.readTextSync(p)) as Record<string, string>;
      const list = obj['list'] !== undefined ? obj['list'] as string : '';
      const active = obj['active'] !== undefined ? obj['active'] as string : '';
      const jwt = obj['jwt'] !== undefined ? obj['jwt'] as string : '';
      return [list, active, jwt];
    } catch (e) {
      return ['', '', ''];
    }
  }

  private static deleteMirror(ctx: common.UIAbilityContext): void {
    try {
      fs.unlinkSync(BindingStore.mirrorPath(ctx));
    } catch (e) {
      // ignore
    }
  }

  private static sanitize(v: string): string {
    return v.split(BindingStore.REC_SEP).join(' ').split(BindingStore.FLD_SEP).join(' ');
  }

  /** 全部绑定（元数据；V2 无 URL 级机密，绑定只要 sid 在即可用） */
  static async loadAll(ctx: common.UIAbilityContext): Promise<Array<BindingInfo>> {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    let list = prefs.getSync(BindingStore.KEY_DEVICE_LIST, '') as string;
    let active = prefs.getSync(BindingStore.KEY_ACTIVE_SID, '') as string;
    hilog.info(0x0000, TAG, 'loadAll: device_list len=%{public}s', String(list.length));
    if (list.length === 0) {
      list = BindingStore.migrateLegacy(prefs);
    }
    if (list.length === 0) {
      // 最后兜底：filesDir 文件镜像
      const m = BindingStore.readMirror(ctx);
      if (m[0].length > 0) {
        hilog.warn(0x0000, TAG, 'loadAll: restored from file mirror len=%{public}s', String(m[0].length));
        list = m[0];
        active = m[1];
        // 自愈：写回 preferences
        prefs.putSync(BindingStore.KEY_DEVICE_LIST, list);
        prefs.putSync(BindingStore.KEY_ACTIVE_SID, active);
        prefs.flush();
      }
    }
    const out: Array<BindingInfo> = [];
    if (list.length === 0) {
      hilog.info(0x0000, TAG, 'loadAll: empty (no list, no legacy, no mirror)');
      return out;
    }
    for (const rec of list.split(BindingStore.REC_SEP)) {
      if (rec.length === 0) {
        continue;
      }
      const f = rec.split(BindingStore.FLD_SEP);
      if (f.length < 5) {
        continue;
      }
      const info = new BindingInfo();
      info.deviceSid = f[0];
      info.deviceName = f[1];
      info.deviceMid = f[2];
      info.appVersion = f[3];
      info.endpointOrigin = f[4];
      out.push(info);
    }
    return out;
  }

  /** 旧版单设备数据 → device_list 一条记录；返回迁移后的列表串（无旧数据返回空） */
  private static migrateLegacy(prefs: preferences.Preferences): string {
    const sid = prefs.getSync(BindingStore.KEY_SID, '') as string;
    if (sid.length === 0) {
      return '';
    }
    const sidTail = sid.substring(Math.max(0, sid.length - 6));
    hilog.info(0x0000, TAG, 'migrating legacy binding sidTail=%{public}s', sidTail);
    const mid = prefs.getSync(BindingStore.KEY_MID, '') as string;
    const name = BindingStore.sanitize(prefs.getSync(BindingStore.KEY_NAME, '我的电脑') as string);
    const ver = prefs.getSync(BindingStore.KEY_VER, '3.14.4') as string;
    const origin = prefs.getSync(BindingStore.KEY_ORIGIN, 'https://zcode.z.ai') as string;
    const rec: string = [sid, name, mid, ver, origin].join(BindingStore.FLD_SEP);
    prefs.putSync(BindingStore.KEY_DEVICE_LIST, rec);
    prefs.putSync(BindingStore.KEY_ACTIVE_SID, sid);
    prefs.flush();
    hilog.info(0x0000, TAG, 'legacy migration done');
    return rec;
  }

  /** 当前激活设备的绑定（无则取列表第一个） */
  static async load(ctx: common.UIAbilityContext): Promise<BindingInfo | undefined> {
    const all = await BindingStore.loadAll(ctx);
    if (all.length === 0) {
      return undefined;
    }
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    const active = prefs.getSync(BindingStore.KEY_ACTIVE_SID, '') as string;
    for (const b of all) {
      if (b.deviceSid === active) {
        return b;
      }
    }
    return all[0];
  }

  /** 保存/更新一台设备并设为激活（同 sid 覆盖，不同 sid 追加） */
  static async save(ctx: common.UIAbilityContext, info: BindingInfo): Promise<void> {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    const rec: string = [
      info.deviceSid,
      BindingStore.sanitize(info.deviceName.length > 0 ? info.deviceName : '我的电脑'),
      BindingStore.sanitize(info.deviceMid),
      BindingStore.sanitize(info.appVersion),
      BindingStore.sanitize(info.endpointOrigin)
    ].join(BindingStore.FLD_SEP);
    const list = prefs.getSync(BindingStore.KEY_DEVICE_LIST, '') as string;
    const kept: Array<string> = [];
    for (const r of list.split(BindingStore.REC_SEP)) {
      if (r.length > 0 && r.split(BindingStore.FLD_SEP)[0] !== info.deviceSid) {
        kept.push(r);
      }
    }
    kept.push(rec);
    prefs.putSync(BindingStore.KEY_DEVICE_LIST, kept.join(BindingStore.REC_SEP));
    prefs.putSync(BindingStore.KEY_ACTIVE_SID, info.deviceSid);
    try {
      await prefs.flush();
      hilog.info(0x0000, TAG, 'save: prefs flush ok');
    } catch (e) {
      hilog.error(0x0000, TAG, 'save: prefs flush FAILED');
    }
    BindingStore.writeMirror(ctx, kept.join(BindingStore.REC_SEP), info.deviceSid,
      prefs.getSync(BindingStore.KEY_JWT, '') as string);
  }

  /** 切换激活设备，返回该设备绑定 */
  static async setActive(ctx: common.UIAbilityContext, sid: string): Promise<BindingInfo | undefined> {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    prefs.putSync(BindingStore.KEY_ACTIVE_SID, sid);
    await prefs.flush();
    const list = prefs.getSync(BindingStore.KEY_DEVICE_LIST, '') as string;
    if (list.length > 0) {
      BindingStore.writeMirror(ctx, list, sid, prefs.getSync(BindingStore.KEY_JWT, '') as string);
    }
    return BindingStore.load(ctx);
  }

  /** 移除一台设备（若为激活设备则顺延到剩余第一台） */
  static async removeDevice(ctx: common.UIAbilityContext, sid: string): Promise<void> {
    hilog.warn(0x0000, TAG, 'removeDevice requested');
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    const list = prefs.getSync(BindingStore.KEY_DEVICE_LIST, '') as string;
    const kept: Array<string> = [];
    for (const r of list.split(BindingStore.REC_SEP)) {
      if (r.length > 0 && r.split(BindingStore.FLD_SEP)[0] !== sid) {
        kept.push(r);
      }
    }
    const active = prefs.getSync(BindingStore.KEY_ACTIVE_SID, '') as string;
    const newList = kept.join(BindingStore.REC_SEP);
    const newActive = active === sid ? (kept.length > 0 ? kept[0].split(BindingStore.FLD_SEP)[0] : '') : active;
    prefs.putSync(BindingStore.KEY_DEVICE_LIST, newList);
    prefs.putSync(BindingStore.KEY_ACTIVE_SID, newActive);
    prefs.delete(BindingStore.fbKey(sid));
    await prefs.flush();
    if (newList.length > 0) {
      BindingStore.writeMirror(ctx, newList, newActive, prefs.getSync(BindingStore.KEY_JWT, '') as string);
    } else {
      BindingStore.deleteMirror(ctx);
    }
  }

  /** 解绑全部设备。注意：不清账号 JWT（重绑同一账号无需重新登录） */
  static async clear(ctx: common.UIAbilityContext): Promise<void> {
    hilog.warn(0x0000, TAG, 'binding store CLEAR (all devices)');
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    // 先读后清：解绑只针对设备绑定，账号/偏好/本机标识保留
    const jwt = prefs.getSync(BindingStore.KEY_JWT, '') as string;
    const colorMode = prefs.getSync(BindingStore.KEY_COLOR_MODE, 'system') as string;
    const phoneMid = prefs.getSync(BindingStore.KEY_PHONE_MID, '') as string;
    await prefs.clear();
    if (jwt.length > 0) {
      prefs.putSync(BindingStore.KEY_JWT, jwt);
    }
    if (colorMode.length > 0) {
      prefs.putSync(BindingStore.KEY_COLOR_MODE, colorMode);
    }
    if (phoneMid.length > 0) {
      prefs.putSync(BindingStore.KEY_PHONE_MID, phoneMid);
    }
    await prefs.flush();
    if (jwt.length > 0) {
      BindingStore.writeMirror(ctx, '', '', jwt);
    } else {
      BindingStore.deleteMirror(ctx);
    }
  }

  /** ===== 账号 JWT（资产优先 → prefs 回退 → 文件镜像自愈） ===== */

  static async loadJwt(ctx: common.UIAbilityContext): Promise<string> {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    let jwt = prefs.getSync(BindingStore.KEY_JWT, '') as string;
    if (jwt.length === 0) {
      jwt = await BindingStore.readJwtAsset();
    }
    if (jwt.length === 0) {
      jwt = prefs.getSync(BindingStore.KEY_JWT_FB, '') as string;
    }
    if (jwt.length === 0) {
      const m = BindingStore.readMirror(ctx);
      if (m[2].length > 0) {
        hilog.warn(0x0000, TAG, 'loadJwt: restored from file mirror');
        jwt = m[2];
      }
    }
    if (jwt.length > 0) {
      // 自愈写回
      prefs.putSync(BindingStore.KEY_JWT, jwt);
      prefs.flush();
    }
    return jwt;
  }

  static async saveJwt(ctx: common.UIAbilityContext, jwt: string): Promise<void> {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    prefs.putSync(BindingStore.KEY_JWT, jwt);
    prefs.delete(BindingStore.KEY_JWT_FB);
    try {
      await prefs.flush();
    } catch (e) {
      // ignore（镜像兜底）
    }
    // 加密资产
    try {
      const rm: asset.AssetMap = new Map();
      rm.set(asset.Tag.ALIAS, BindingStore.enc(BindingStore.JWT_ASSET_ALIAS));
      await asset.remove(rm);
    } catch (e) {
      // ignore
    }
    let assetOk = false;
    try {
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.SECRET, BindingStore.enc(jwt));
      attrs.set(asset.Tag.ALIAS, BindingStore.enc(BindingStore.JWT_ASSET_ALIAS));
      await asset.add(attrs);
      assetOk = true;
    } catch (e) {
      hilog.error(0x0000, TAG, 'jwt asset add failed, fallback to prefs');
    }
    if (!assetOk) {
      prefs.putSync(BindingStore.KEY_JWT_FB, jwt);
      await prefs.flush();
    }
    // 镜像（list/active 保持现状）
    const list = prefs.getSync(BindingStore.KEY_DEVICE_LIST, '') as string;
    const active = prefs.getSync(BindingStore.KEY_ACTIVE_SID, '') as string;
    BindingStore.writeMirror(ctx, list, active, jwt);
  }

  private static async readJwtAsset(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, BindingStore.enc(BindingStore.JWT_ASSET_ALIAS));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length > 0) {
        const secret = results[0].get(asset.Tag.SECRET);
        if (secret !== undefined && secret instanceof Uint8Array) {
          return BindingStore.dec(secret as Uint8Array);
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'jwt asset query failed');
    }
    return '';
  }

  /** ===== 本机中继连接标识（phone_mid，一次生成持久复用） ===== */

  static getOrCreatePhoneMid(ctx: common.UIAbilityContext): string {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    let mid = prefs.getSync(BindingStore.KEY_PHONE_MID, '') as string;
    if (mid.length > 0) {
      return mid;
    }
    let rnd = '';
    for (let i = 0; i < 4; i++) {
      rnd += Math.floor(Math.random() * 0xffff).toString(16).padStart(4, '0');
    }
    mid = 'zr-' + rnd;
    prefs.putSync(BindingStore.KEY_PHONE_MID, mid);
    prefs.flush();
    hilog.info(0x0000, TAG, 'phone_mid generated');
    return mid;
  }

  /** 外观偏好: 'system' | 'light' | 'dark' */
  static getColorModePref(ctx: common.UIAbilityContext): string {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    const v = prefs.getSync(BindingStore.KEY_COLOR_MODE, 'system') as string;
    return v.length > 0 ? v : 'system';
  }

  static setColorModePref(ctx: common.UIAbilityContext, pref: string): void {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    prefs.putSync(BindingStore.KEY_COLOR_MODE, pref);
    prefs.flush();
  }

  /** 防截屏（隐私窗口）开关 */
  static getPrivacyMode(ctx: common.UIAbilityContext): boolean {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    return (prefs.getSync(BindingStore.KEY_PRIVACY, '0') as string) === '1';
  }

  static setPrivacyMode(ctx: common.UIAbilityContext, on: boolean): void {
    const prefs = preferences.getPreferencesSync(ctx, { name: BindingStore.PREF_NAME });
    prefs.putSync(BindingStore.KEY_PRIVACY, on ? '1' : '0');
    prefs.flush();
  }
}
