import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BridgeSession } from '../protocol/BridgeSession';
import { FrameIdentity } from '../protocol/FrameCodec';
import { RelayClient, STATE_CLOSED, STATE_ERROR, STATE_PAIRED } from '../protocol/RelayClient';
import { jArr, jNum, jRec, jStr, jBool, parseObj } from '../protocol/Json';
import { BindingInfo, SnapshotResult, SnapshotRuntime, SessionMetaInfo, ModelConfig, ModelOption,
  ModelSelectionView, ModelProviderGroup, ModelEntry, EntitlementSnapshot, EntitlementLimit,
  pickLimit,
  TaskItem, TaskGroup, WorkspaceItem, ChatMessage, ContentPart, ToolCall,
  PermissionRequest, PermissionOption, ElicitationRequest,
  THOUGHT_MAX, TOOL_OUTPUT_MAX, TOOL_INPUT_MAX, truncateText, genClientId } from '../model/Models';
import { BindingStore } from '../store/BindingStore';
import { AppError, ERR_BRIDGE, ERR_NOT_CONNECTED } from '../model/AppError';
import { PhoneInfo } from '../model/PhoneInfo';

const TAG: string = 'ZCRemote';

/**
 * 全局单例: 绑定管理、中继连接、列表同步、桥会话与任务快照
 */
export class ZcodeService {
  private static instance: ZcodeService | undefined = undefined;

  static getInstance(): ZcodeService {
    if (ZcodeService.instance === undefined) {
      ZcodeService.instance = new ZcodeService();
    }
    return ZcodeService.instance;
  }

  binding: BindingInfo | undefined = undefined;
  connState: string = 'idle';
  connDetail: string = '';
  workspaces: Array<WorkspaceItem> = [];
  tasks: Array<TaskItem> = [];
  groups: Array<TaskGroup> = [];
  activeWorkspaceKey: string = '';
  activeTaskId: string = '';
  desktopAppVersion: string = '';
  lastError: string = '';

  private relay: RelayClient | undefined = undefined;
  private bridge: BridgeSession | undefined = undefined;
  private ctx: common.UIAbilityContext | undefined = undefined;
  private listeners: Array<() => void> = [];
  private pendingBridge: PendingBridge | undefined = undefined;
  private refreshingAll: boolean = false;

  setContext(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
  }

  addListener(cb: () => void): void {
    this.listeners.push(cb);
  }

  removeListener(cb: () => void): void {
    const idx = this.listeners.indexOf(cb);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  get bound(): boolean {
    return this.binding !== undefined;
  }

  /** 应用启动时加载绑定并自动连接 */
  async initialize(): Promise<void> {
    if (this.ctx === undefined) {
      return;
    }
    const info = await BindingStore.load(this.ctx);
    if (info !== undefined) {
      this.binding = info;
      this.startConnect();
    }
  }

  /** 保存新绑定并立即连接 */
  async bind(info: BindingInfo): Promise<void> {
    if (this.ctx === undefined) {
      return;
    }
    this.closeBridgeSession();
    this.binding = info;
    await BindingStore.save(this.ctx, info);
    this.startConnect();
  }

  async unbind(): Promise<void> {
    if (this.ctx === undefined) {
      return;
    }
    this.closeBridgeSession();
    if (this.relay !== undefined) {
      this.relay.stop();
      this.relay = undefined;
    }
    this.binding = undefined;
    this.tasks = [];
    this.workspaces = [];
    this.connState = 'idle';
    this.connDetail = '';
    await BindingStore.clear(this.ctx);
    this.notify();
  }

  startConnect(): void {
    if (this.binding === undefined) {
      return;
    }
    if (this.relay !== undefined) {
      this.relay.stop();
    }
    const relay = new RelayClient(this.binding);
    this.relay = relay;
    relay.onState = (state: string, detail: string) => {
      this.connState = state;
      this.connDetail = detail;
      if (state === STATE_ERROR || state === STATE_CLOSED) {
        this.closeBridgeSession();
      }
      if (state === STATE_PAIRED) {
        // 上报本机设备信息（桌面"已连接设备"显示名来源）
        this.sendApp({
          'zcode_type': 'mobile-view-state-update',
          'viewState': { 'updatedAt': Date.now() } as Record<string, Object>,
          'deviceInfo': {
            'platform': 'web',
            'version': this.binding !== undefined ? this.binding.appVersion : 'web',
            'name': PhoneInfo.phoneName(),
            'userAgent': PhoneInfo.userAgent(this.binding !== undefined ? this.binding.appVersion : 'web'),
            'language': PhoneInfo.language(),
            'viewport': PhoneInfo.viewport(),
            'updatedAt': Date.now()
          } as Record<string, Object>
        } as Record<string, Object>);
        // 每次配对成功后主动拉取工作区/任务列表
        this.sendApp({
          'zcode_type': 'bootstrap-request',
          'requestId': `boot-${Date.now()}`
        } as Record<string, Object>);
        this.refreshAllTasks();
      }
      this.notify();
    };
    relay.onPayload = (payload: Record<string, Object>) => {
      this.handlePayload(payload);
    };
    relay.start();
  }

  /** 手动刷新任务列表 */
  requestWorkspaceList(): void {
    this.sendApp({
      'zcode_type': 'workspace-list-request',
      'requestId': `wl-${Date.now()}`
    } as Record<string, Object>);
  }

  private sendApp(payload: Record<string, Object>): boolean {
    if (this.relay === undefined || this.connState !== STATE_PAIRED) {
      return false;
    }
    return this.relay.sendPayloadJson(JSON.stringify(payload));
  }

  private handlePayload(payload: Record<string, Object>): void {
    const zt = jStr(payload, 'zcode_type');
    hilog.info(0x0000, TAG, '[svc] payload zcode_type=%{public}s bridge=%{public}s',
      zt, this.bridge !== undefined ? 'yes' : 'no');
    // 桥内帧优先交给当前桥
    if (this.bridge !== undefined && (zt === 'rpc-frame' || zt === 'rpc-frame-ack')) {
      this.bridge.feedPayload(payload);
      return;
    }
    if (zt === 'bootstrap-response' || zt === 'workspace-list-response' || zt === 'workspace-list-updated') {
      this.applyListResult(jRec(payload, 'result'));
      return;
    }
    if (zt === 'workspace-bridge-ready') {
      if (this.pendingBridge === undefined && this.bridge === undefined) {
        // 兜底：open 的等待方已超时/被清理，但桌面桥已打开——直接接住，避免帧泄漏
        this.onBridgeReady(payload);
        return;
      }
      this.onBridgeReady(payload);
      return;
    }
    if (zt === 'workspace-bridge-error') {
      const sid = jStr(payload, 'bridgeSessionId');
      if (this.pendingBridge !== undefined && this.pendingBridge.bridgeSessionId === sid) {
        const p = this.pendingBridge;
        this.pendingBridge = undefined;
        p.reject(new Error(jStr(payload, 'error')));
      }
      return;
    }
    if (zt === 'bridge-degraded') {
      const sid = jStr(payload, 'bridgeSessionId');
      if (this.bridge !== undefined && this.bridge.identity.bridgeSessionId === sid) {
        this.closeBridgeSession();
        this.lastError = '桥接降级: ' + jStr(payload, 'reason');
        this.notify();
      }
      return;
    }
    if (zt === 'app-error') {
      const reason = jStr(payload, 'reason');
      if (reason === 'desktop-disconnected') {
        this.closeBridgeSession();
      }
      this.lastError = jStr(payload, 'error');
      this.notify();
      return;
    }
  }

  private applyListResult(result: Record<string, Object> | undefined): void {
    if (result === undefined) {
      return;
    }
    const workspaces: Array<WorkspaceItem> = [];
    const wsArr = jArr(result, 'workspaces');
    for (const w of wsArr) {
      const rec = jRec({ 'v': w } as Record<string, Object>, 'v');
      if (rec === undefined) {
        continue;
      }
      const item = new WorkspaceItem();
      item.workspacePath = jStr(rec, 'workspacePath');
      const identity = jStr(rec, 'workspaceIdentity');
      item.workspaceKey = identity.trim().length > 0 ? identity.trim() : item.workspacePath;
      item.label = jStr(rec, 'label');
      if (item.label.length === 0) {
        item.label = item.workspacePath;
      }
      item.kind = jStr(rec, 'kind');
      item.connectionState = jStr(rec, 'connectionState');
      workspaces.push(item);
    }
    const tasks: Array<TaskItem> = [];
    const taskArr = jArr(result, 'tasks');
    for (const t of taskArr) {
      const rec = jRec({ 'v': t } as Record<string, Object>, 'v');
      if (rec === undefined) {
        continue;
      }
      const item = new TaskItem();
      item.taskId = jStr(rec, 'taskId');
      item.title = jStr(rec, 'title');
      item.displayStatus = jStr(rec, 'displayStatus');
      if (item.displayStatus.length === 0) {
        item.displayStatus = 'idle';
      }
      item.updatedAt = jNum(rec, 'updatedAt');
      item.createdAt = jNum(rec, 'createdAt');
      item.hasBackgroundWork = jBool(rec, 'hasBackgroundWork');
      item.pinned = jBool(rec, 'pinned');
      item.archived = jBool(rec, 'archived');
      if (item.archived) {
        continue;
      }
      const identity = jStr(rec, 'workspaceIdentity');
      item.workspacePath = jStr(rec, 'workspacePath');
      item.workspaceKey = identity.trim().length > 0 ? identity.trim() : item.workspacePath;
      tasks.push(item);
    }
    // 排序: 置顶优先，updatedAt 降序
    tasks.sort((a: TaskItem, b: TaskItem): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      return b.updatedAt - a.updatedAt;
    });
    this.workspaces = workspaces;
    this.tasks = tasks;
    this.groups = buildGroups(workspaces, tasks);
    hilog.info(0x0000, TAG, '[svc] list applied: workspaces=%{public}d tasks=%{public}d groups=%{public}d activeKey=%{public}s activeTask=%{public}s',
      workspaces.length, tasks.length, this.groups.length, this.activeWorkspaceKey, this.activeTaskId);
    this.desktopAppVersion = jStr(result, 'desktopAppVersion');
    this.activeWorkspaceKey = jStr(result, 'activeWorkspaceKey');
    this.activeTaskId = jStr(result, 'activeTaskId');
    // bootstrap 响应的激活视图位于 initialViewState 子对象
    if (this.activeWorkspaceKey.length === 0) {
      const view = jRec(result, 'initialViewState');
      if (view !== undefined) {
        this.activeWorkspaceKey = jStr(view, 'activeWorkspaceKey');
        this.activeTaskId = jStr(view, 'activeTaskId');
      }
    }
    this.notify();
  }

  /** 找到任务所属工作区路径（含合并进来的独立工作区任务） */
  findWorkspacePath(workspaceKey: string): string {
    for (const w of this.workspaces) {
      if (w.workspaceKey === workspaceKey) {
        return w.workspacePath;
      }
    }
    // 回退: 任务元数据里的 workspacePath
    for (const t of this.tasks) {
      if (t.taskId === workspaceKey || t.workspaceKey === workspaceKey) {
        return t.workspacePath.length > 0 ? t.workspacePath : workspaceKey;
      }
    }
    return workspaceKey;
  }

  /**
   * 拉取全量任务（含未打开工作区/独立任务）:
   * listGroupedTaskViewStructure({workspaceScopes:[]}) → topLevelOrders(全量 taskId+workspaceKey)
   * 对 bootstrap 未覆盖的工作区再 listTasks({workspacePath}) 补元数据，合并重建分组。
   */
  async refreshAllTasks(): Promise<void> {
    if (this.refreshingAll || this.connState !== STATE_PAIRED) {
      return;
    }
    this.refreshingAll = true;
    try {
      let bridgeMaybe = this.bridge;
      if (bridgeMaybe === undefined) {
        bridgeMaybe = await this.ensureBridge(this.defaultWorkspaceKey(), '');
      }
      const bridge: BridgeSession = bridgeMaybe;
      const structJson = await bridge.channel.request('zcode-task', 'listGroupedTaskViewStructure',
        JSON.stringify([{ 'workspaceScopes': [] } as Record<string, Object>]), 20000);
      const viewStruct = parseObj(structJson);
      if (viewStruct === undefined) {
        return;
      }
      const byWs = new Map<string, Array<string>>();
      const orders = jArr(viewStruct, 'topLevelOrders');
      for (const o of orders) {
        const orec = jRec({ 'v': o } as Record<string, Object>, 'v');
        if (orec === undefined) {
          continue;
        }
        const wsKey = jStr(orec, 'workspaceKey');
        const tid = jStr(orec, 'taskId');
        if (wsKey.length === 0 || tid.length === 0) {
          continue;
        }
        if (!byWs.has(wsKey)) {
          byWs.set(wsKey, new Array<string>());
        }
        const ids = byWs.get(wsKey);
        if (ids !== undefined) {
          ids.push(tid);
        }
      }
      // 找出 bootstrap 未覆盖的工作区
      const knownTasks = new Set<string>();
      for (const t of this.tasks) {
        knownTasks.add(t.taskId);
      }
      const missingWs: Array<string> = [];
      byWs.forEach((ids: Array<string>, wsKey: string) => {
        let covered: boolean = false;
        for (const id of ids) {
          if (knownTasks.has(id)) {
            covered = true;
            break;
          }
        }
        if (!covered) {
          missingWs.push(wsKey);
        }
      });
      if (missingWs.length === 0) {
        return;
      }
      // 逐工作区补元数据
      const extraTasks: Array<TaskItem> = [];
      const extraWorkspaces: Array<WorkspaceItem> = [];
      for (const wsKey of missingWs) {
        try {
          const metaJson = await bridge.channel.request('zcode-task', 'listTasks',
            JSON.stringify([{ 'workspacePath': wsKey } as Record<string, Object>]), 15000);
          const arrText = metaJson.length > 0 ? metaJson : '[]';
          let arr: Array<Object> = [];
          try {
            const parsed: Object = JSON.parse(arrText) as Object;
            if (Array.isArray(parsed)) {
              arr = parsed as Array<Object>;
            }
          } catch (e) {
            arr = [];
          }
          if (arr.length === 0) {
            continue;
          }
          const synthesized = new WorkspaceItem();
          synthesized.workspacePath = wsKey;
          synthesized.workspaceKey = wsKey;
          synthesized.label = pathLabel(wsKey);
          synthesized.kind = 'local';
          extraWorkspaces.push(synthesized);
          for (const t of arr) {
            const trec = jRec({ 'v': t } as Record<string, Object>, 'v');
            if (trec === undefined) {
              continue;
            }
            if (jBool(trec, 'archived')) {
              continue;
            }
            const item = new TaskItem();
            item.taskId = jStr(trec, 'taskId');
            item.title = jStr(trec, 'title');
            item.displayStatus = jStr(trec, 'status');
            if (item.displayStatus.length === 0) {
              item.displayStatus = 'idle';
            }
            item.updatedAt = jNum(trec, 'updatedAt');
            item.createdAt = jNum(trec, 'createdAt');
            item.pinned = jBool(trec, 'pinned');
            item.workspaceKey = wsKey;
            item.workspacePath = wsKey;
            extraTasks.push(item);
          }
        } catch (e) {
          hilog.warn(0x0000, TAG, '[svc] listTasks %{public}s failed: %{public}s',
            wsKey, e instanceof Error ? (e as Error).message : '?');
        }
      }
      if (extraTasks.length === 0) {
        return;
      }
      // 合并去重 + 补充 workspaces + 重建分组
      const merged = this.tasks.slice();
      for (const t of extraTasks) {
        let dup: boolean = false;
        for (const m of merged) {
          if (m.taskId === t.taskId) {
            dup = true;
            break;
          }
        }
        if (!dup) {
          merged.push(t);
        }
      }
      merged.sort((a: TaskItem, b: TaskItem): number => {
        if (a.pinned !== b.pinned) {
          return a.pinned ? -1 : 1;
        }
        return b.updatedAt - a.updatedAt;
      });
      this.tasks = merged;
      const wsKeys = new Set<string>();
      for (const w of this.workspaces) {
        wsKeys.add(w.workspaceKey);
      }
      for (const w of extraWorkspaces) {
        if (!wsKeys.has(w.workspaceKey)) {
          this.workspaces.push(w);
        }
      }
      this.groups = buildGroups(this.workspaces, this.tasks);
      hilog.info(0x0000, TAG, '[svc] all tasks merged: total=%{public}d groups=%{public}d extra=%{public}d',
        this.tasks.length, this.groups.length, extraTasks.length);
      this.notify();
    } catch (e) {
      hilog.warn(0x0000, TAG, '[svc] refreshAllTasks failed: %{public}s',
        e instanceof Error ? (e as Error).message : '?');
    } finally {
      this.refreshingAll = false;
    }
  }

  private defaultWorkspaceKey(): string {
    if (this.activeWorkspaceKey.length > 0) {
      return this.activeWorkspaceKey;
    }
    if (this.workspaces.length > 0) {
      return this.workspaces[0].workspaceKey;
    }
    return '';
  }

  /** 强制关闭并重建桥（会话页轮询连续失败时的自愈入口） */
  forceReopenBridge(): void {
    this.closeBridgeSession();
  }

  /**
   * 退出会话页时调用：把当前任务桥替换为无任务绑定的 home 桥，
   * 使桌面端解除该任务的"被远程查看"标记；同时清空 mobileViewState.activeTaskId。
   */
  closeTaskBinding(workspaceKey: string): void {
    this.forceReopenBridge();
    this.ensureBridge(workspaceKey, '').catch(() => {
      // home 桥打开失败静默：不影响列表页其他功能
    });
    this.sendApp({
      'zcode_type': 'mobile-view-state-update',
      'viewState': { 'activeWorkspaceKey': workspaceKey, 'updatedAt': Date.now() } as Record<string, Object>
    } as Record<string, Object>);
  }

  /** 打开（或复用）当前工作区桥 */
  async ensureBridge(workspaceKey: string, taskId: string): Promise<BridgeSession> {
    if (this.bridge !== undefined && this.bridge.workspaceKey === workspaceKey) {
      // 同工作区还要求任务绑定一致：home 桥（无任务）不能复用为任务桥，反之亦然
      const bound = this.bridge.initialTaskId;
      if (taskId.length === 0 ? bound.length === 0 : bound === taskId) {
        return this.bridge;
      }
    }
    // 并发守卫：已有开桥流程进行中时，等它结束再重试一次（避免孤儿 Promise 与重复 open 帧）
    if (this.pendingBridge !== undefined) {
      await new Promise<void>((resolve) => {
        const check = setInterval(() => {
          if (this.pendingBridge === undefined) {
            clearInterval(check);
            resolve();
          }
        }, 100);
        setTimeout(() => {
          clearInterval(check);
          resolve();
        }, 5000);
      });
      if (this.bridge !== undefined && this.bridge.workspaceKey === workspaceKey) {
        return this.bridge;
      }
    }
    this.closeBridgeSession();
    if (this.connState !== STATE_PAIRED) {
      return await Promise.reject(new Error('未连接到桌面端'));
    }
    if (workspaceKey.length === 0) {
      workspaceKey = this.defaultWorkspaceKey();
    }
    // 独立工作区不在桌面窗口的可用列表中，无法为它开桥；桥只是 RPC 通道，用默认工作区开
    let known: boolean = false;
    for (const w of this.workspaces) {
      if (w.workspaceKey === workspaceKey) {
        known = true;
        break;
      }
    }
    if (!known) {
      workspaceKey = this.defaultWorkspaceKey();
    }
    const bridgeSessionId = `app-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e9).toString(36)}`;
    const request: Record<string, Object> = {
      'zcode_type': 'workspace-bridge-open',
      'requestId': `bridge-${Date.now()}`,
      'bridgeSessionId': bridgeSessionId,
      'bridgeGeneration': 1,
      'workspaceKey': workspaceKey
    };
    if (taskId.length > 0) {
      request['taskId'] = taskId;
    }
    const promise = new Promise<BridgeSession>((resolve, reject) => {
      this.pendingBridge = new PendingBridge(bridgeSessionId, resolve, reject);
    });
    if (!this.sendApp(request)) {
      const p = this.pendingBridge;
      this.pendingBridge = undefined;
      if (p !== undefined) {
        p.reject(new Error('当前未连接桌面端，无法建立会话通道'));
      }
      return await Promise.reject(new AppError(ERR_NOT_CONNECTED, '未连接到桌面端', '请检查网络后重试，或在桌面端确认远程控制开关已打开'));
    }
    const timeout = setTimeout(() => {
      if (this.pendingBridge !== undefined && this.pendingBridge.bridgeSessionId === bridgeSessionId) {
        const p = this.pendingBridge;
        this.pendingBridge = undefined;
        p.reject(new Error('打开桥超时（桌面端可能正忙或工作区已关闭）'));
      }
    }, 15000);
    try {
      const bridge = await promise;
      clearTimeout(timeout);
      this.bridge = bridge;
      return bridge;
    } catch (e) {
      clearTimeout(timeout);
      throw e as Error;
    }
  }

  private onBridgeReady(payload: Record<string, Object>): void {
    const sid = jStr(payload, 'bridgeSessionId');
    const bridgeRec = jRec(payload, 'bridge');
    if (bridgeRec === undefined) {
      if (this.pendingBridge !== undefined && this.pendingBridge.bridgeSessionId === sid) {
        const p0 = this.pendingBridge;
        this.pendingBridge = undefined;
        p0.reject(new Error('桥响应缺少 bridge 字段'));
      }
      return;
    }
    // 构造桥（无论是否有 pendingBridge 等待——桌面桥已打开，必须接管）
    const identity = new FrameIdentity(
      sid,
      jNum(payload, 'bridgeGeneration') > 0 ? jNum(payload, 'bridgeGeneration') : 1,
      jStr(payload, 'recoveryId')
    );
    const bridge = new BridgeSession(identity, jStr(bridgeRec, 'workspaceKey'),
      jStr(bridgeRec, 'workspacePath'), jStr(bridgeRec, 'initialTaskId'));
    bridge.sendAppPayloadJson = (jsonText: string): boolean => {
      if (this.relay === undefined) {
        return false;
      }
      return this.relay.sendPayloadJson(jsonText);
    };
    bridge.onAppPayload = (appPayload: Record<string, Object>) => {
      this.handlePayload(appPayload);
    };
    bridge.onBridgeDown = (reason: string) => {
      if (this.bridge === bridge) {
        this.bridge = undefined;
        this.lastError = '桥已断开: ' + reason;
        this.notify();
      }
    };
    const previous = this.bridge;
    this.bridge = bridge;
    if (this.pendingBridge !== undefined && this.pendingBridge.bridgeSessionId === sid) {
      const p = this.pendingBridge;
      this.pendingBridge = undefined;
      p.resolve(bridge);
    } else {
      hilog.info(0x0000, TAG, '[svc] bridge adopted without pending waiter (%{public}s)', sid);
    }
    if (previous !== undefined && previous !== bridge) {
      // 顶掉旧桥：释放其回调引用
      previous.onTransportDown();
    }
  }

  private closeBridgeSession(): void {
    if (this.bridge !== undefined) {
      const b = this.bridge;
      this.bridge = undefined;
      b.onTransportDown();
    }
    if (this.pendingBridge !== undefined) {
      const p = this.pendingBridge;
      this.pendingBridge = undefined;
      p.reject(new Error('桥已关闭'));
    }
  }

  hasBridge(): boolean {
    return this.bridge !== undefined;
  }

  /**
   * 读取任务快照（含 etag 增量）。返回 undefined 表示 etag 命中（内容未变化）。
   */
  async fetchSnapshot(taskId: string, workspacePath: string, ifNoneMatch: string,
    includeRaw: boolean = false): Promise<SnapshotResult | undefined> {
    if (this.bridge === undefined) {
      return await Promise.reject(new Error('桥未就绪'));
    }
    const args: Record<string, Object> = {
      'taskId': taskId,
      'workspacePath': workspacePath,
      'clientMode': 'web-remote-replayable'
    };
    if (ifNoneMatch.length > 0) {
      args['ifNoneMatch'] = ifNoneMatch;
    }
    const argArray: Array<Object> = [args];
    const dataJson = await this.bridge.channel.request('zcode-task', 'getTaskSnapshotWithEtag',
      JSON.stringify(argArray), 20000);
    if (dataJson.length === 0) {
      return undefined;
    }
    const data = parseObj(dataJson);
    if (data === undefined) {
      hilog.error(0x0000, TAG, '[svc] snapshot parse failed len=%{public}d', dataJson.length);
      throw new AppError(ERR_BRIDGE, '任务快照解析失败', '可能是 ZCode 版本差异导致数据结构变化，请升级 APP 或反馈 issue');
    }
    const result = new SnapshotResult();
    result.etag = jStr(data, 'etag');
    const snapshot = jRec(data, 'snapshot');
    if (snapshot === undefined) {
      // etag 命中，内容未变
      return undefined;
    }
    result.messages = parseSnapshotMessages(snapshot, includeRaw);
    result.runtime = parseSnapshotRuntime(snapshot);
    result.meta = parseSessionMeta(snapshot);
    result.config = parseModelConfig(snapshot);
    applyContextWindowOverride(result);
    return result;
  }

  /**
   * 拉取模型选择注册表视图（与桌面端选择器同源）：
   * 仅含已开启渠道与已启用模型，带模型标称 contextWindow 与思考级别。
   */
  async fetchModelSelectionView(workspacePath: string): Promise<ModelSelectionView> {
    if (this.bridge === undefined) {
      return await Promise.reject(new Error('桥未就绪'));
    }
    const args: Record<string, Object> = {
      'workspacePath': workspacePath
    };
    const identity = this.workspaceIdentityOf(workspacePath);
    if (identity.length > 0) {
      args['workspaceIdentity'] = identity;
    }
    const argArray: Array<Object> = [args];
    const dataJson = await this.bridge.channel.request('model-selection', 'getView',
      JSON.stringify(argArray), 20000);
    const view = new ModelSelectionView();
    const data = parseObj(dataJson);
    if (data === undefined) {
      return view;
    }
    const provArr = jArr(data, 'providers');
    for (const pv of provArr) {
      const prec = jRec({ 'v': pv } as Record<string, Object>, 'v');
      if (prec === undefined) {
        continue;
      }
      const group = new ModelProviderGroup();
      group.providerId = jStr(prec, 'providerId');
      group.providerName = jStr(prec, 'providerName');
      if (group.providerName.length === 0) {
        group.providerName = group.providerId;
      }
      const modelArr = jArr(prec, 'models');
      for (const m of modelArr) {
        const mrec = jRec({ 'v': m } as Record<string, Object>, 'v');
        if (mrec === undefined) {
          continue;
        }
        const entry = new ModelEntry();
        entry.modelId = jStr(mrec, 'modelId');
        const cfg = jRec(mrec, 'config');
        if (cfg !== undefined) {
          const props = jRec(cfg, 'properties');
          if (props !== undefined) {
            entry.contextWindow = jNum(props, 'contextWindow');
          }
          const specs = jRec(cfg, 'optionSpecs');
          if (specs !== undefined) {
            const rl = jRec(specs, 'reasoningLevel');
            if (rl !== undefined) {
              for (const lv of jArr(rl, 'values')) {
                if (typeof lv === 'string') {
                  entry.thoughtLevels.push(lv as string);
                }
              }
            }
          }
        }
        if (entry.modelId.length > 0) {
          group.models.push(entry);
        }
      }
      if (group.models.length > 0) {
        view.providers.push(group);
      }
    }
    hilog.info(0x0000, TAG, '[svc] model view: providers=%{public}d', view.providers.length);
    return view;
  }

  /**
   * 拉取渠道额度快照（5 小时/每周积分或 token 额度、重置时间）。
   * preferredProviderId 从 model-selection 视图取；accountAccess 按 providerId 推导
   * （host 侧用桌面 OAuth 自行解析，无 token 传输）。
   */
  async fetchEntitlement(workspacePath: string, preferredProviderId: string): Promise<EntitlementSnapshot> {
    const out = new EntitlementSnapshot();
    if (this.bridge === undefined) {
      return out;
    }
    const args: Record<string, Object> = {
      'includeSubscription': false,
      'preferredProviderId': preferredProviderId,
      'accountAccess': { 'type': 'zhipu-account', 'family': 'bigmodel', 'planKind': 'individual-coding-plan' } as Record<string, Object>
    };
    if (preferredProviderId.includes('start-plan')) {
      args['accountAccess'] = { 'type': 'zhipu-account', 'family': 'bigmodel', 'planKind': 'start-plan' } as Record<string, Object>;
    }
    const argArray: Array<Object> = [args];
    try {
      const dataJson = await this.bridge.channel.request('usage-stats', 'getEntitlementSnapshot',
        JSON.stringify(argArray), 20000);
      const data = parseObj(dataJson);
      if (data === undefined) {
        return out;
      }
      out.unavailableReason = jStr(data, 'unavailableReason');
      const quota = jRec(data, 'quota');
      if (quota === undefined) {
        return out;
      }
      const limArr = jArr(quota, 'limits');
      for (const l of limArr) {
        const lrec = jRec({ 'v': l } as Record<string, Object>, 'v');
        if (lrec === undefined) {
          continue;
        }
        const item = new EntitlementLimit();
        item.type = jStr(lrec, 'type');
        item.unit = jNum(lrec, 'unit');
        item.number = jNum(lrec, 'number');
        item.currentValue = jNum(lrec, 'currentValue');
        item.limit = jNum(lrec, 'limit');
        item.remaining = jNum(lrec, 'remaining');
        item.percentage = jNum(lrec, 'percentage');
        item.nextResetTime = jNum(lrec, 'nextResetTime');
        out.limits.push(item);
      }
      out.fiveHour = pickLimit(out.limits, 'TOKENS_LIMIT', 3, 5);
      out.weekly = pickLimit(out.limits, 'TOKENS_LIMIT', 6, 0);
      out.available = out.limits.length > 0;
    } catch (e) {
      hilog.warn(0x0000, TAG, '[svc] entitlement failed: %{public}s',
        e instanceof Error ? (e as Error).message : '?');
    }
    hilog.info(0x0000, TAG, '[svc] entitlement: available=%{public}s limits=%{public}d reason=%{public}s',
      String(out.available), out.limits.length, out.unavailableReason);
    return out;
  }

  /** 切换模型 */
  async setModel(taskId: string, workspacePath: string, model: string): Promise<void> {
    await this.agentSessionCall(taskId, workspacePath, 'setModel', (args: Record<string, Object>): void => {
      args['model'] = model;
      args['persistAsWorkspaceLastUsed'] = true;
    });
  }

  /** 切换思考强度 */
  async setThoughtLevel(taskId: string, workspacePath: string, thoughtLevel: string): Promise<void> {
    await this.agentSessionCall(taskId, workspacePath, 'setThoughtLevel',
      (args: Record<string, Object>): void => {
        args['thoughtLevel'] = thoughtLevel;
        args['persistAsWorkspaceLastUsed'] = true;
      });
  }

  /** 切换模式 build/plan/edit/yolo */
  async setMode(taskId: string, workspacePath: string, mode: string): Promise<void> {
    await this.agentSessionCall(taskId, workspacePath, 'setMode', (args: Record<string, Object>): void => {
      args['mode'] = mode;
    });
  }

  /** zcode-agent 通道的 session 级调用通用封装 */
  private async agentSessionCall(taskId: string, workspacePath: string, method: string,
    fillArgs: (args: Record<string, Object>) => void): Promise<void> {
    if (this.bridge === undefined) {
      return await Promise.reject(new Error('桥未就绪'));
    }
    const args: Record<string, Object> = {
      'sessionId': taskId,
      'workspacePath': workspacePath
    };
    fillArgs(args);
    const argArray: Array<Object> = [args];
    await this.bridge.channel.request('zcode-agent', method, JSON.stringify(argArray), 20000);
    hilog.info(0x0000, TAG, '[svc] agentSessionCall %{public}s ok (session=%{public}s)', method, taskId);
  }

  /** 发送用户消息到任务会话（走 zcode-agent.sendPrompt → session/send） */
  async sendMessage(taskId: string, workspacePath: string, text: string): Promise<void> {
    if (this.bridge === undefined) {
      return await Promise.reject(new Error('桥未就绪'));
    }
    const args: Record<string, Object> = {
      'workspacePath': workspacePath,
      'sessionId': taskId,
      'inputId': genClientId(),
      'content': text,
      'clientMode': 'web-remote-replayable'
    };
    const identity = this.workspaceIdentityOf(workspacePath);
    if (identity.length > 0) {
      args['workspaceIdentity'] = identity;
    }
    const argArray: Array<Object> = [args];
    await this.bridge.channel.request('zcode-agent', 'sendPrompt',
      JSON.stringify(argArray), 30000);
    hilog.info(0x0000, TAG, '[svc] message sent to %{public}s len=%{public}d', taskId, text.length);
  }

  /** 中断当前回合 */
  async stopTask(taskId: string, workspacePath: string): Promise<void> {
    if (this.bridge === undefined) {
      return await Promise.reject(new Error('桥未就绪'));
    }
    const envelope: Record<string, Object> = {
      'type': 'stop',
      'payload': {} as Record<string, Object>,
      'sessionId': taskId
    };
    const args: Record<string, Object> = {
      'workspacePath': workspacePath,
      'envelope': envelope
    };
    const identity = this.workspaceIdentityOf(workspacePath);
    if (identity.length > 0) {
      args['workspaceIdentity'] = identity;
    }
    const argArray: Array<Object> = [args];
    await this.bridge.channel.request('zcode-agent', 'sendConversationCommandV4',
      JSON.stringify(argArray), 15000);
    hilog.info(0x0000, TAG, '[svc] stop sent to %{public}s', taskId);
  }

  /** 权限审批（工具确认）: optionId 取自 permission_request.options */
  async resolvePermission(taskId: string, workspacePath: string, requestId: string,
    optionId: string): Promise<void> {
    await this.sendConversationCommand(taskId, workspacePath, 'permission', requestId, () => {
      const payload: Record<string, Object> = {
        'interactionId': requestId,
        'answer': { 'optionId': optionId } as Record<string, Object>
      };
      return payload;
    });
  }

  /**
   * 用户输入问答回复（与网页端一致）：
   * 选择选项 → answer:{optionId}；自由文本 → answer:{freeText}
   */
  async respondElicitation(taskId: string, workspacePath: string, requestId: string,
    optionId: string, freeText: string): Promise<void> {
    await this.sendConversationCommand(taskId, workspacePath, 'elicitation', requestId, () => {
      const answer: Record<string, Object> = {};
      if (freeText.length > 0) {
        answer['freeText'] = freeText;
      } else {
        answer['optionId'] = optionId;
      }
      const payload: Record<string, Object> = {
        'interactionId': requestId,
        'answer': answer
      };
      return payload;
    });
  }

  private async sendConversationCommand(taskId: string, workspacePath: string, tag: string,
    requestId: string, buildPayload: () => Record<string, Object>): Promise<void> {
    if (this.bridge === undefined) {
      return await Promise.reject(new Error('桥未就绪'));
    }
    const envelope: Record<string, Object> = {
      'type': 'resolveInteraction',
      'payload': buildPayload(),
      'sessionId': taskId
    };
    const args: Record<string, Object> = {
      'workspacePath': workspacePath,
      'envelope': envelope
    };
    const identity = this.workspaceIdentityOf(workspacePath);
    if (identity.length > 0) {
      args['workspaceIdentity'] = identity;
    }
    const argArray: Array<Object> = [args];
    await this.bridge.channel.request('zcode-agent', 'sendConversationCommandV4',
      JSON.stringify(argArray), 15000);
    hilog.info(0x0000, TAG, '[svc] resolveInteraction %{public}s %{public}s ok', tag, requestId);
  }

  private workspaceIdentityOf(workspacePath: string): string {
    for (const w of this.workspaces) {
      if (w.workspacePath === workspacePath && w.workspaceKey !== workspacePath) {
        return w.workspaceKey;
      }
    }
    return '';
  }
}

class PendingBridge {
  bridgeSessionId: string;
  resolve: (b: BridgeSession) => void;
  reject: (e: Error) => void;

  constructor(id: string, resolve: (b: BridgeSession) => void, reject: (e: Error) => void) {
    this.bridgeSessionId = id;
    this.resolve = resolve;
    this.reject = reject;
  }
}

/**
 * 模型真实上下文窗口修正表。
 * session 层登记的 contextWindow 可能是会话压缩阈值（如 GLM-5.3-Flash 登记 200K），
 * 与桌面端圆环显示的模型标称窗口（1M）不一致；注册表暂无远程通道，此处内置已确认值。
 */
const MODEL_CONTEXT_WINDOW_OVERRIDES: Array<[string, number]> = [
  ['GLM-5.3-Flash', 1000000],
];

function applyContextWindowOverride(result: SnapshotResult): void {
  if (result.runtime.contextSize <= 0) {
    return;
  }
  const modelId = extractModelId(result.meta.model);
  for (const rule of MODEL_CONTEXT_WINDOW_OVERRIDES) {
    if (modelId === rule[0]) {
      result.runtime.contextSize = rule[1];
      return;
    }
  }
}

function extractModelId(model: string): string {
  const slash = model.lastIndexOf('/');
  return slash > 0 ? model.substring(slash + 1) : model;
}

/** 解析会话当前模型/思考/模式（meta） */
function parseSessionMeta(snapshot: Record<string, Object>): SessionMetaInfo {
  const info = new SessionMetaInfo();
  const rec = jRec(snapshot, 'meta');
  if (rec === undefined) {
    return info;
  }
  info.model = jStr(rec, 'model');
  info.thoughtLevel = jStr(rec, 'thoughtLevel');
  info.mode = jStr(rec, 'mode');
  return info;
}

/** 解析模型选择配置（configOptions 中 id=model 的 select 项） */
function parseModelConfig(snapshot: Record<string, Object>): ModelConfig {
  const cfg = new ModelConfig();
  const arr = jArr(snapshot, 'configOptions');
  for (const c of arr) {
    const crec = jRec({ 'v': c } as Record<string, Object>, 'v');
    if (crec === undefined || jStr(crec, 'id') !== 'model') {
      continue;
    }
    cfg.currentValue = jStr(crec, 'currentValue');
    const optArr = jArr(crec, 'options');
    for (const o of optArr) {
      const orec = jRec({ 'v': o } as Record<string, Object>, 'v');
      if (orec === undefined) {
        continue;
      }
      const opt = new ModelOption();
      opt.value = jStr(orec, 'value');
      opt.name = jStr(orec, 'name');
      opt.modelProviderName = jStr(orec, 'modelProviderName');
      opt.defaultThoughtLevel = jStr(orec, 'modelDefaultThoughtLevel');
      const lvArr = jArr(orec, 'modelThoughtLevels');
      for (const lv of lvArr) {
        if (typeof lv === 'string') {
          opt.thoughtLevels.push(lv as string);
        }
      }
      if (opt.value.length > 0) {
        cfg.options.push(opt);
      }
    }
    break;
  }
  return cfg;
}

/** 按工作区分组任务（组内: 置顶优先 + updatedAt 降序；组间: 组内最新任务时间降序） */
function buildGroups(workspaces: Array<WorkspaceItem>, tasks: Array<TaskItem>): Array<TaskGroup> {
  // 全局按 taskId 去重：bootstrap 与全量合并的竞态可能引入重复
  const seenIds = new Set<string>();
  const uniqueTasks: Array<TaskItem> = [];
  for (const t of tasks) {
    if (t.archived || seenIds.has(t.taskId)) {
      continue;
    }
    seenIds.add(t.taskId);
    uniqueTasks.push(t);
  }
  tasks = uniqueTasks;
  const groups: Array<TaskGroup> = [];
  const used = new Set<string>();
  for (const w of workspaces) {
    const g = new TaskGroup();
    g.key = w.workspaceKey;
    g.label = w.label;
    g.kind = w.kind;
    for (const t of tasks) {
      if (t.archived) {
        continue;
      }
      if (t.workspaceKey === w.workspaceKey) {
        g.tasks.push(t);
        used.add(t.taskId);
      }
    }
    if (g.tasks.length > 0) {
      groups.push(g);
    }
  }
  // 归不进已打开工作区的任务（独立任务）: 按各自工作区路径分组
  const pathGroups = new Map<string, TaskGroup>();
  for (const t of tasks) {
    if (used.has(t.taskId) || t.archived) {
      continue;
    }
    const key = t.workspaceKey.length > 0 ? t.workspaceKey : t.workspacePath;
    const existing: TaskGroup | undefined = pathGroups.get(key);
    const g: TaskGroup = existing !== undefined ? existing : new TaskGroup();
    if (existing === undefined) {
      g.key = key;
      g.label = pathLabel(key);
      pathGroups.set(key, g);
      groups.push(g);
    }
    g.tasks.push(t);
  }
  // 去掉可能的空组
  const nonEmpty: Array<TaskGroup> = [];
  for (const g of groups) {
    if (g.tasks.length > 0) {
      nonEmpty.push(g);
    }
  }
  groups.length = 0;
  for (const g of nonEmpty) {
    groups.push(g);
  }

  // 组排序: 按组内最新任务时间
  groups.sort((a: TaskGroup, b: TaskGroup): number => {
    const ta = a.tasks.length > 0 ? a.tasks[0].updatedAt : 0;
    const tb = b.tasks.length > 0 ? b.tasks[0].updatedAt : 0;
    return tb - ta;
  });
  // 独立对话工作区(default) → 归为"任务"组并置底
  const ordered: Array<TaskGroup> = [];
  const defaultBucket: Array<TaskGroup> = [];
  for (const g of groups) {
    if (isDefaultWorkspaceKey(g.key)) {
      g.label = '任务';
      defaultBucket.push(g);
    } else {
      ordered.push(g);
    }
  }
  groups.length = 0;
  for (const g of ordered) {
    groups.push(g);
  }
  for (const g of defaultBucket) {
    groups.push(g);
  }
  return groups;
}

/** 是否独立对话工作区（~/.zcode/workspace/default） */
function isDefaultWorkspaceKey(key: string): boolean {
  const norm = key.split(String.fromCharCode(92)).join('/').toLowerCase();
  return norm.endsWith('.zcode/workspace/default');
}

/** 路径末段作为显示名 */
function pathLabel(p: string): string {
  const norm = p.replace(/\\/g, '/');
  const segs = norm.split('/').filter((x: string): boolean => x.length > 0);
  return segs.length > 0 ? segs[segs.length - 1] : p;
}

/** 解析单个工具调用 */
function parseToolCall(rec: Record<string, Object>): ToolCall {
  const tc = new ToolCall();
  tc.toolName = jStr(rec, 'toolName');
  tc.title = jStr(rec, 'title');
  if (tc.title.length === 0) {
    tc.title = tc.toolName;
  }
  tc.kind = jStr(rec, 'kind');
  tc.status = jStr(rec, 'status');
  // input 摘要: 取常见关键字段
  const input = jRec(rec, 'input');
  if (input !== undefined) {
    for (const key of ['description', 'title', 'file_path', 'path', 'command', 'query', 'pattern', 'url', 'prompt']) {
      const v: Object | undefined = input[key];
      if (typeof v === 'string' && (v as string).length > 0) {
        tc.inputSummary = (v as string).replace(/\s+/g, ' ');
        if (tc.inputSummary.length > 120) {
          tc.inputSummary = tc.inputSummary.substring(0, 120) + '…';
        }
        break;
      }
    }
    try {
      tc.inputJson = truncateText(JSON.stringify(input, null, 1), TOOL_INPUT_MAX);
    } catch (e) {
      tc.inputJson = '';
    }
  }
  const output: Object | undefined = rec['output'];
  if (typeof output === 'string') {
    tc.outputText = truncateText(output as string, TOOL_OUTPUT_MAX);
  } else if (output !== undefined) {
    try {
      tc.outputText = truncateText(JSON.stringify(output, null, 1), TOOL_OUTPUT_MAX);
    } catch (e) {
      tc.outputText = '';
    }
  }
  return tc;
}

/** 解析快照 runtime（运行状态 + 待审批项） */
function parseSnapshotRuntime(snapshot: Record<string, Object>): SnapshotRuntime {
  const rt = new SnapshotRuntime();
  const rec = jRec(snapshot, 'runtime');
  if (rec === undefined) {
    return rt;
  }
  rt.activeTurnKind = jStr(rec, 'activeTurnKind');
  const usage = jRec(rec, 'contextUsage');
  if (usage !== undefined) {
    rt.contextUsed = jNum(usage, 'used');
    rt.contextSize = jNum(usage, 'size');
  }
  // 权限审批
  const permArr = jArr(rec, 'pendingPermissions');
  for (const p of permArr) {
    const prec = jRec({ 'v': p } as Record<string, Object>, 'v');
    if (prec === undefined) {
      continue;
    }
    const item = new PermissionRequest();
    item.requestId = jStr(prec, 'requestId');
    item.kind = jStr(prec, 'kind');
    item.title = jStr(prec, 'title');
    if (item.title.length === 0) {
      item.title = item.kind;
    }
    item.description = jStr(prec, 'description');
    const optArr = jArr(prec, 'options');
    for (const o of optArr) {
      const orec = jRec({ 'v': o } as Record<string, Object>, 'v');
      if (orec === undefined) {
        continue;
      }
      const opt = new PermissionOption();
      opt.optionId = jStr(orec, 'optionId');
      opt.label = jStr(orec, 'label');
      if (opt.label.length === 0) {
        opt.label = jStr(orec, 'name');
      }
      if (opt.optionId.length > 0 || opt.label.length > 0) {
        item.options.push(opt);
      }
    }
    if (item.requestId.length > 0) {
      rt.pendingPermissions.push(item);
    }
  }
  // 用户输入问答
  const elArr = jArr(rec, 'pendingElicitations');
  for (const p of elArr) {
    const prec = jRec({ 'v': p } as Record<string, Object>, 'v');
    if (prec === undefined) {
      continue;
    }
    const item = new ElicitationRequest();
    item.requestId = jStr(prec, 'requestId');
    item.message = jStr(prec, 'message');
    item.header = jStr(prec, 'header');
    item.multiSelect = jBool(prec, 'multiSelect');
    const optArr = jArr(prec, 'options');
    for (const o of optArr) {
      const orec = jRec({ 'v': o } as Record<string, Object>, 'v');
      if (orec === undefined) {
        continue;
      }
      const opt = new PermissionOption();
      opt.optionId = jStr(orec, 'optionId');
      if (opt.optionId.length === 0) {
        opt.optionId = jStr(orec, 'value');
      }
      opt.label = jStr(orec, 'label');
      if (opt.label.length === 0) {
        opt.label = jStr(orec, 'value');
      }
      if (opt.optionId.length > 0) {
        item.options.push(opt);
      }
    }
    // freeText 标志在 schema（interaction === 'free_text'）或原始字段
    const schema = jRec(prec, 'schema');
    if (schema !== undefined && jStr(schema, 'interaction') === 'free_text') {
      item.freeText = true;
    }
    if (jBool(prec, 'freeText')) {
      item.freeText = true;
    }
    if (item.requestId.length > 0) {
      rt.pendingElicitations.push(item);
    }
  }
  return rt;
}

/**
 * 解析快照中的消息列表。
 * 渲染顺序权威 = parts 数组（type: thought | content | tool-call，tool-call 引用 tools[toolIndex]）。
 * 无 parts 时回退 content 字符串 + thought。
 */
function parseSnapshotMessages(snapshot: Record<string, Object>, includeRaw: boolean): Array<ChatMessage> {
  const out: Array<ChatMessage> = [];
  const msgArr = jArr(snapshot, 'messages');
  for (const m of msgArr) {
    const rec = jRec({ 'v': m } as Record<string, Object>, 'v');
    if (rec === undefined) {
      continue;
    }
    const msg = new ChatMessage();
    msg.id = jStr(rec, 'id');
    msg.role = jStr(rec, 'role');
    msg.timestamp = jNum(rec, 'timestamp');
    msg.durationMs = jNum(rec, 'durationMs');
    // 工具调用
    const toolArr = jArr(rec, 'tools');
    for (const t of toolArr) {
      const trec = jRec({ 'v': t } as Record<string, Object>, 'v');
      if (trec !== undefined) {
        msg.tools.push(parseToolCall(trec));
      }
    }
    // 内容块顺序
    const partArr = jArr(rec, 'parts');
    if (partArr.length > 0) {
      for (const p of partArr) {
        const prec = jRec({ 'v': p } as Record<string, Object>, 'v');
        if (prec === undefined) {
          continue;
        }
        const part = new ContentPart();
        part.type = jStr(prec, 'type');
        const c: Object | undefined = prec['content'];
        part.text = typeof c === 'string' ? (c as string) : '';
        part.toolIndex = jNum(prec, 'toolIndex');
        if (part.type === 'thought') {
          part.text = truncateText(part.text, THOUGHT_MAX);
        }
        if (part.text.length > 0 || part.type === 'tool-call') {
          msg.parts.push(part);
        }
      }
    } else {
      // 回退: content + thought
      const content: Object | undefined = rec['content'];
      if (typeof content === 'string' && (content as string).length > 0) {
        const part = new ContentPart();
        part.type = 'content';
        part.text = content as string;
        msg.parts.push(part);
      }
      const thought: Object | undefined = rec['thought'];
      if (typeof thought === 'string' && (thought as string).length > 0) {
        const part = new ContentPart();
        part.type = 'thought';
        part.text = truncateText(thought as string, THOUGHT_MAX);
        msg.parts.push(part);
      }
    }
    if (includeRaw) {
      msg.rawJson = JSON.stringify(rec);
    }
    out.push(msg);
  }
  return out;
}
