import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import http from '@ohos.net.http';
import { BindingStore } from '../store/BindingStore';
import { AppError, ERR_AUTH, ERR_NETWORK } from '../model/AppError';

const TAG: string = 'ZCRemote';

/**
 * V2 账号认证服务:
 *  - JWT：OAuth 登录（LoginWebViewPage）捕获后由 BindingStore 加密持久化
 *  - 终端短时 token：POST /api/v1/remote/token {role:"terminal"}（Bearer JWT）→ expires_in=60s，
 *    因此不缓存，每次中继连接前现取（RelayClientV2 的 TokenProvider）
 *  - 401/403 → 判定登录过期，抛 ERR_AUTH 由上层引导重新登录
 */
export class AuthService {
  private static jwt: string = '';
  private static loaded: boolean = false;

  /** 启动时加载持久化的 JWT（幂等） */
  static async load(ctx: common.UIAbilityContext): Promise<void> {
    if (AuthService.loaded) {
      return;
    }
    AuthService.jwt = await BindingStore.loadJwt(ctx);
    AuthService.loaded = true;
    hilog.info(0x0000, TAG, 'auth: jwt loaded present=%{public}s', String(AuthService.jwt.length > 0));
  }

  static jwtPresent(): boolean {
    return AuthService.jwt.length > 0;
  }

  static async saveJwt(ctx: common.UIAbilityContext, jwt: string): Promise<void> {
    AuthService.jwt = jwt;
    AuthService.loaded = true;
    await BindingStore.saveJwt(ctx, jwt);
    hilog.info(0x0000, TAG, 'auth: jwt saved len=%{public}s', String(jwt.length));
  }

  /**
   * 换发终端短时 token（每次连接前调用）
   * 失败分类：未登录/过期 → ERR_AUTH（message 含"登录"供上层区分引导）；
   * 网络/服务异常 → ERR_NETWORK（上层走退避重试）。
   */
  static async ensureTerminalToken(origin: string): Promise<string> {
    if (AuthService.jwt.length === 0) {
      throw new AppError(ERR_AUTH, '尚未登录 ZCode 账号', '请先完成账号登录');
    }
    const base = origin.replace(/\/$/, '');
    const client = http.createHttp();
    try {
      const resp = await client.request(`${base}/api/v1/remote/token`, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${AuthService.jwt}`,
          'Content-Type': 'application/json'
        } as Record<string, string>,
        extraData: JSON.stringify({ 'role': 'terminal' }),
        connectTimeout: 10000,
        readTimeout: 10000
      });
      const status = resp.responseCode;
      const body = typeof resp.result === 'string' ? resp.result : '';
      if (status === 401 || status === 403) {
        hilog.error(0x0000, TAG, 'auth: token endpoint %{public}d — login expired', status);
        throw new AppError(ERR_AUTH, '账号登录已过期', '请重新登录 ZCode 账号');
      }
      if (status < 200 || status >= 300) {
        throw new AppError(ERR_NETWORK, `令牌服务 HTTP ${status}`, '服务端临时异常，稍后自动重试');
      }
      let parsed: Record<string, Object> | undefined;
      try {
        parsed = JSON.parse(body) as Record<string, Object>;
      } catch (e) {
        throw new AppError(ERR_NETWORK, '令牌服务响应异常', '稍后自动重试');
      }
      const code = parsed !== undefined && typeof parsed['code'] === 'number'
        ? parsed['code'] as number : -1;
      const data = parsed !== undefined && parsed['data'] !== undefined
        && typeof parsed['data'] === 'object'
        ? parsed['data'] as Record<string, Object> : undefined;
      const token = data !== undefined && typeof data['token'] === 'string' ? data['token'] as string : '';
      if (code !== 0 || token.length === 0) {
        const msg = parsed !== undefined && typeof parsed['msg'] === 'string' ? parsed['msg'] as string : '';
        hilog.error(0x0000, TAG, 'auth: token code=%{public}d msg=%{public}s', code, msg);
        if (msg.indexOf('auth') >= 0 || msg.indexOf('登录') >= 0 || msg.indexOf('token') >= 0) {
          throw new AppError(ERR_AUTH, '账号登录已过期', '请重新登录 ZCode 账号');
        }
        throw new AppError(ERR_NETWORK, `令牌服务返回异常（${code}）`, '稍后自动重试');
      }
      hilog.info(0x0000, TAG, 'auth: terminal token ok len=%{public}s', String(token.length));
      return token;
    } catch (e) {
      if (e instanceof AppError) {
        throw e;
      }
      const msg = e instanceof Error ? (e as Error).message : '';
      throw new AppError(ERR_NETWORK, msg.length > 0 ? msg : '网络异常', '请检查手机网络后重试');
    } finally {
      client.destroy();
    }
  }
}
