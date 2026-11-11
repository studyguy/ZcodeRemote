/**
 * 数据模型（防御式解析中继 JSON 的产物）
 */

/** Index ↔ WebPage 路由参数：url=要加载的绑定链接；forceBind=true 强制落在扫码页（添加/重绑设备） */
export class WebRouteParams {
  url: string = '';
  forceBind: boolean = false;

  constructor(u: string, force: boolean = false) {
    this.url = u;
    this.forceBind = force;
  }
}

export class BindingInfo {
  deviceSid: string = '';
  /** V1 遗留字段（V2 无 URL 级机密，恒为空；保留兼容旧存储/死代码引用） */
  passHash: string = '';
  deviceMid: string = '';
  deviceName: string = '';
  appVersion: string = '';
  /** https://zcode.z.ai */
  endpointOrigin: string = 'https://zcode.z.ai';
  /** 本机中继连接标识（phone_mid，一次生成持久复用；ZcodeService 加载时填充） */
  phoneMid: string = '';

  /** V2 中继 WebSocket 地址（token 以 URL 参数携带，见 RelayClientV2） */
  get relayWsUrl(): string {
    const origin = this.endpointOrigin.replace(/\/$/, '');
    if (origin.startsWith('https://')) {
      return 'wss://' + origin.substring(8) + '/api/v1/remote/ws2';
    }
    if (origin.startsWith('http://')) {
      return 'ws://' + origin.substring(7) + '/api/v1/remote/ws2';
    }
    return 'wss://zcode.z.ai/api/v1/remote/ws2';
  }

  /**
   * 绑定页面 URL（壳方案 WebStage 加载入口）。
   * V2 配对无 URL 级机密（配对 = sid + 同账号双重校验），直接由元数据构造。
   */
  get boundUrl(): string {
    const origin = this.endpointOrigin.replace(/\/$/, '');
    let url = origin + '/remote/v4?sid=' + encodeURIComponent(this.deviceSid);
    if (this.deviceMid.length > 0) {
      url += '&mid=' + encodeURIComponent(this.deviceMid);
    }
    if (this.deviceName.length > 0) {
      url += '&name=' + encodeURIComponent(this.deviceName);
    }
    if (this.appVersion.length > 0) {
      url += '&app_version=' + encodeURIComponent(this.appVersion);
    }
    return url;
  }
}

export class WorkspaceItem {
  workspaceKey: string = '';
  workspacePath: string = '';
  label: string = '';
  kind: string = '';
  connectionState: string = '';
}

export class TaskItem {
  taskId: string = '';
  title: string = '';
  displayStatus: string = '';
  updatedAt: number = 0;
  createdAt: number = 0;
  hasBackgroundWork: boolean = false;
  pinned: boolean = false;
  archived: boolean = false;
  workspaceKey: string = '';
  workspacePath: string = '';
}

export class ChatMessage {
  id: string = '';
  role: string = '';
  /** 渲染顺序权威: thought | content | tool-call（来自快照 parts，按原顺序） */
  parts: ContentPart[] = new Array<ContentPart>();
  tools: Array<ToolCall> = new Array<ToolCall>();
  timestamp: number = 0;
  durationMs: number = 0;
  /** content 非字符串（内容块数组等）时保留原始 JSON 供调试展示 */
  rawJson: string = '';
}

export class ContentPart {
  type: string = 'content';
  text: string = '';
  toolIndex: number = -1;
}

export class ToolCall {
  toolName: string = '';
  title: string = '';
  kind: string = '';
  status: string = '';
  /** 截断后的 input JSON 文本 */
  inputJson: string = '';
  /** 截断后的 output 文本 */
  outputText: string = '';
  /** input 里的关键字段摘要（一行） */
  inputSummary: string = '';
}

export const THOUGHT_MAX: number = 8000;
export const TOOL_OUTPUT_MAX: number = 4000;
export const TOOL_INPUT_MAX: number = 2000;

export class SnapshotResult {
  etag: string = '';
  messages: Array<ChatMessage> = new Array<ChatMessage>();
  runtime: SnapshotRuntime = new SnapshotRuntime();
  meta: SessionMetaInfo = new SessionMetaInfo();
  config: ModelConfig = new ModelConfig();
}

/** displayStatus → 状态语义归类（未知值归 other） */
export function statusKind(displayStatus: string): string {
  const s = displayStatus.toLowerCase();
  if (s.includes('run') || s.includes('active') || s.includes('progress') || s.includes('busy')) {
    return 'running';
  }
  if (s.includes('wait') || s.includes('pend') || s.includes('confirm') || s.includes('input') || s.includes('ask')) {
    return 'attention';
  }
  if (s.includes('fail') || s.includes('error') || s.includes('abort') || s.includes('cancel') || s.includes('stop')) {
    return 'failed';
  }
  if (s.includes('done') || s.includes('complete') || s.includes('finish')) {
    return 'done';
  }
  return 'other';
}

/** 任务分组（主页按项目展示） */
export class TaskGroup {
  key: string = '';
  label: string = '';
  kind: string = '';
  tasks: Array<TaskItem> = new Array<TaskItem>();
}

export function formatTime(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d = new Date(ms);
  const mm = d.getMonth() + 1;
  const dd = d.getDate();
  const hh = d.getHours();
  const mi = d.getMinutes();
  const p = (n: number): string => {
    return n < 10 ? `0${n}` : `${n}`;
  };
  return `${p(mm)}-${p(dd)} ${p(hh)}:${p(mi)}`;
}

/** 截断文本（附省略标记） */
export function truncateText(s: string, max: number): string {
  if (s.length <= max) {
    return s;
  }
  return s.substring(0, max) + `\n…（已截断，共 ${s.length} 字符）`;
}

/** 快照 runtime.pendingPermissions 项（工具权限审批） */
export class PermissionRequest {
  requestId: string = '';
  kind: string = '';
  title: string = '';
  description: string = '';
  options: Array<PermissionOption> = new Array<PermissionOption>();
}

export class PermissionOption {
  optionId: string = '';
  label: string = '';
}

/** 快照 runtime.pendingElicitations 项（用户输入问答/计划审批） */
export class ElicitationRequest {
  requestId: string = '';
  message: string = '';
  header: string = '';
  options: Array<PermissionOption> = new Array<PermissionOption>();
  multiSelect: boolean = false;
  /** schema.interaction === 'free_text' 时可用自由文本回答 */
  freeText: boolean = false;
}

/** 会话运行时状态（快照 runtime） */
export class SnapshotRuntime {
  activeTurnKind: string = '';
  /** 工具权限审批 */
  pendingPermissions: Array<PermissionRequest> = new Array<PermissionRequest>();
  /** 用户输入问答 */
  pendingElicitations: Array<ElicitationRequest> = new Array<ElicitationRequest>();
  /** 排队中的消息 */
  pendingCommands: Array<QueueItem> = new Array<QueueItem>();
  /** 上下文占用（tokens） */
  contextUsed: number = 0;
  contextSize: number = 0;
}

/** 会话当前模型/思考/模式（快照 meta） */
export class SessionMetaInfo {
  model: string = '';
  thoughtLevel: string = '';
  mode: string = '';
}

/** 可选模型项（快照 configOptions type=model） */
export class ModelOption {
  value: string = '';
  name: string = '';
  modelProviderName: string = '';
  thoughtLevels: Array<string> = new Array<string>();
  defaultThoughtLevel: string = '';
}

/** 已启用渠道下的模型项（来自 model-selection 注册表视图） */
export class ModelEntry {
  modelId: string = '';
  contextWindow: number = 0;
  thoughtLevels: Array<string> = new Array<string>();
}

/** 已启用的模型渠道（注册表视图，仅含开启的渠道与模型） */
export class ModelProviderGroup {
  providerId: string = '';
  providerName: string = '';
  models: Array<ModelEntry> = new Array<ModelEntry>();
}

/** 模型选择注册表视图 */
export class ModelSelectionView {
  providers: Array<ModelProviderGroup> = new Array<ModelProviderGroup>();
}

/** 模型选择配置 */
export class ModelConfig {
  currentValue: string = '';
  options: Array<ModelOption> = new Array<ModelOption>();

  currentModelId(): string {
    const idx = this.currentValue.indexOf('$');
    return idx > 0 ? this.currentValue.substring(0, idx) : this.currentValue;
  }

  currentThought(): string {
    const idx = this.currentValue.indexOf('$');
    return idx > 0 ? this.currentValue.substring(idx + 1) : '';
  }

  currentOption(): ModelOption | undefined {
    const mid = this.currentModelId();
    for (const o of this.options) {
      if (o.value === mid) {
        return o;
      }
    }
    return undefined;
  }
}

/** 排队中的消息（快照 runtime.pendingCommands 项） */
export class QueueItem {
  queueItemId: string = '';
  sourceCommandId: string = '';
  text: string = '';
  kind: string = '';
}

/** 渠道额度项（usage-stats.getEntitlementSnapshot 的 quota.limits 项） */
export class EntitlementLimit {
  type: string = '';
  unit: number = 0;
  number: number = 0;
  currentValue: number = 0;
  limit: number = 0;
  remaining: number = 0;
  percentage: number = -1;
  nextResetTime: number = 0;
}

/** 渠道额度快照 */
export class EntitlementSnapshot {
  limits: Array<EntitlementLimit> = new Array<EntitlementLimit>();
  /** 5 小时额度（unit=3, number=5；TOKENS/CREDIT 等价） */
  fiveHour: EntitlementLimit | undefined = undefined;
  /** 每周额度（unit=6；TOKENS/CREDIT 等价） */
  weekly: EntitlementLimit | undefined = undefined;
  available: boolean = false;
  unavailableReason: string = '';
}

/** 生成客户端唯一 id（commandId/inputId 用） */
export function genClientId(): string {
  const rnd = (): string => {
    return Math.floor(Math.random() * 0xffff).toString(16).padStart(4, '0');
  };
  return `app-${Date.now().toString(36)}${rnd()}${rnd()}${rnd()}`;
}

/** 额度类型等价判定（CREDIT 与 TOKENS 互为等价类） */
export function limitTypeMatch(a: string, b: string): boolean {
  if (a === b) {
    return true;
  }
  const credit: Array<string> = ['CREDIT_LIMIT', 'TOKENS_LIMIT'];
  return credit.includes(a) && credit.includes(b);
}

/** 按桌面规则选额度项（type 等价 + unit 匹配 + number 可选匹配） */
export function pickLimit(limits: Array<EntitlementLimit>, type: string, unit: number,
  number: number): EntitlementLimit | undefined {
  for (const l of limits) {
    if (!limitTypeMatch(l.type, type) || l.unit !== unit) {
      continue;
    }
    if (number > 0 && l.number !== number) {
      continue;
    }
    return l;
  }
  return undefined;
}

/** 额度周期名（unit: 3=小时族, 6=周, 5=月；number 为窗口小时/个数） */
export function limitPeriodLabel(l: EntitlementLimit): string {
  if (l.unit === 6) {
    return '每周额度';
  }
  if (l.unit === 5) {
    return '每月额度';
  }
  if (l.unit === 3) {
    return l.number > 0 ? `${l.number} 小时额度` : '小时额度';
  }
  return l.type === 'TIME_LIMIT' ? '时间额度' : 'Token 额度';
}

/** token 数紧凑格式化（与桌面端一致: 12k / 1.2M） */
export function formatTokens(n: number): string {
  if (n >= 1000000) {
    return (n / 1000000).toFixed(1) + 'M';
  }
  if (n >= 1000) {
    return (n / 1000).toFixed(n >= 100000 ? 0 : 1) + 'k';
  }
  return n.toString();
}

/** 模式显示名 */
export function modeLabel(mode: string): string {
  if (mode === 'build') {
    return 'Build';
  }
  if (mode === 'plan') {
    return 'Plan';
  }
  if (mode === 'edit') {
    return 'Edit';
  }
  if (mode === 'yolo') {
    return 'Yolo';
  }
  return mode.length > 0 ? mode : 'Build';
}
