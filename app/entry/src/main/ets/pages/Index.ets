import { promptAction, router } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { ZcodeService } from '../service/ZcodeService';
import { QrParser, QrParseResult } from '../store/QrParser';
import { BindingInfo, TaskItem, TaskGroup, formatTime, statusKind } from '../model/Models';

@Entry
@Component
struct Index {
  @State bound: boolean = false;
  @State connState: string = 'idle';
  @State connDetail: string = '';
  @State tasks: Array<TaskItem> = [];
  @State groups: Array<TaskGroup> = [];
  @State collapsedKeys: Array<string> = [];
  @State lastError: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State refreshing: boolean = false;
  @State bindError: string = '';
  @State pasteUrl: string = '';
  private service: ZcodeService = ZcodeService.getInstance();
  private listener: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    // 键盘避让改 RESIZE：键盘弹出压缩页面高度（顶栏留在原位，只压缩列表与输入区）
    try {
      this.getUIContext().setKeyboardAvoidMode(1); // KeyboardAvoidMode.RESIZE
    } catch (e) {
      // ignore
    }
    this.bound = this.service.bound;
    this.connState = this.service.connState;
    this.connDetail = this.service.connDetail;
    this.tasks = this.service.tasks.slice();
    this.listener = () => {
      this.bound = this.service.bound;
      this.connState = this.service.connState;
      this.connDetail = this.service.connDetail;
      this.tasks = this.service.tasks.slice();
      this.groups = this.service.groups.slice();
      this.lastError = this.service.lastError;
    };
    this.service.addListener(this.listener);
  }

  aboutToDisappear(): void {
    if (this.listener !== undefined) {
      this.service.removeListener(this.listener);
      this.listener = undefined;
    }
  }

  build() {
    Stack() {
      if (!this.bound) {
        this.bindView()
      } else {
        this.homeView()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.statusBarHeight })
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea()
  }

  /** ============ 绑定页 ============ */
  @Builder
  bindView() {
    Column({ space: 20 }) {
      Blank().height(60)
      Image($r('app.media.app_icon'))
        .width(92)
        .height(92)
        .borderRadius(22)
      Text('ZCode Remote')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('扫码绑定一次，之后打开即连。\n无需每次扫码，无需浏览器。')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)

      Button('扫码绑定')
        .width('60%')
        .height(46)
        .backgroundColor($r('app.color.accent'))
        .fontColor(Color.White)
        .fontSize(16)
        .onClick(() => {
          this.doScanBind();
        })

      Divider()
        .strokeWidth(1)
        .color($r('app.color.btn_secondary_bg'))
        .width('70%')

      Text('或粘贴绑定链接（桌面端二维码的内容）')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))

      TextInput({ placeholder: 'https://zcode.z.ai/remote/v4?sid=...', text: this.pasteUrl })
        .width('86%')
        .height(42)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .backgroundColor($r('app.color.bg_card'))
        .onChange((v: string) => {
          this.pasteUrl = v;
        })

      Button('链接绑定')
        .width('60%')
        .height(42)
        .backgroundColor($r('app.color.btn_secondary_bg'))
        .fontColor($r('app.color.text_primary'))
        .fontSize(15)
        .onClick(() => {
          this.doPasteBind();
        })

      if (this.bindError.length > 0) {
        Text(this.bindError)
          .fontSize(13)
          .fontColor($r('app.color.error_text'))
          .textAlign(TextAlign.Center)
          .width('86%')
      }

      Blank()
    }
    .width('100%')
    .height('100%')
  }

  private async requestCamera(): Promise<boolean> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const mgr = abilityAccessCtrl.createAtManager();
      const result = await mgr.requestPermissionsFromUser(ctx, ['ohos.permission.CAMERA'] as Array<Permissions>);
      for (const r of result.authResults) {
        if (r === 0) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  private doScanBind(): void {
    this.requestCamera().then((granted: boolean) => {
      if (!granted) {
        this.bindError = '未授予相机权限，无法扫码；可改用下方粘贴链接方式绑定';
        return;
      }
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      };
      const ctx = getContext(this) as common.Context;
      scanBarcode.startScanForResult(ctx, options).then((res: scanBarcode.ScanResult) => {
        this.applyBinding(res.originalValue);
      }).catch((e: Error) => {
        this.bindError = '扫码取消或失败: ' + e.message;
      });
    });
  }

  private isCollapsed(key: string): boolean {
    return this.collapsedKeys.indexOf(key) >= 0;
  }

  private toggleGroup(key: string): void {
    const idx = this.collapsedKeys.indexOf(key);
    const next = this.collapsedKeys.slice();
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(key);
    }
    this.collapsedKeys = next;
  }

  private doPasteBind(): void {
    this.applyBinding(this.pasteUrl);
  }

  private applyBinding(text: string): void {
    const parsed: QrParseResult = QrParser.parse(text);
    if (!parsed.ok || parsed.info === undefined) {
      this.bindError = parsed.error;
      return;
    }
    const info: BindingInfo = parsed.info;
    // 安全确认：把凭证发往的服务器必须让用户知情
    promptAction.showDialog({
      title: '确认绑定',
      message: `设备：${info.deviceName}\n服务器：${info.endpointOrigin}\n\n确认将配对凭证保存到该服务器对应的连接？`,
      buttons: [
        { text: '取消', color: '#9AA1B5' },
        { text: '确认绑定', color: '#3B6FE0' }
      ]
    }).then((result) => {
      if (result.index !== 1) {
        return;
      }
      this.bindError = '';
      this.service.bind(info).then(() => {
        promptAction.showToast({ message: `已绑定 ${info.deviceName}`, duration: 2000 });
      }).catch((e: Error) => {
        this.bindError = '保存绑定失败: ' + e.message;
      });
    });
  }

  /** ============ 主页（任务列表） ============ */
  @Builder
  homeView() {
    Column() {
      // 顶栏
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('ZCode Remote')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          this.stateBadge()
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('刷新')
          .height(32)
          .fontSize(13)
          .backgroundColor($r('app.color.btn_secondary_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.service.requestWorkspaceList();
            this.service.refreshAllTasks();
          })

        Button() {
          Text('⚙')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
        }
        .height(32)
        .width(44)
        .backgroundColor($r('app.color.btn_secondary_bg'))
        .onClick(() => {
          router.pushUrl({ url: 'pages/SettingsPage' });
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 6 })

      if (this.connState !== 'paired') {
        Text(this.stateHint())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 16, right: 16, bottom: 6 })
          .width('100%')
      }

      if (this.lastError.length > 0) {
        Text('⚠ ' + this.lastError)
          .fontSize(11)
          .fontColor($r('app.color.error_text'))
          .padding({ left: 16, right: 16, bottom: 6 })
          .width('100%')
          .maxLines(2)
      }

      // 任务列表
      Refresh({ refreshing: this.refreshing }) {
        List({ space: 4 }) {
          if (this.tasks.length === 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text(this.connState === 'paired' ? '暂无任务' : '尚未连接到桌面端')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.connState === 'paired'
                  ? '在桌面端开启远程控制并开始一个任务后，这里会实时显示'
                  : this.stateHint())
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding({ top: 80 })
            }
          }
          ForEach(this.groups, (group: TaskGroup) => {
            ListItem() {
              Column({ space: 4 }) {
                // 项目分组头（点击折叠/展开）
                Row({ space: 6 }) {
                  Text(this.isCollapsed(group.key) ? '▸' : '▾')
                    .fontSize(10)
                    .fontColor($r('app.color.text_tertiary'))
                    .width(14)
                  Text(group.label)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(group.tasks.length.toString())
                    .fontSize(10)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .width('100%')
                .padding({ top: 4, bottom: 2 })
                .onClick(() => {
                  this.toggleGroup(group.key);
                })
                if (!this.isCollapsed(group.key)) {
                  ForEach(group.tasks, (task: TaskItem) => {
                    this.taskCard(task)
                  }, (task: TaskItem) => {
                    return task.taskId + task.updatedAt.toString();
                  })
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }, (group: TaskGroup) => {
            return group.key + '#' + group.tasks.length.toString() + '#' +
              (group.tasks.length > 0 ? group.tasks[0].updatedAt.toString() : '');
          })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 10, right: 10 })
      }
      .layoutWeight(1)
      .onRefreshing(() => {
        this.service.requestWorkspaceList();
        this.service.refreshAllTasks();
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  stateBadge() {
    Row({ space: 6 }) {
      Circle({ width: 8, height: 8 })
        .fill(this.stateColor())
      Text(this.stateText())
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
      if (this.connState !== 'paired' && this.connState !== 'idle') {
        Text('点击重连')
          .fontSize(10)
          .fontColor($r('app.color.accent'))
      }
    }
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.connState !== 'paired') {
        this.service.startConnect();
        promptAction.showToast({ message: '正在重新连接…', duration: 1500 });
      }
    })
  }

  private stateColor(): ResourceColor {
    if (this.connState === 'paired') {
      return $r('app.color.state_ok');
    }
    if (this.connState === 'waiting' || this.connState === 'connecting' ||
      this.connState === 'authenticating' || this.connState === 'reconnecting') {
      return $r('app.color.state_warn');
    }
    if (this.connState === 'error') {
      return $r('app.color.error_text');
    }
    return $r('app.color.text_tertiary');
  }

  private stateText(): string {
    if (this.connState === 'paired') {
      return '已连接';
    }
    if (this.connState === 'waiting') {
      return '等待桌面端';
    }
    if (this.connState === 'connecting' || this.connState === 'authenticating' || this.connState === 'reconnecting') {
      return '连接中';
    }
    if (this.connState === 'error') {
      return '连接错误';
    }
    return '未连接';
  }

  private stateHint(): string {
    if (this.connDetail.length > 0) {
      return this.connDetail;
    }
    if (this.connState === 'error') {
      return '连接出错，请到设置页检查绑定或重新扫码';
    }
    return '打开桌面端 ZCode 的"远程控制"开关后自动完成配对';
  }

  @Builder
  taskCard(task: TaskItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(task.pinned ? '📌 ' : '')
          .fontSize(11)
        Text(task.title.length > 0 ? task.title : '(未命名任务)')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        this.statusChip(task)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(formatTime(task.updatedAt))
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .padding(10)
    .borderRadius(10)
    .backgroundColor($r('app.color.bg_card'))
    .width('100%')
    .onClick(() => {
      const params: Record<string, Object> = {
        'taskId': task.taskId,
        'title': task.title,
        'workspaceKey': task.workspaceKey
      };
      router.pushUrl({
        url: 'pages/SessionPage',
        params: params
      });
    })
  }

  @Builder
  statusChip(task: TaskItem) {
    Text(this.statusText(task))
      .fontSize(11)
      .fontColor(Color.White)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(8)
      .backgroundColor(this.statusBg(task))
  }

  private statusText(task: TaskItem): string {
    const kind = statusKind(task.displayStatus);
    if (kind === 'running') {
      return '运行中';
    }
    if (kind === 'attention') {
      return '待确认';
    }
    if (kind === 'failed') {
      return '失败';
    }
    if (kind === 'done') {
      return '已完成';
    }
    return task.displayStatus;
  }

  private statusBg(task: TaskItem): ResourceColor {
    const kind = statusKind(task.displayStatus);
    if (kind === 'running') {
      return $r('app.color.chip_running');
    }
    if (kind === 'attention') {
      return $r('app.color.chip_attention');
    }
    if (kind === 'failed') {
      return $r('app.color.chip_failed');
    }
    if (kind === 'done') {
      return $r('app.color.chip_done');
    }
    return $r('app.color.chip_other');
  }
}
