# ZcodeRemote 解锁文档（HANDOFF）

> 本文档是项目的完整交接资料：任何开发者或 AI 工具读完本文件即可接手开发。
> 最后更新：2026-10-03。维护约定：**每次重大改动后同步更新本文件**。

---

## 1. 项目定位

非官方的 [ZCode](https://github.com/zai-org/ZCode)（z.ai 开源编码 Agent，Apache-2.0）**鸿蒙原生伴侣客户端**。桌面端 ZCode 自带"移动端远程控制"功能（扫码后浏览器查看/控制对话），本工程将其实现为鸿蒙 APP：**扫码绑定一次，打开即连**，原生 UI 实现对话查看、任务管理、远程交互（发消息/中断/审批/模型切换）。

- 包名：`com.zcode.remote`；最低 API 12（实测跑在 HarmonyOS 7.0 阔折叠真机）
- 协议：逆向自 ZCode 官方实现（桌面 Electron 端 + 云端中继 + 远程网页），完整规范见 `research/protocol.md`
- 与 Z.ai 无隶属关系；ZCode 商标归其所有者（见 `NOTICE.md`）

## 2. 当前状态（截至最后提交）

| 项 | 状态 |
|---|---|
| 单机全链路（绑定→列表→会话→发消息→中断→审批→模型/思考/模式切换） | ✅ 真机验证通过 |
| 全屏适配（窗口级全屏+手动避让，导航条悬浮于列表内容上） | ✅ 已验证 |
| 归档过滤、项目分组折叠、独立任务置底、重复去重 | ✅ 已验证 |
| 多电脑连接支持 | ⏳ **已设计未实现**（见 §10，这是下一个功能） |
| 已知未对齐项 | 附件/@引用/新建任务/改名归档（协议已逆向，见 FEATURES.md） |

Git 提交历史（全部干净，无敏感数据）：
```
5a65cc1 移除任务卡"查看"文字 + 徽章点击重连 + 合并去重
ec58db7 退出会话解除远程标记（任务桥→home桥替换）
09656f4 真全屏适配（窗口级全屏+手动避让）
5ab6958 任务列表打磨（查看提示/重连徽章/合并去重）
519f1f8 首次提交（全部功能与加固）
```

## 3. 仓库结构

```
ZcodeRemote/
├── HANDOFF.md            ← 本文件
├── README.md             ← 面向使用者的介绍/构建/排查
├── NOTICE.md             ← 上游 ZCode（Apache-2.0）出处声明
├── LICENSE               ← MIT
├── .gitignore            ← 构建产物/签名材料/本机配置/研究样本全部排除
├── app/                  ← 鸿蒙 APP 工程（DevEco Studio / ArkTS，交付主体）
│   ├── AppScope/ + build-profile.json5 + hvigorfile.ts + oh-package.json5
│   ├── entry/src/main/
│   │   ├── module.json5            # 权限仅 INTERNET + CAMERA
│   │   └── ets/
│   │       ├── protocol/           # 协议层（与 ZCode 解耦，可独立测试）
│   │       │   ├── Bytes.ets / Crc32.ets        # varint/Base64/CRC-32
│   │       │   ├── WireSerializer.ets           # 桥内 tagged 二进制序列化
│   │       │   ├── FrameCodec.ets               # rpc-frame 分帧/组装（可靠层）
│   │       │   ├── RelayClient.ets              # 中继 WSS（鉴权/心跳/重连）
│   │       │   ├── ChannelClient.ets            # RPC 通道（请求/响应/事件）
│   │       │   └── BridgeSession.ets            # 工作区桥（组合以上各层）
│   │       ├── service/ZcodeService.ets  # 全局单例：绑定/连接/列表/快照/交互
│   │       ├── store/               # BindingStore(凭证)+QrParser(二维码解析)
│   │       ├── view/                # MarkdownParser + MarkdownView + MessageDataSource
│   │       ├── model/               # Models.ets(数据模型) + AppError.ets(错误分类)
│   │       ├── pages/               # Index(绑定+主页) / SessionPage / SettingsPage
│   │       └── entryability/        # 入口（全屏/主题/避让高度下发）
│   ├── README.md / FEATURES.md      # 构建指南 / 与网页端功能对比表
│   └── build-and-install.sh / serve-hap.sh   # 一键构建安装 / 局域网分发
├── research/
│   └── protocol.md       # ★ 完整协议规范（逆向成果，最重要的文档之一）
└── probe/                # Node 工具：探针/协议单测/图标生成/上游代码切片
    ├── probe.mjs~probe5.mjs   # 各期协议验证探针（凭证从 ~/.zcode/v2 本地读取）
    ├── test_protocol.js       # 协议层单元测试（无需连接）
    └── main|host|spa|renderer # ZCode 上游代码切片（出处见 NOTICE.md）
```

## 4. 协议核心（详见 research/protocol.md）

**架构**：桌面端与手机端各自主动外连云端中继 `wss://<endpoint>/ws`，互不开监听端口。二维码内容 = `https://<endpoint>/remote/v4?sid&hash&t&mid&name&app_version`，其中 sid+hash 是**长期配对凭证**（桌面端持久化，仅"重置配对"轮换）。

**手机端连接时序**（role=`terminal`，注意不是 web）：
1. WSS 连接 → `auth_init{role:"terminal", device_sid}` → 收 `auth_challenge{nonce}`
2. 证明 = `base64url(HMAC-SHA256(key=passHash, msg="nonce|terminal|deviceSid"))` → `auth_response`
3. `auth_ack{pair_status: waiting|matched}` → matched 后可收发
4. 心跳 `pair_status_query` 每 10s，30s 无 ack 重连
5. 应用消息必须包帧：`{type:"data", payload, client_ts}`（发裸 payload 会被 WRONG_PARAM 断链）

**两级数据面**：
- JSON 应用层：`bootstrap-request`、`workspace-list-request`、`workspace-bridge-open`、`mobile-view-state-update`
- 桥内二进制（打开桥后）：rpc-frame 分帧（CRC-32+base64 分片+双向 seq）→ tagged 序列化 → VS Code 风格 RPC 通道

**关键 RPC 通道**（桥内，方法参数是 `[参数对象]` 数组的 JSON）：

| 通道 | 常用方法 |
|---|---|
| `zcode-task` | `getTaskSnapshotWithEtag({taskId,workspacePath,clientMode:"web-remote-replayable",ifNoneMatch?})`、`listTasks({workspacePath})`、rename/archive/pin 等 |
| `zcode-agent` | `sendPrompt({workspacePath,sessionId,inputId,content,clientMode})`、`sendConversationCommandV4({workspacePath,envelope:{type:"stop"/"resolveInteraction"/"sendText",payload,sessionId}})`、`setModel/setThoughtLevel/setMode({sessionId,...})`、`readSession` |
| `model-selection` | `getView([{workspacePath}])` → **已启用渠道+模型注册表视图**（含真实 contextWindow，桌面选择器同源） |

**快照结构**：`{meta:{model,thoughtLevel,mode,...}, messages:[{id,role,content,timestamp,parts?,tools?...}], runtime:{activeTurnKind,contextUsage:{used,size},pendingPermissions,pendingElicitations,...}, configOptions}`。
- **parts 是渲染顺序权威**：`[{type:"thought"|"content"|"tool-call", content, toolIndex}]`，tool-call 引用 `tools[toolIndex]={toolName,status,input,output}`
- **陷阱**：`runtime.contextUsage.size` 是 session 层压缩阈值（GLM-5.3-Flash 记 200K），真实模型窗口（1M）在 `model-selection.getView()` 的模型属性里

**workspaceKey** = `workspaceIdentity.trim() || workspacePath`（与桌面端一致的分组/定位键）。

## 5. APP 架构要点

- **单例** `ZcodeService`：持有绑定、RelayClient、任务/工作区列表、桥会话。页面通过 `addListener/removeListener` 订阅状态通知（notify 驱动 UI 刷新），操作直接调 Service 方法
- **凭证**：passHash 存系统加密资产库（AssetStoreKit，alias=`zcode_pass_hash`），sid/mid/name 存 Preferences；**勿把凭证写日志**（现有日志只打 sid 尾号与 proof 长度）
- **主题**：颜色全部资源化（`resources/base/element/color.json` 浅色 + `resources/dark/element/color.json` 深色），外观偏好存 Preferences，EntryAbility `setColorMode` 应用
- **全屏**：窗口级 `setWindowLayoutFullScreen(true)` + 避让高度经 AppStorage（`statusBarHeight`/`navBarHeight`）下发，页面用 `@StorageProp` 做顶部避让；底部不避让（列表穿过导航条）
- **错误**：`model/AppError.ets` 分类体系（AUTH/DESKTOP_OFFLINE/TIMEOUT/BRIDGE...+suggestion），所有失败路径应产出 AppError
- **会话页退出**：必须调 `closeTaskBinding(workspaceKey)`（任务桥→home 桥替换），否则桌面端"被远程查看"标记残留

## 6. 构建与签名环境（本机事实）

- DevEco Studio 26.0 位于 `D:\Program Files\DevEco Studio`（自带 node/hvigor 6.26.8/SDK API 26）
- **CLI 构建**：`cd app && NODE_HOME="D:\Program Files\DevEco Studio\tools\node" DEVECO_SDK_HOME="D:\Program Files\DevEco Studio\sdk" "D:/Program Files/DevEco Studio/tools/hvigor/bin/hvigorw.bat" --no-daemon assembleHap`
- `app/local.properties`（hwsdk.dir）不入仓
- **签名**：真机只认华为签发证书（OpenHarmony 社区证书会被拒 `9568257`）。唯一路径 = DevEco 自动签名（需登录华为账号），材料生成于 `~/.ohos/config/` 并写入 build-profile.json5。**build-profile.json5 已 git skip-worktree**：仓库里是占位签名材料，本机是真实材料——改它不会进提交，`git status` 也不显示
- API 26 的版本格式是 `"26.0.0"`（无括号）；API≤25 才是 `"5.0.0(12)"` 格式
- 产物：`app/entry/build/default/outputs/default/entry-default-signed.hap`；装机：`hdc install -r <hap>`；启动：`hdc shell aa start -b com.zcode.remote -a EntryAbility`

## 7. 已知坑清单（全部实测踩过）

**ArkTS 语言**：
- `@Builder` 方法**不能声明返回类型**（加 `: void` 会使其失去 Builder 语义，组件树语法整体报 any 级联错误）
- `Record` 不能 `new`：用 `{} as Record<string, boolean>`；该错误会级联污染整个 struct 的类型推断
- import 语句之间不能插 const（arkts-no-misplaced-imports）
- Promise executor 参数不能写类型注解；禁结构化类型/解构声明/未类型化对象字面量
- ForEach 数据源必须用 `@State` 字段（非 @State 的 service 字段会导致整列表不渲染）
- 反斜杠正则字面量易被构建链吞掉——运行时替换用 `String.fromCharCode(92)` 更稳

**ArkUI**：
- `SafeAreaType` 只有 SYSTEM/CUTOUT/KEYBOARD；`expandSafeArea()` 无参 = 全部
- 组件级 expandSafeArea **不能让滚动内容穿越导航条**——必须窗口级 `setWindowLayoutFullScreen(true)` + 页面用 AppStorage 高度手动避让（状态栏高度经 `display.densityPixels` 换算，px2vp 在 Ability 上下文不可靠；hilog 不支持 %f 用 %s）
- List 的 padding bottom 会形成"不显示内容的底色条"——全屏列表不应加底部 padding

**ZCode 协议**：
- 中继应用帧必须包 `{type:"data", payload}`，发裸 payload 被 WRONG_PARAM 断链
- 同 device_sid 二连会被 KICKED（探针与 APP 互斥）；不同 sid 互不干扰
- rpc-frame 必须带 `bridgeGeneration`，否则桌面按 identityMismatch 丢帧
- HMAC 密钥生成器算法名是 `'HMAC'`（不是 'SHA256'，那是 createMac 的摘要名）
- workspaceKey = `workspaceIdentity.trim() || workspacePath`

**调试**：`hdc shell "hilog -x | grep ZCRemote"`（TAG=ZCRemote）；模拟点击 `hdc shell uitest uiInput click X Y`（注意设备坐标 ≠ 截图坐标，需按分辨率换算）；截图放 `C:\Users\Admin\AppData\Local\Temp\zcoderemote\` 且**调试完立即删**（用户红线），报错一律从日志读。

## 8. 关键决策记录（ADR）

| 决策 | 理由 |
|---|---|
| 纯原生 UI 而非 WebView 壳 | 用户明确选择；代价是需完整逆向协议（已完成） |
| 上下文分母用内置修正表兜底 | session 层 contextWindow 是压缩阈值非标称值；真实值在 model-selection 注册表（远程可读）→ 已改为动态读取，修正表仅兜底 |
| 退出会话页用 home 桥替换任务桥 | 桌面无 bridge-close 消息；home 桥（无 taskId，entryKind=home）是桌面 startDraft 的标准路径，替换后"被远程查看"标记解除 |
| 会话内容用 etag 轮询而非接 v4 订阅流 | v4 流（topic/fragment）协议复杂；3s etag 轮询观感一致且实现简单。未来需要即时性再接 `sessionSubscribe` |
| 任务列表 = bootstrap + 全量合并 | bootstrap 只推当前窗口工作区；用 `listGroupedTaskViewStructure({workspaceScopes:[]})`+`listTasks({workspacePath})` 补全独立任务，archived 过滤 |
| probe/ 上游切片入仓 | ZCode 已开源（Apache-2.0），出处已在 NOTICE.md 声明；切片仅作协议研究 |
| 凭证存 AssetStoreKit | 系统级加密，卸载即销毁；sid 等非敏感字段走 Preferences |

## 9. 安全红线

1. **绝不提交**：`research/samples/`（真实会话数据）、签名材料（含设备 UDID）、`~/.ohos` 引用的真实签名配置、任何 deviceSid/passHash/UDID/序列号/API key、`local.properties`（.gitignore 已覆盖，提交前务必跑隐私终扫：`grep -rn "Admin\|UDID前8位\|d_5zbj\|56V02\|192.168" --exclude-dir=.git .`）
2. 历史教训：曾有含完整配对凭证的样本文件被删除，但**该凭证建议在桌面端"重置配对"使其失效**（待用户执行）
3. 二维码内容等同凭证，文档/截图不得外传

## 10. 待办与路线图

### 10.1 多电脑连接（已设计，最高优先级）
需求：一台 APP 同时连接两台电脑的不同 ZCode，可即时切换。
- 调研结论：不同 device_sid 在中继是独立会话（互不干扰），双连接可行
- **设计方案**（已论证）：
  - BindingStore 多绑定：列表存 Preferences JSON，passHash 按独立 asset alias 存储，旧单绑定自动迁移
  - 抽 `service/Connection.ets`（ZcodeConnection 类）：把 ZcodeService 的单机状态与方法整体迁入（binding/relay/tasks/groups/bridge/全部操作方法）
  - ZcodeService 变管理器：`Map<sid, Connection>` + activeSid + `switchTo(sid)` + 增删绑定 API；页面公开 API 委托 active()
  - UI：主页设备名点击弹菜单（每台名称+状态+✓）即点即切；设置页设备列表（切换/逐台解绑）；绑定流程扫码即新增（同 sid 覆盖）
  - 会话页记录所属 sid，操作固定该连接；检测到切换 → 自动退回列表
  - 边界：同名设备加 sid 尾号区分；解绑使用中设备自动切剩余；同 sid 重扫覆盖更新
- 工作量估计：ZcodeService 拆分重构为主（约 1 个完整开发轮次）

### 10.2 后续候选
- 附件/@引用（attachment V4 协议已逆向：attachmentBegin/Chunk/Commit）
- 新建任务（createSession 协议已知）、任务改名/归档 UI
- 文件变更面板（快照 fileChanges 字段已在）、计划 todos 面板（plan 字段已在）
- 接 v4 订阅流（`sessionSubscribe`）替代轮询，获得真正的推送实时性
- 完整 Markdown 渲染（图片/任务列表/脚注）

### 10.3 其他平台移植指引
iOS/Android/桌面客户端：`research/protocol.md` 是完整规范，`probe/*.mjs` 是可运行的 Node 参考实现，`app/entry/src/main/ets/protocol/` 是逐层对应的实现范本。核心即：WSS + HMAC(terminal) + data 帧包装 + bootstrap → 桥 → 通道 RPC。

## 11. 验证流程（每次改动后）

```bash
# 1. 协议单测（如有协议层改动）
cd probe && node test_protocol.js
# 2. 构建（见 §6 命令）
# 3. 装机启动
hdc install -r app/entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -b com.zcode.remote -a EntryAbility
# 4. 日志验证
hdc shell "hilog -x | grep ZCRemote"
# 5. 隐私终扫（提交前）
grep -rn "Admin\|56V02\|6E7098\|d_5zbj\|0000001A" --exclude-dir=.git .
```

## 12. Git 工作流

- 仓库已初始化，首次提交起历史干净；提交署名用 `ZcodeRemote <zcoderemote@users.noreply.github.com>`
- `app/build-profile.json5` 处于 **skip-worktree**（`git ls-files -v` 看 S 前缀）：本机签名材料改动不进版本库。若需恢复跟踪：`git update-index --no-skip-worktree app/build-profile.json5`
- 提交前跑隐私终扫（§11.5）；发布到远程仓库由项目所有者执行
