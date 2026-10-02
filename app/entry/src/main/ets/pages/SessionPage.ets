import { promptAction, router } from '@kit.ArkUI';
import { ChatMessage, ContentPart, ToolCall, SnapshotRuntime, PermissionRequest,
  PermissionOption, ElicitationRequest, ModelOption, ModelConfig, SessionMetaInfo,
  ModelSelectionView, ModelProviderGroup, ModelEntry,
  EntitlementSnapshot, EntitlementLimit, limitTypeMatch, limitPeriodLabel,
  formatTime, statusKind, formatTokens, modeLabel } from '../model/Models';
import { AppError } from '../model/AppError';
import { ZcodeService } from '../service/ZcodeService';
import { BridgeSession } from '../protocol/BridgeSession';
import { MarkdownView } from '../view/MarkdownView';
import { MessageDataSource } from '../view/MessageDataSource';

const POLL_INTERVAL_MS: number = 3000;

@Entry
@Component
struct SessionPage {
  @State dataSource: MessageDataSource = new MessageDataSource();
  @State loading: boolean = true;
  @State loadError: string = '';
  @State showRaw: boolean = false;
  @State runtime: SnapshotRuntime = new SnapshotRuntime();
  @State meta: SessionMetaInfo = new SessionMetaInfo();
  @State config: ModelConfig = new ModelConfig();
  @State modelView: ModelSelectionView = new ModelSelectionView();
  @State entitlement: EntitlementSnapshot = new EntitlementSnapshot();
  @State modelSheetShow: boolean = false;
  @State sheetProvider: ModelProviderGroup | undefined = undefined;
  @State sending: boolean = false;
  private service: ZcodeService = ZcodeService.getInstance();
  private taskId: string = '';
  private title: string = '';
  private workspaceKey: string = '';
  private workspacePath: string = '';
  private bridge: BridgeSession | undefined = undefined;
  private etag: string = '';
  private pollTimer: number = -1;
  private polling: boolean = false;
  private scroller: Scroller = new Scroller();
  /** 用户是否停留在底部（底部才自动跟随新消息） */
  private stickBottom: boolean = true;
  /** 发送/审批后强制跟随一次 */
  private forceFollow: boolean = false;
  /** 连续失败次数（达到上限停止轮询，显示重试按钮） */
  private failCount: number = 0;
  private maxFailCount: number = 4;
  private connState: string = '';
  private connDetail: string = '';
  /** 卡片展开状态表（键 = uid），卡片重建后可恢复 */
  @State openMap: Record<string, boolean> = {} as Record<string, boolean>;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  private serviceListener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.taskId = params['taskId'] !== undefined ? params['taskId'] as string : '';
    this.title = params['title'] !== undefined ? params['title'] as string : '';
    this.workspaceKey = params['workspaceKey'] !== undefined ? params['workspaceKey'] as string : '';
    this.workspacePath = this.service.findWorkspacePath(this.workspaceKey);
    this.connState = this.service.connState;
    this.connDetail = this.service.connDetail;
    this.serviceListener = () => {
      this.connState = this.service.connState;
      this.connDetail = this.service.connDetail;
    };
    this.service.addListener(this.serviceListener);
    this.startSession();
  }

  aboutToDisappear(): void {
    this.stopPolling();
    // 解除任务绑定：替换为 home 桥，桌面端"被远程查看"标记随此消失
    this.service.closeTaskBinding(this.workspaceKey);
    if (this.serviceListener !== undefined) {
      this.service.removeListener(this.serviceListener);
      this.serviceListener = undefined;
    }
  }

  onPageHide(): void {
    // 退后台停止轮询，省电省流量
    this.stopPolling();
  }

  onPageShow(): void {
    // 回前台立即刷新一次并恢复轮询
    if (this.pollTimer === -1 && this.taskId.length > 0) {
      this.pollOnce(false);
      this.startPolling();
    }
  }

  private async startSession(): Promise<void> {
    try {
      this.bridge = await this.service.ensureBridge(this.workspaceKey, this.taskId);
      await this.bridge.channel.waitReady(3000);
      await this.pollOnce(true);
      this.startPolling();
      this.refreshModelView();
      this.refreshEntitlement();
    } catch (e) {
      this.loadError = e instanceof Error ? (e as Error).message : '打开会话失败';
      this.loading = false;
    }
  }

  /** 拉取模型注册表视图（与桌面选择器同源）；失败时回退 configOptions 平铺 */
  private refreshModelView(): void {
    this.service.fetchModelSelectionView(this.workspacePath)
      .then((view: ModelSelectionView) => {
        this.modelView = view;
        // 视图就绪后拉额度（需要 preferredProviderId）
        this.refreshEntitlement();
      })
      .catch((e: Error) => {
        // 视图获取失败不影响主流程，模型菜单回退 configOptions
      });
  }

  /** 拉取渠道额度（5 小时/每周），失败静默（状态条不显示额度项） */
  private refreshEntitlement(): void {
    const providerId = this.currentProviderId();
    if (providerId.length === 0) {
      return;
    }
    this.service.fetchEntitlement(this.workspacePath, providerId)
      .then((snap: EntitlementSnapshot) => {
        this.entitlement = snap;
      })
      .catch((e: Error) => {
        // 静默：额度是辅助信息
      });
  }

  private currentProviderId(): string {
    const model = this.meta.model;
    const slash = model.lastIndexOf('/');
    return slash > 0 ? model.substring(0, slash) : '';
  }

  /** 额度菜单标签（5 小时/每周） */
  private entitlementLabel(l: EntitlementLimit): string {
    const period = limitPeriodLabel(l);
    let usage: string;
    if (l.percentage >= 0) {
      usage = `已用 ${Math.min(100, Math.max(0, Math.round(l.percentage)))}%`;
    } else if (l.limit > 0) {
      usage = `已用 ${formatTokens(l.currentValue)}/${formatTokens(l.limit)}`;
    } else {
      usage = `剩余 ${formatTokens(l.remaining)}`;
    }
    let reset = '';
    if (l.nextResetTime > 0) {
      const d = new Date(l.nextResetTime);
      const p = (n: number): string => {
        return n < 10 ? `0${n}` : `${n}`;
      };
      reset = ` · ${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())} 重置`;
    }
    return `${period}：${usage}${reset}`;
  }

  private buildEntitlementMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [];
    items.push({
      value: '── 渠道额度 ──',
      action: (): void => {
      }
    });
    if (!this.entitlement.available) {
      items.push({
        value: this.entitlement.unavailableReason.length > 0
          ? `暂不可用（${this.entitlement.unavailableReason}）` : '暂无额度数据',
        action: (): void => {
        }
      });
      return items;
    }
    for (const l of this.entitlement.limits) {
      items.push({
        value: this.entitlementLabel(l),
        action: (): void => {
          this.refreshEntitlement();
        }
      });
    }
    items.push({
      value: '（点击条目刷新）',
      action: (): void => {
      }
    });
    return items;
  }

  private startPolling(): void {
    this.stopPolling();
    this.pollTimer = setInterval(() => {
      this.pollOnce(false);
    }, POLL_INTERVAL_MS);
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async pollOnce(first: boolean): Promise<void> {
    if (this.polling || this.taskId.length === 0) {
      return;
    }
    this.polling = true;
    try {
      const result = await this.service.fetchSnapshot(this.taskId, this.workspacePath, this.etag, this.showRaw);
      this.failCount = 0;
      if (result !== undefined) {
        this.etag = result.etag;
        this.dataSource.reload(result.messages);
        this.runtime = result.runtime;
        this.meta = result.meta;
        this.config = result.config;
        // 注册表标称窗口优先（session 层记录的可能是压缩阈值）
        this.applyRegistryContextWindow();
        this.loadError = '';
        this.scrollToLatest(first);
      }
      if (first) {
        this.loading = false;
      }
    } catch (e) {
      const err = AppError.from(e as Object, '读取快照失败');
      this.failCount += 1;
      this.loadError = err.display();
      if (first) {
        this.loading = false;
      }
      if (this.failCount >= this.maxFailCount) {
        // 连续失败达到上限：停止轮询，给出明确指引（避免风暴）
        this.stopPolling();
        this.loadError = err.display() + ` —— 已连续失败 ${this.failCount} 次，自动刷新已暂停`;
        return;
      }
      if (!first && this.failCount === 1) {
        // 仅首次失败时重建桥一次（后续交给退避与手动重试，避免与 ready 竞态）
        this.bridge = undefined;
        this.service.forceReopenBridge();
      }
    } finally {
      this.polling = false;
    }
  }

  private manualRetry(): void {
    this.failCount = 0;
    this.loadError = '';
    this.loading = true;
    this.bridge = undefined;
    this.service.forceReopenBridge();
    this.startSession();
  }

  /** 首次进入或仍在底部时，滚动到最新消息（两拍滚动：渲染后再补一次，保证贴合底部） */
  private scrollToLatest(first: boolean): void {
    if (!(first || this.stickBottom || this.forceFollow)) {
      return;
    }
    this.forceFollow = false;
    const doScroll = (): void => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 忽略滚动时机问题
      }
    };
    setTimeout(doScroll, 80);
    setTimeout(doScroll, 350);
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 10 }) {
        Button() {
          Text('‹')
            .fontSize(18)
            .fontColor($r('app.color.text_primary'))
        }
        .width(32)
        .height(30)
        .backgroundColor($r('app.color.btn_secondary_bg'))
        .onClick(() => {
          router.back();
        })

        Column({ space: 2 }) {
          Text(this.title.length > 0 ? this.title : '会话')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.loadError.length > 0 ? this.loadError : this.statusText())
            .fontSize(10)
            .fontColor(this.loadError.length > 0 ? $r('app.color.error_text') : $r('app.color.text_secondary'))
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.showRaw ? '渲染' : 'JSON')
          .height(28)
          .fontSize(11)
          .backgroundColor($r('app.color.btn_secondary_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.showRaw = !this.showRaw;
            this.pollOnce(false);
          })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: this.statusBarHeight + 6, bottom: 6 })

      // 会话状态条: 上下文占用 + 模型 + 思考 + 模式
      Row({ space: 8 }) {
        Row({ space: 4 }) {
          Progress({ value: this.ctxPercent(), total: 100, type: ProgressType.Linear })
            .color(this.ctxColor())
            .backgroundColor($r('app.color.bg_input'))
            .style({ strokeWidth: 4 })
            .width(36)
          Text(this.ctxLabel())
            .fontSize(9)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(VerticalAlign.Center)

        Blank()

        if (this.entitlement.available) {
          Text('⚡ ' + this.entitlementBadge())
            .fontSize(10)
            .fontColor(this.entitlementColor())
            .bindMenu(this.buildEntitlementMenu())
        }
        if (this.config.options.length > 0) {
          Text(this.modelLabel())
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '38%' })
            .bindMenu(this.buildModelMenu())
        }
        if (this.thoughtLabel().length > 0) {
          Text('思考·' + this.thoughtLabel())
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .bindMenu(this.buildThoughtMenu())
        }
        Text(modeLabel(this.meta.mode))
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .bindMenu(this.buildModeMenu())
      }
      .width('100%')
      .height(22)
      .borderRadius(6)
      .backgroundColor($r('app.color.bg_card'))
      .padding({ left: 8, right: 8 })
      .margin({ left: 10, right: 10 })

      if (this.pollTimer === -1 && this.failCount >= this.maxFailCount && !this.loading) {
        Button('重新连接并刷新')
          .height(32)
          .fontSize(13)
          .backgroundColor($r('app.color.accent'))
          .fontColor(Color.White)
          .margin({ bottom: 6 })
          .onClick(() => {
            this.manualRetry();
          })
      }

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('app.color.accent'))
          Text('正在连接桌面端工作区…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 6, scroller: this.scroller }) {
          LazyForEach(this.dataSource, (msg: ChatMessage) => {
            ListItem() {
              this.messageCard(msg)
            }
          }, (msg: ChatMessage) => {
            return msg.id;
          })
          ListItem() {
            Text('· 已加载到最新 ·')
              .fontSize(9)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(6)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 10, right: 10, bottom: 8 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .onScrollIndex((first: number, last: number) => {
          // 可视末项到达最后一条消息（或提示行）即认为在底部
          this.stickBottom = last >= this.dataSource.totalCount() - 1;
        })
      }

      // ===== 底部操作区: 审批卡片 + 停止按钮 + 输入框 =====
      Column({ space: 8 }) {
        // 待审批卡片（权限 / 问答）
        ForEach(this.runtime.pendingPermissions, (perm: PermissionRequest) => {
          PermissionCardView({
            title: perm.title,
            description: perm.description,
            options: perm.options,
            onPick: (optionId: string) => {
              this.onResolvePermission(perm.requestId, optionId);
            }
          })
        }, (perm: PermissionRequest) => perm.requestId + perm.options.length.toString())

        ForEach(this.runtime.pendingElicitations, (el: ElicitationRequest) => {
          ElicitationCardView({
            header: el.header,
            message: el.message,
            options: el.options,
            freeTextEnabled: el.freeText,
            onAnswer: (optionId: string, freeText: string) => {
              this.onRespondElicitation(el.requestId, optionId, freeText);
            }
          })
        }, (el: ElicitationRequest) => el.requestId + el.options.length.toString())

        InputBarView({
          sending: this.sending,
          canStop: this.runtime.activeTurnKind.length > 0 && this.runtime.activeTurnKind !== 'idle',
          onSubmitText: (text: string): void => {
            this.onSend(text);
          },
          onStop: (): void => {
            this.onStop();
          }
        })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 4, bottom: this.navBarHeight + 6 })
      .backgroundColor($r('app.color.bg_page'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .bindSheet(this.modelSheetShow, this.modelSheetBuilder(), {
      height: 420,
      showClose: false,
      onDisappear: () => {
        this.modelSheetShow = false;
      }
    })
  }

  @Builder
  modelSheetBuilder() {
    Column() {
      Row({ space: 8 }) {
        if (this.sheetProvider !== undefined) {
          Text('‹')
            .fontSize(18)
            .fontColor($r('app.color.text_primary'))
            .width(32)
            .onClick(() => {
              this.sheetProvider = undefined;
            })
        }
        Text(this.sheetProvider !== undefined ? this.sheetProvider.providerName : '选择渠道')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button() {
          Text('×')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .width(30)
        .height(28)
        .backgroundColor($r('app.color.btn_secondary_bg'))
        .onClick(() => {
          this.modelSheetShow = false;
        })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 8 })

      List({ space: 4 }) {
        if (this.sheetProvider === undefined) {
          ForEach(this.modelView.providers, (prov: ModelProviderGroup) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(prov.providerName)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                  Text(prov.models.length.toString() + ' 个模型')
                    .fontSize(10)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('›')
                  .fontSize(16)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .borderRadius(10)
              .backgroundColor($r('app.color.bg_card'))
              .onClick(() => {
                this.sheetProvider = prov;
              })
            }
          }, (prov: ModelProviderGroup) => prov.providerId)
        } else {
          ForEach(this.sheetModels(), (m: ModelEntry) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(this.isCurrentModel(this.sheetProviderProviderId() + '/' + m.modelId) ? '✓ ' : '')
                  .fontSize(14)
                  .fontColor($r('app.color.accent'))
                  .width(24)
                Text(m.modelId)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                if (m.contextWindow > 0) {
                  Text(formatTokens(m.contextWindow))
                    .fontSize(10)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .onClick(() => {
                this.onSwitchModelById(this.sheetProviderProviderId(), m.modelId,
                  m.contextWindow, m.thoughtLevels);
                this.modelSheetShow = false;
              })
            }
          }, (m: ModelEntry) => m.modelId)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 10, right: 10, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /** 用模型注册表标称窗口覆盖 session 层分母（若视图已加载且能匹配当前模型） */
  private applyRegistryContextWindow(): void {
    if (this.modelView.providers.length === 0 || this.meta.model.length === 0) {
      return;
    }
    for (const prov of this.modelView.providers) {
      for (const m of prov.models) {
        const value = prov.providerId + '/' + m.modelId;
        if (value === this.meta.model && m.contextWindow > 0) {
          this.runtime.contextSize = m.contextWindow;
          return;
        }
      }
    }
  }

  private entitlementBadge(): string {
    const l = this.entitlement.fiveHour !== undefined ? this.entitlement.fiveHour
      : (this.entitlement.weekly !== undefined ? this.entitlement.weekly
        : (this.entitlement.limits.length > 0 ? this.entitlement.limits[0] : undefined));
    if (l === undefined) {
      return '';
    }
    if (l.percentage >= 0) {
      return Math.round(100 - Math.min(100, Math.max(0, l.percentage))) + '%';
    }
    return formatTokens(l.remaining);
  }

  private entitlementColor(): ResourceColor {
    const l = this.entitlement.fiveHour !== undefined ? this.entitlement.fiveHour
      : (this.entitlement.weekly !== undefined ? this.entitlement.weekly
        : (this.entitlement.limits.length > 0 ? this.entitlement.limits[0] : undefined));
    if (l === undefined) {
      return $r('app.color.text_secondary');
    }
    const used = l.percentage >= 0 ? l.percentage : (l.limit > 0 ? l.currentValue / l.limit * 100 : 0);
    if (used >= 90) {
      return $r('app.color.state_bad');
    }
    if (used >= 70) {
      return $r('app.color.state_warn');
    }
    return $r('app.color.state_ok');
  }

  private ctxPercent(): number {
    if (this.runtime.contextSize <= 0 || this.runtime.contextUsed <= 0) {
      return 0;
    }
    const v = this.runtime.contextUsed / this.runtime.contextSize * 100;
    return Math.min(100, Math.max(0, v));
  }

  private ctxColor(): ResourceColor {
    const v = this.ctxPercent();
    if (v >= 85) {
      return $r('app.color.state_bad');
    }
    if (v >= 60) {
      return $r('app.color.state_warn');
    }
    return $r('app.color.state_ok');
  }

  private ctxLabel(): string {
    if (this.runtime.contextSize <= 0) {
      return '';
    }
    return formatTokens(this.runtime.contextUsed) + '/' + formatTokens(this.runtime.contextSize);
  }

  private modelLabel(): string {
    const opt = this.config.currentOption();
    if (opt !== undefined) {
      return opt.name;
    }
    const mid = this.meta.model;
    const slash = mid.lastIndexOf('/');
    return slash > 0 ? mid.substring(slash + 1) : mid;
  }

  private thoughtLabel(): string {
    const t = this.config.currentThought();
    return t.length > 0 ? t : this.meta.thoughtLevel;
  }

  private buildModelMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [];
    // 首选注册表视图：仅含已开启渠道与已启用模型，按渠道分组（与桌面客户端一致）
    if (this.modelView.providers.length > 0) {
      for (const prov of this.modelView.providers) {
        items.push({
          value: '── ' + prov.providerName + ' ──',
          action: (): void => {
          }
        });
        for (const m of prov.models) {
          const value = prov.providerId + '/' + m.modelId;
          const isCurrent = this.isCurrentModel(value);
          const label = (isCurrent ? '✓ ' : '') + m.modelId;
          items.push({
            value: label,
            action: (): void => {
              this.onSwitchModelById(prov.providerId, m.modelId, m.contextWindow, m.thoughtLevels);
            }
          });
        }
      }
      return items;
    }
    // 回退：configOptions 平铺（视图获取失败时保证可用）
    for (const opt of this.config.options) {
      const isCurrent = opt.value === this.config.currentValue ||
        (opt.value === this.config.currentModelId() + '$' + this.thoughtLabel());
      const item: MenuElement = {
        value: (isCurrent ? '✓ ' : '') + opt.name + ' · ' + opt.modelProviderName,
        action: (): void => {
          this.onSwitchModel(opt);
        }
      };
      items.push(item);
    }
    return items;
  }

  /** 当前选中值 = providerId/modelId（与 configOptions value 同格式） */
  private isCurrentModel(value: string): boolean {
    const currentFull = this.meta.model;
    if (currentFull === value) {
      return true;
    }
    // meta.model 与 value 同为 provider/model 格式
    const slash = currentFull.lastIndexOf('/');
    const currentModel = slash > 0 ? currentFull.substring(slash + 1) : currentFull;
    const valueModel = value.substring(value.lastIndexOf('/') + 1);
    const valueProvider = value.substring(0, value.lastIndexOf('/'));
    return currentModel === valueModel && currentFull.indexOf(valueProvider) >= 0;
  }

  private buildThoughtMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [];
    const levels = this.currentThoughtLevels();
    const current = this.thoughtLabel();
    for (const lv of levels) {
      const isCurrent = lv === current;
      const item: MenuElement = {
        value: (isCurrent ? '✓ ' : '') + lv,
        action: (): void => {
          this.onSwitchThought(lv);
        }
      };
      items.push(item);
    }
    return items;
  }

  private buildModeMenu(): Array<MenuElement> {
    const modes: Array<string> = ['build', 'plan', 'edit', 'yolo'];
    const items: Array<MenuElement> = [];
    for (const m of modes) {
      const isCurrent = m === this.meta.mode;
      const item: MenuElement = {
        value: (isCurrent ? '✓ ' : '') + modeLabel(m),
        action: (): void => {
          this.onSwitchMode(m);
        }
      };
      items.push(item);
    }
    return items;
  }

  private currentThoughtLevels(): Array<string> {
    // 注册表视图当前模型的思考级别
    const slash = this.meta.model.lastIndexOf('/');
    const providerId = slash > 0 ? this.meta.model.substring(0, slash) : '';
    const modelId = slash > 0 ? this.meta.model.substring(slash + 1) : this.meta.model;
    for (const prov of this.modelView.providers) {
      if (prov.providerId !== providerId) {
        continue;
      }
      for (const m of prov.models) {
        if (m.modelId === modelId && m.thoughtLevels.length > 0) {
          return m.thoughtLevels;
        }
      }
    }
    // 回退 configOptions
    const opt = this.config.currentOption();
    if (opt !== undefined && opt.thoughtLevels.length > 0) {
      return opt.thoughtLevels;
    }
    const fallback: Array<string> = ['low', 'high', 'max'];
    return fallback;
  }

  /** 按注册表视图切换模型（providerId/modelId） */
  private onSwitchModelById(providerId: string, modelId: string, contextWindow: number,
    thoughtLevels: Array<string>): void {
    this.sending = true;
    // 与桌面一致：切模型附带该模型的默认思考档位
    const level = thoughtLevels.length > 0 ? thoughtLevels[thoughtLevels.length - 1] : '';
    this.service.setModel(this.taskId, this.workspacePath, providerId, modelId, level)
      .then(() => {
        promptAction.showToast({ message: '模型已切换: ' + modelId, duration: 1500 });
        if (level.length > 0) {
          return this.service.setThoughtLevel(this.taskId, this.workspacePath, level);
        }
        return Promise.resolve();
      })
      .then(() => {
        this.sending = false;
        // 用注册表 contextWindow 立即修正分母
        if (contextWindow > 0) {
          this.runtime.contextSize = contextWindow;
        }
        this.refreshModelView();
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        this.sending = false;
        promptAction.showToast({ message: '切换失败: ' + e.message, duration: 2500 });
      });
  }

  private onSwitchModel(opt: ModelOption): void {
    // value 形如 providerId/modelId$thought —— 拆为对象
    const dollar = opt.value.lastIndexOf('$');
    const base = dollar > 0 ? opt.value.substring(0, dollar) : opt.value;
    const thought = dollar > 0 ? opt.value.substring(dollar + 1) : opt.defaultThoughtLevel;
    const slash = base.lastIndexOf('/');
    const providerId = slash > 0 ? base.substring(0, slash) : base;
    const modelId = slash > 0 ? base.substring(slash + 1) : base;
    this.service.setModel(this.taskId, this.workspacePath, providerId, modelId, thought)
      .then(() => {
        promptAction.showToast({ message: '模型已切换: ' + opt.name, duration: 1500 });
        if (thought.length > 0) {
          return this.service.setThoughtLevel(this.taskId, this.workspacePath, thought);
        }
        return Promise.resolve();
      })
      .then(() => {
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        promptAction.showToast({ message: '切换失败: ' + e.message, duration: 2500 });
      });
  }

  private onSwitchThought(level: string): void {
    this.service.setThoughtLevel(this.taskId, this.workspacePath, level)
      .then(() => {
        promptAction.showToast({ message: '思考强度: ' + level, duration: 1500 });
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        promptAction.showToast({ message: '切换失败: ' + e.message, duration: 2500 });
      });
  }

  private onSwitchMode(mode: string): void {
    this.service.setMode(this.taskId, this.workspacePath, mode)
      .then(() => {
        promptAction.showToast({ message: '模式: ' + modeLabel(mode), duration: 1500 });
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        promptAction.showToast({ message: '切换失败: ' + e.message, duration: 2500 });
      });
  }

  private onSend(text: string): void {
    const body = text.trim();
    if (body.length === 0 || this.sending) {
      return;
    }
    this.sending = true;
    this.service.sendMessage(this.taskId, this.workspacePath, body)
      .then(() => {
        this.sending = false;
        this.stickBottom = true;
        this.forceFollow = true;
        // 发送后立即拉一次快照（不等下个 3s 周期）
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        this.sending = false;
        this.loadError = '发送失败: ' + e.message;
        promptAction.showToast({ message: '发送失败: ' + e.message, duration: 2500 });
      });
  }

  private onStop(): void {
    this.service.stopTask(this.taskId, this.workspacePath)
      .then(() => {
        promptAction.showToast({ message: '已发送停止指令', duration: 1500 });
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        promptAction.showToast({ message: '停止失败: ' + e.message, duration: 2500 });
      });
  }

  private onResolvePermission(requestId: string, optionId: string): void {
    this.service.resolvePermission(this.taskId, this.workspacePath, requestId, optionId)
      .then(() => {
        this.stickBottom = true;
        this.forceFollow = true;
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        promptAction.showToast({ message: '操作失败: ' + e.message, duration: 2500 });
      });
  }

  private onRespondElicitation(requestId: string, optionId: string, freeText: string): void {
    this.service.respondElicitation(this.taskId, this.workspacePath, requestId, optionId, freeText)
      .then(() => {
        this.stickBottom = true;
        this.forceFollow = true;
        this.pollOnce(false);
      })
      .catch((e: Error) => {
        promptAction.showToast({ message: '操作失败: ' + e.message, duration: 2500 });
      });
  }

  private sheetModels(): Array<ModelEntry> {
    return this.sheetProvider !== undefined ? this.sheetProvider.models : new Array<ModelEntry>();
  }

  private sheetProviderProviderId(): string {
    return this.sheetProvider !== undefined ? this.sheetProvider.providerId : '';
  }

  private statusText(): string {
    if (this.connState === 'paired') {
      return `已连接 · 每 ${POLL_INTERVAL_MS / 1000}s 自动刷新`;
    }
    if (this.connDetail.length > 0) {
      return this.connDetail;
    }
    if (this.connState.length > 0) {
      return '连接状态: ' + this.connState;
    }
    return `每 ${POLL_INTERVAL_MS / 1000}s 自动刷新`;
  }

  private partsKey(msg: ChatMessage): string {
    let k = '';
    for (const p of msg.parts) {
      k += p.type.charAt(0);
      if (p.type === 'tool-call') {
        k += p.toolIndex.toString();
      } else {
        k += p.text.length.toString();
      }
      k += ',';
    }
    return k;
  }

  @Builder
  messageCard(msg: ChatMessage) {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text(this.roleLabel(msg.role))
          .fontSize(10)
          .fontColor(Color.White)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(5)
          .backgroundColor(this.roleColor(msg.role))
        if (msg.durationMs > 0) {
          Text((msg.durationMs / 1000).toFixed(1) + 's')
            .fontSize(9)
            .fontColor($r('app.color.text_tertiary'))
        }
        Blank()
        if (msg.timestamp > 0) {
          Text(formatTime(msg.timestamp))
            .fontSize(9)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')

      if (this.showRaw) {
        Text(msg.rawJson)
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .fontFamily('monospace')
          .maxLines(12)
          .padding(8)
          .borderRadius(8)
          .backgroundColor($r('app.color.bg_code'))
          .width('100%')
      } else {
        ForEach(msg.parts, (part: ContentPart, idx: number) => {
          if (part.type === 'thought') {
            ThoughtCardView({
              uid: msg.id + '-t' + idx.toString(), body: part.text,
              open: this.openMap[msg.id + '-t' + idx.toString()] === true,
              onToggle: (uid: string, open: boolean) => {
                this.openMap[uid] = open;
              }
            })
          } else if (part.type === 'tool-call') {
            if (part.toolIndex >= 0 && part.toolIndex < msg.tools.length) {
              ToolCardView({
                uid: msg.id + '-c' + part.toolIndex.toString(), tool: msg.tools[part.toolIndex],
                open: this.openMap[msg.id + '-c' + part.toolIndex.toString()] === true,
                onToggle: (uid: string, open: boolean) => {
                  this.openMap[uid] = open;
                }
              })
            }
          } else {
            MarkdownView({ text: part.text })
          }
        }, (part: ContentPart, idx: number) => {
          return msg.id + '-' + idx.toString() + '-' + part.type;
        })
      }
    }
    .padding(msg.role === 'user' ? 10 : 0)
    .borderRadius(10)
    .backgroundColor(msg.role === 'user' ? $r('app.color.msg_user_bg') : Color.Transparent)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private roleLabel(role: string): string {
    const r = role.toLowerCase();
    if (r === 'user' || r.includes('human')) {
      return '用户';
    }
    if (r === 'assistant' || r.includes('ai') || r.includes('agent')) {
      return 'AI';
    }
    if (r.includes('tool')) {
      return '工具';
    }
    if (r.includes('system')) {
      return '系统';
    }
    return role.length > 0 ? role : '消息';
  }

  private roleColor(role: string): ResourceColor {
    const r = role.toLowerCase();
    if (r === 'user' || r.includes('human')) {
      return $r('app.color.role_user');
    }
    if (r === 'assistant' || r.includes('ai') || r.includes('agent')) {
      return $r('app.color.role_ai');
    }
    if (r.includes('tool')) {
      return $r('app.color.role_tool');
    }
    return $r('app.color.role_system');
  }
}

/** 思考过程卡片（默认折叠，灰色等宽小字） */
@Component
struct ThoughtCardView {
  @Prop uid: string;
  @Prop body: string;
  @Prop open: boolean;
  onToggle: (uid: string, open: boolean) => void = (uid: string, open: boolean) => {
  };

  build() {
    Column({ space: 4 }) {
      Row({ space: 5 }) {
        Text(this.open ? '▾' : '▸')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
        Text('思考过程')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(this.open ? '收起' : '展开')
          .fontSize(9)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .onClick(() => {
        this.onToggle(this.uid, !this.open);
      })

      if (this.open) {
        Text(this.body)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding(8)
          .borderRadius(8)
          .backgroundColor($r('app.color.bg_input'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 工具调用卡片（标题行 + 可展开的输入/输出） */
@Component
struct ToolCardView {
  @Prop uid: string;
  @Prop tool: ToolCall;
  @Prop open: boolean;
  onToggle: (uid: string, open: boolean) => void = (uid: string, open: boolean) => {
  };

  private statusText(status: string): string {
    const s = status.toLowerCase();
    if (s.includes('run') || s.includes('progress') || s.includes('pending')) {
      return '运行中';
    }
    if (s.includes('complet') || s.includes('done') || s.includes('success') || s.includes('finish')) {
      return '完成';
    }
    if (s.includes('fail') || s.includes('error')) {
      return '失败';
    }
    return status.length > 0 ? status : '—';
  }

  private statusColor(status: string): ResourceColor {
    const kind = statusKind(status);
    if (kind === 'running') {
      return $r('app.color.chip_running');
    }
    if (kind === 'failed') {
      return $r('app.color.chip_failed');
    }
    if (kind === 'done') {
      return $r('app.color.chip_done');
    }
    return $r('app.color.chip_other');
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Circle({ width: 6, height: 6 })
          .fill(this.statusColor(this.tool.status))
        Text(this.tool.toolName)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        if (this.tool.inputSummary.length > 0) {
          Text(this.tool.inputSummary)
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          Blank()
        }
        Text(this.open ? '▾' : '▸')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .onClick(() => {
        this.onToggle(this.uid, !this.open);
      })

      if (this.open) {
        if (this.tool.inputJson.length > 0) {
          Column({ space: 4 }) {
            Text('输入')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.tool.inputJson)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor($r('app.color.code_text'))
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(8)
          .borderRadius(8)
          .backgroundColor($r('app.color.bg_code'))
        }
        if (this.tool.outputText.length > 0) {
          Column({ space: 4 }) {
            Text('输出')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
            Scroll() {
              Text(this.tool.outputText)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor($r('app.color.code_text'))
                .width('100%')
            }
            .height(260)
            .scrollBar(BarState.Auto)
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(8)
          .borderRadius(8)
          .backgroundColor($r('app.color.bg_code'))
        }
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4, left: 8, right: 8 })
    .borderRadius(7)
    .backgroundColor($r('app.color.bg_input'))
    .alignItems(HorizontalAlign.Start)
  }
}

/** 底部输入行：[停止(运行中)] [输入框] [发送]。击键仅重渲染本组件 */
@Component
struct InputBarView {
  @Prop sending: boolean;
  @Prop canStop: boolean;
  onSubmitText: (text: string) => void = (text: string) => {
  };
  onStop: () => void = () => {
  };
  @State text: string = '';

  private submit(): void {
    const body = this.text.trim();
    if (body.length === 0 || this.sending) {
      return;
    }
    this.text = '';
    this.onSubmitText(body);
  }

  build() {
    Row({ space: 6 }) {
      if (this.canStop) {
        Button() {
          Rect({ width: 11, height: 11 })
            .fill($r('app.color.error_text'))
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor($r('app.color.btn_secondary_bg'))
        .onClick(() => {
          this.onStop();
        })
      }

      TextInput({ placeholder: '输入消息…', text: this.text })
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .placeholderFont({ size: 13 })
        .backgroundColor($r('app.color.bg_input'))
        .borderRadius(18)
        .height(36)
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Send)
        .onChange((v: string) => {
          this.text = v;
        })
        .onSubmit(() => {
          this.submit();
        })

      Button() {
        Text(this.sending ? '…' : '↑')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.text.trim().length > 0 && !this.sending
        ? $r('app.color.accent') : $r('app.color.btn_secondary_bg'))
      .enabled(this.text.trim().length > 0 && !this.sending)
      .onClick(() => {
        this.submit();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

/** 权限审批卡片（工具确认） */
@Component
struct PermissionCardView {
  @Prop title: string;
  @Prop description: string;
  @Prop options: Array<PermissionOption>;
  onPick: (optionId: string) => void = (optionId: string) => {
  };

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 })
          .fill($r('app.color.state_warn'))
        Text('需要确认')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')

      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row({ space: 8 }) {
        ForEach(this.options, (opt: PermissionOption) => {
          Button(opt.label.length > 0 ? opt.label : opt.optionId)
            .fontSize(13)
            .height(34)
            .layoutWeight(1)
            .backgroundColor($r('app.color.accent'))
            .fontColor(Color.White)
            .onClick(() => {
              this.onPick(opt.optionId);
            })
        }, (opt: PermissionOption) => opt.optionId + opt.label)
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .borderRadius(10)
    .border({ width: 1, color: $r('app.color.state_warn') })
    .backgroundColor($r('app.color.bg_card'))
  }
}

/** 用户输入问答卡片（AskUserQuestion / 计划审批） */
@Component
struct ElicitationCardView {
  @Prop header: string;
  @Prop message: string;
  @Prop options: Array<PermissionOption>;
  @Prop freeTextEnabled: boolean;
  onAnswer: (optionId: string, freeText: string) => void = (optionId: string, freeText: string) => {
  };
  @State freeText: string = '';

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 })
          .fill($r('app.color.accent'))
        Text(this.header.length > 0 ? this.header : '等待你的输入')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }

      // 选项按钮 → answer:{optionId}
      if (this.options.length > 0) {
        Column({ space: 6 }) {
          ForEach(this.options, (opt: PermissionOption) => {
            Button(opt.label)
              .fontSize(13)
              .height(36)
              .width('100%')
              .backgroundColor($r('app.color.btn_secondary_bg'))
              .fontColor($r('app.color.text_primary'))
              .onClick(() => {
                this.onAnswer(opt.optionId, '');
              })
          }, (opt: PermissionOption) => opt.optionId + opt.label)
        }
        .width('100%')
      }

      // 自由文本 → answer:{freeText}（仅 schema 标记 free_text 的问答显示）
      if (this.freeTextEnabled || this.options.length === 0) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '输入回答…', text: this.freeText })
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .backgroundColor($r('app.color.bg_input'))
            .borderRadius(18)
            .height(36)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.freeText = v;
            })
          Button('提交')
            .fontSize(13)
            .height(36)
            .backgroundColor($r('app.color.accent'))
            .fontColor(Color.White)
            .enabled(this.freeText.trim().length > 0)
            .onClick(() => {
              this.onAnswer('', this.freeText.trim());
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(10)
    .borderRadius(10)
    .border({ width: 1, color: $r('app.color.accent') })
    .backgroundColor($r('app.color.bg_card'))
  }
}
