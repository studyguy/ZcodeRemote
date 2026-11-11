import { BindingInfo } from '../model/Models';

/**
 * 解析 ZCode 桌面端二维码 / 粘贴的绑定链接:
 *  - V1 (≤3.14): https://…/remote/v4?sid=…&hash=…&t=…&mid=…&name=…&app_version=…
 *  - V2 (3.16+): https://…/remote/v4?sid=…&mid=…&name=…&app_version=…（无 hash/t，配对改 sid+桌面端确认）
 */
export class QrParseResult {
  ok: boolean = false;
  error: string = '';
  info: BindingInfo | undefined = undefined;
}

export class QrParser {
  static parse(text: string): QrParseResult {
    const result = new QrParseResult();
    const raw = text.trim();
    if (raw.length === 0) {
      result.error = '内容为空';
      return result;
    }
    const qIdx = raw.indexOf('?');
    if (qIdx < 0) {
      result.error = '未找到链接参数（请扫描桌面端弹出的二维码或粘贴完整链接）';
      return result;
    }
    const query = raw.substring(qIdx + 1);
    const params: Map<string, string> = new Map();
    const parts = query.split('&');
    for (const p of parts) {
      if (p.length === 0) {
        continue;
      }
      const eq = p.indexOf('=');
      if (eq < 0) {
        continue;
      }
      params.set(safeDecode(p.substring(0, eq)), safeDecode(p.substring(eq + 1)));
    }
    const sid = params.get('sid') !== undefined ? params.get('sid') as string : '';
    const hash = params.get('hash') !== undefined ? params.get('hash') as string : '';
    if (sid.length === 0) {
      result.error = '链接缺少 sid 配对标识';
      return result;
    }
    // V2（桌面 3.16+）二维码不含 hash；V1 的 hash 若存在做基本校验
    if (hash.length > 0 && hash.length < 20) {
      result.error = 'hash 字段异常';
      return result;
    }
    const info = new BindingInfo();
    info.deviceSid = sid;
    info.passHash = hash;
    const mid = params.get('mid');
    info.deviceMid = mid !== undefined ? mid : '';
    const name = params.get('name');
    info.deviceName = name !== undefined && name.length > 0 ? name : '我的电脑';
    const ver = params.get('app_version');
    info.appVersion = ver !== undefined && ver.length > 0 ? ver : '3.14.4';
    const schemeEnd = raw.indexOf('://');
    if (schemeEnd <= 0) {
      result.error = '链接缺少协议头';
      return result;
    }
    const scheme = raw.substring(0, schemeEnd).toLowerCase();
    if (scheme !== 'https') {
      result.error = '绑定链接必须为 https（当前: ' + scheme + '），为防凭证泄露已拒绝';
      return result;
    }
    // 绑定凭证/网页登录态只交给 ZCode 官方主站；不接受仿冒 host、端口或 userinfo。
    const authorityStart: number = schemeEnd + 3;
    const authorityEnd: number = raw.indexOf('/', authorityStart);
    if (authorityEnd <= authorityStart) {
      result.error = '绑定链接缺少官方远程控制路径';
      return result;
    }
    const authority: string = raw.substring(authorityStart, authorityEnd).toLowerCase();
    if (authority !== 'zcode.z.ai') {
      result.error = '仅支持 ZCode 官方域名 zcode.z.ai，为保护账号安全已拒绝';
      return result;
    }
    const pathEndQ: number = raw.indexOf('?', authorityEnd);
    const pathEndHash: number = raw.indexOf('#', authorityEnd);
    let pathEnd: number = raw.length;
    if (pathEndQ >= 0 && pathEndQ < pathEnd) {
      pathEnd = pathEndQ;
    }
    if (pathEndHash >= 0 && pathEndHash < pathEnd) {
      pathEnd = pathEndHash;
    }
    const path: string = raw.substring(authorityEnd, pathEnd).replace(/\/$/, '');
    if (path !== '/remote/v4') {
      result.error = '仅支持 ZCode 官方远程控制二维码';
      return result;
    }
    info.endpointOrigin = 'https://zcode.z.ai';
    result.ok = true;
    result.info = info;
    return result;
  }
}

/** 安全 decode：畸形百分号编码返回原值而非抛异常 */
function safeDecode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch (e) {
    return text;
  }
}
