# ZcodeRemote 解锁文档（HANDOFF）

> 本文档是项目的完整交接资料：任何开发者或 AI 工具读完本文件即可接手开发。
> 最后更新：2026-11-11。维护约定：**每次重大改动后同步更新本文件**。

---

## 1. 项目定位

ZcodeRemote 是非官方的 [ZCode](https://github.com/zai-org/ZCode) HarmonyOS 远程控制宿主。产品采用**WebView 壳优先架构**：扫码建立桌面绑定，官方远程网页负责任务、会话、审批与交互；原生层负责扫码、多设备绑定、登录态持久化、网页状态提示、本地通知、防截屏及系统返回手势。

- 包名：`com.zcode.remote`；最低 API 12。
- 当前网页入口：`https://zcode.z.ai/remote/v4`；仅允许官方 ZCode 与 OAuth 域名。
- 当前 Web↔Shell 桥：`window.zrNative.post(tag, payload)` 单入口，定义见 `app/entry/src/main/ets/bridge/ShellBridge.ets`。
- 与 Z.ai 无隶属关系；ZCode 商标归其所有者（见 `NOTICE.md`）。

## 2. 当前状态（壳优先，2026-11-11）

| 项 | 状态 |
|---|---|
| 纯 sid 二维码绑定 → 官方网页任务/项目列表 | ✅ HarmonyOS 真机验证通过 |
| 登录态跨进程恢复（AuthMirror） | ✅ 已实现 |
| 状态胶囊、WebView 主题联动、断网重试、通知/震动、防截屏 | ✅ 已实现 |
| 多电脑扫码添加/切换/移除 | ✅ 已实现 |
| 每任务运行数与审批状态徽标 | ⚠️ 运行数按任务行 spinner 统计；审批为有/无提示，不推断数量 |
| 系统返回手势回退网页历史 | ✅ 已实现；不同网页视图仍需持续真机验收 |

当前主页面：Index（启动分流）→ BindPage（无绑定时扫码）或 WebStage（绑定后承载官方网页）；SettingsPage 管理多设备与偏好。`WebPage.ets` 是旧壳实现，仅留作迁移参考，不在当前路由中注册。

原生 V1/V2 协议栈（RelayClient、RelayClientV2、ZcodeService、SessionPage）留在源码中作历史/研究参考，不属于当前产品运行路径。旧协议分析见 `research/protocol.md`，以本节和当前代码为准。

**安全边界**：二维码只接受 `https://zcode.z.ai/remote/v4`；网页导航限定到 ZCode 官方及已确认的 OAuth 域；JWT 恢复脚本仅对 `https://zcode.z.ai` 注入；相机/麦克风权限只授予主站，其余来源拒绝。

## 2.1 壳侧核心文件

- `pages/Index.ets`：启动分流。
- `pages/BindPage.ets`：扫码/粘贴、绑定确认、添加设备退路。
- `pages/WebStage.ets`：官方网页容器、状态胶囊、横幅、重试、返回手势、设备菜单、通知与防截屏。
- `bridge/ShellBridge.ets`：tag/payload 单入口、网页探测脚本、受限的 Shell→Web 命令。
- `service/AuthMirror.ets`：ArkWeb 登录态镜像（只在 ZCode 主站恢复）。
- `service/NotifyService.ets`：系统通知槽位与震动。
- `store/BindingStore.ets` / `store/QrParser.ets`：多设备存储、官方域/路径校验、二维码解析。

> WebView 登录态 JWT 属敏感数据，只写入应用私有存储；严禁日志、样例、截图或提交中出现 JWT、完整二维码 URL、设备 SID/MID、设备 UDID、用户主目录或任务标题。

## 2.2 当前运行架构与敏感信息处理（2026-11-11，同步说明）

本节为当前实现的权威说明；本文档前面的原生客户端条目是历史记录，不描述当前运行行为。

- 当前入口：Index → BindPage（未绑定）/ WebStage（已绑定）；官方 WebView 承载任务列表、项目、会话和审批。
- 登录态镜像只在官方主站 origin 恢复；OAuth 页面用于登录跳转，不接收已有 JWT 镜像。二维码、深链和路由 URL 均须经过官方域名/路径校验。
- 相机/麦克风权限仅对 `https://zcode.z.ai` 请求授予；外部站点导航被拦截。
- 日志只允许打印状态、计数、错误类型或 SID 短尾（确有诊断需要时）；严禁完整 SID/MID、JWT、绑定 URL、用户任务标题。
- 本机凭证位于 HarmonyOS 应用私有存储；仓库与 Git 历史只含占位/通用协议示例。



```
ZcodeRemote/
├── HANDOFF.md / README.md / NOTICE.md / LICENSE
├── app/
│   ├── AppScope/ + build-profile.json5 + hvigorfile.ts
│   ├── entry/src/main/
│   │   ├── ets/pages/       # Index / BindPage / WebStage / SettingsPage / LoginWebViewPage
│   │   ├── ets/bridge/      # ShellBridge：Web↔Shell 单入口事件桥与 DOM 探测
│   │   ├── ets/service/     # AuthMirror / NotifyService；旧 ZcodeService 仅供迁移参考
│   │   ├── ets/store/       # BindingStore / QrParser
│   │   ├── ets/model/       # BindingInfo 与展示模型
│   │   └── ets/protocol/    # 历史 V1/V2 原生协议参考，不由壳主流程启动
│   └── README.md / FEATURES.md / 构建与安装脚本
├── research/protocol.md    # 历史 V1/V2 协议逆向存档（非当前运行契约）
└── probe/                  # 协议测试与历史研究脚本；不得包含真实凭证或会话样本
```

## 4. 协议与网页集成

**当前产品路径是官方 WebView 壳，不直接连接中继。** 工作区的 V1/V2 原生协议章节仅用于历史研究与故障取证；当前 UI、登录态、任务/会话数据均由 ZCode 官方网页处理，壳侧只通过 `bridge/ShellBridge.ets` 的单一 JSON 事件桥提供宿主能力。

- Web 页面 URL 从官方 `https://zcode.z.ai/remote/v4` 与扫码得到的 sid/name/mid/version 元数据构造；不在二维码 URL 中持久保存或外传 JWT。
- 登录 OAuth 页面可跳转到已审核的官方 OAuth 域；JWT 镜像只在 `https://zcode.z.ai` 主站注入。
- 网页主题、视图、审批提示、运行任务统计、任务完成通过 tag/payload 事件回传；兼容层不伪造配对 hash。
- 原生 V1/V2 直接中继协议、RPC bridge 与任务快照细节见后续章节，属于归档参考，不是当前产品运行依赖。

## 5. 当前 APP 架构要点

- **启动分流**：Index 读取 BindingStore；有绑定进入 WebStage，无绑定进入 BindPage。
- **主业务**：WebStage 内嵌官方远程页面，管理状态胶囊、网页历史返回、断网重试、异常接管、多设备切换、系统通知、防截屏和 OAuth 登录态镜像。
- **消息桥**：`window.zrNative.post(tag, payload)` 单入口；事件定义与注入逻辑见 `app/entry/src/main/ets/bridge/ShellBridge.ets`。
- **绑定数据**：BindingStore 保存多设备元数据与激活设备；boundUrl 从元数据构造。JWT 使用应用私有存储，WebView 注入限制在官方主站。
- **原生协议栈**：`RelayClient.ets`、`RelayClientV2.ets`、`BridgeSession`、`ZcodeService` 保留作研究/迁移资产，当前壳流程不得同时启动原生 relay，以免同设备被中继踢下线。
- **安全**：仅接受 `https://zcode.z.ai/remote/v4` 二维码；WebStage 只导航到受信任 ZCode/OAuth 域；相机/麦克风仅官方主站可申请；日志不记录完整 SID、JWT、绑定 URL 或任务标题。


## 6. 构建（开发环境）

- 使用 DevEco Studio 与 HarmonyOS SDK；各开发机本地 SDK 路径写在 `app/local.properties`，不入仓。
- 构建命令见 `app/README.md`；签名由开发者在 DevEco Studio 配置，本机签名文件不提交。
- `app/build-profile.json5` 在部分开发机使用 `skip-worktree` 保护本地签名配置；提交前确认只包含仓库模板，不强制添加该文件。
- HAP 位于 `app/entry/build/default/outputs/default/`，构建产物由 Git ignore 排除。

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

**调试**：`hdc shell "hilog -x | grep ZCRemote"`（TAG=ZCRemote）；截图只存系统临时目录，调试验证完立即删除（不要放进项目或提交）。

## 8. 关键决策记录（ADR）

| 决策 | 理由 |
|---|---|
| WebView 壳优先，官方网页承载业务 | 桌面/网页持续更新；避免在手机端重复实现任务、会话、审批等业务协议 |
| 壳↔网页使用单入口 tag/payload 桥 | 缩小接口面，降低网页 DOM/接口变化对原生代码的影响 |
| JWT 仅在官方主站注入 | OAuth 子域可以完成登录跳转，但不接收壳镜像的已有 JWT |
| 运行任务按独立任务行 spinner 探测 | 新版 SPA 的任务行无稳定状态文本；待确认仅显示存在性，不伪造全局数量 |
| 原生 V1/V2 协议实现保留为历史资料 | 当前业务由官方网页运行；避免原生 relay 与网页连接互相踢线 |

## 9. 安全红线

1. 不提交真实会话样本、签名材料、设备 UDID、完整二维码 URL、SID/MID、JWT/API key、私有 IP、用户主目录或任务标题。
2. `app/build-profile.json5` 可能被开发机以 `skip-worktree` 保护；提交前核对其暂存内容，仓库只保留占位配置。
3. 二维码与 WebView 登录态均视为凭证；不进入文档、截图、日志、测试夹具或 Git 历史。
4. 二维码解析仅接受官方 HTTPS 主站与 `/remote/v4` 路径；WebStage 的 JWT 恢复只对主站注入，权限请求按来源校验。
5. 提交前检查当前 diff、全部待推送提交历史及 staged tree 中是否有上述敏感数据；不在扫描命令中写入真实凭证值。

## 10. 后续候选

### 10.1 多电脑与设置
多绑定存储、切换、添加、移除已在壳侧实现（`BindingStore` + WebStage/SettingsPage）。后续维护以官方网页登录页和官方设备选择器行为为准；不实现原生双中继连接。

### 10.2 后续候选
- 按新版官方网页 DOM/事件改动维护 WebStage 的运行任务/待确认提示探测器
- 完善系统返回手势与不同设备尺寸/折叠态验收
- 保持 OAuth host allowlist 与登录态注入 origin 同步评审
- 如未来网页提供正式宿主 API，优先使用正式 API 替代 DOM 探测

### 10.3 其他平台参考
`research/protocol.md` 与 `app/entry/src/main/ets/protocol/` 是历史原生协议研究资料，不是当前壳方案的运行依赖。其他平台优先内嵌官方远程网页并复用宿主能力设计；只有官方网页无法覆盖的能力才考虑原生协议。

## 11. 验证流程（每次改动后）

```bash
# 1. 构建协议代码改动时才运行历史协议单测
cd probe && node test_protocol.js
# 2. HarmonyOS APP 构建（见 app/README.md）
# 3. 真机安装与启动
hdc install -r app/entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -b com.zcode.remote -a EntryAbility
# 4. 检查壳事件日志
hdc shell "hilog -x | grep ZCRemote"
```

提交前检查 diff、暂存区和待推送历史：确认无真实凭证、完整绑定 URL、设备标识、个人路径、私有 IP、任务标题、签名材料或运行日志。
## 12. Git 工作流

- 仓库已初始化，首次提交起历史干净；提交署名用 `ZcodeRemote <zcoderemote@users.noreply.github.com>`
- `app/build-profile.json5` 处于 **skip-worktree**（`git ls-files -v` 看 S 前缀）：本机签名材料改动不进版本库。若需恢复跟踪：`git update-index --no-skip-worktree app/build-profile.json5`
- 提交前跑隐私终扫（§11.5）；发布到远程仓库由项目所有者执行
