import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ZCRemote';

/**
 * 登录态镜像（V2 网页登录持久化）：
 * ArkWeb 的 localStorage 不保证跨进程持久（实测），壳侧在 filesDir/auth_mirror.json
 * 保存网页登录态（zcodejwttoken + oauth provider），注入脚本在 documentStart 写回。
 * 自 WebPage.ets 原样抽出（2026-11-11 壳优先重构），逻辑不变。
 */
export class AuthMirrorData {
  t: string = '';
  p: string = '';
}

export class AuthMirror {
  private static mirrorPath(ctx: common.UIAbilityContext): string {
    return ctx.filesDir + '/auth_mirror.json';
  }

  /** 同步读（必须早于 Web 首次渲染，供 documentStart 恢复） */
  static load(ctx: common.UIAbilityContext): AuthMirrorData {
    const out = new AuthMirrorData();
    try {
      const p = AuthMirror.mirrorPath(ctx);
      if (!fs.accessSync(p)) {
        return out;
      }
      const obj = JSON.parse(fs.readTextSync(p)) as Record<string, string>;
      out.t = obj['t'] !== undefined ? obj['t'] as string : '';
      out.p = obj['p'] !== undefined ? obj['p'] as string : '';
      hilog.info(0x0000, TAG, 'auth mirror loaded tLen=%{public}s p=%{public}s',
        String(out.t.length), out.p);
    } catch (e) {
      // ignore
    }
    return out;
  }

  /** 网页上报登录态变化时写镜像（登出清空） */
  static save(ctx: common.UIAbilityContext, token: string, provider: string): void {
    try {
      const f = fs.openSync(AuthMirror.mirrorPath(ctx),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify({ t: token, p: provider }));
      fs.closeSync(f);
      hilog.info(0x0000, TAG, 'auth mirror saved tLen=%{public}s p=%{public}s',
        String(token.length), provider);
    } catch (e) {
      hilog.error(0x0000, TAG, 'auth mirror write failed');
    }
  }
}
