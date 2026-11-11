# ZCode Web Remote Control 历史协议笔记（V1/V2 原生栈归档）

> **当前运行架构（2026-11-11）**：ZcodeRemote 使用 WebView 壳优先方案，官方网页承载任务/会话/审批。本文件其余内容是旧原生 relay 与 RPC bridge 的逆向笔记，只供历史研究，不是当前应用协议契约。
>
> 当前壳↔网页事件桥、允许的网页/OAuth 域与认证态安全边界见 [`HANDOFF.md`](../HANDOFF.md) 和 `app/entry/src/main/ets/bridge/ShellBridge.ets`。
>
> 本文示例只使用占位符。不要添加真实 JWT、sid/mid、二维码 URL、设备信息、用户路径、IP 或任务内容。

## 0. 总体架构

```
┌────────────┐  role=device  ┌─────────────────┐  role=terminal  ┌──────────┐
│ ZCode 桌面  │◄──── WSS ────►│ 云端中继          │◄──── WSS ──────►│ 手机 APP  │
│ (Electron) │               │ wss://zcode.z.ai/ws │                │ (本工程)  │
└────────────┘               └─────────────────┘                 └──────────┘
```

- 桌面端与手机端都**主动外连**同一个云端 WebSocket 中继（本机不监听端口）。
- 二维码内容：`https://zcode.z.ai/remote/v4?sid=<deviceSid>&hash=<passHash>&t=<客户端毫秒时间戳>&mid=<deviceMid>&name=<设备名>&app_version=<版本>`
- 配对凭证：
  - `deviceSid`（协议分配的设备会话 ID）：桌面端保存在其用户配置目录的设置存储中。
  - `passHash`：V1 历史协议使用的密码摘要；仅用于理解旧版 challenge-response，不是当前壳的凭证来源。
  - V1 配对凭证只作历史协议示例；不要从开发机配置复制真实值到文档、样本或日志。
  - `t` 是客户端时间戳，每次连接可重新生成。

## 1. 中继 WebSocket 层（JSON 文本帧）

连接：`wss://zcode.z.ai/ws?mid=<deviceMid>`（mid 可选；桌面端另带 `X-Device-ID` 头，浏览器/APP 不需要）。

### 1.1 鉴权（手机端 role=terminal）

| 方向 | 消息 |
|---|---|
| → | `{type:"auth_init", role:"terminal", device_sid, meta:{platform:"web", version:"3.14.4", name:"mobile-browser"}, client_ts}` |
| ← | `{type:"auth_challenge", nonce}` |
| → | `{type:"auth_response", device_sid, proof, client_ts}` 其中 `proof = base64url(HMAC-SHA256(key=passHash, msg=nonce+"|terminal|"+deviceSid))` |
| ← | `{type:"auth_ack", pair_status:"waiting"|"matched"}` |

- 桌面端同流程但 `role="device"`，证明消息为 `nonce|device|deviceSid`；首次配对时桌面端先发 `device_register_init {device_mid, pass_hash, meta, client_ts}` 换取 `device_sid`。
- `waiting` = 凭证有效但桌面端未连接；30s 内未 matched 则手机端报"desktop did not match"。
- `matched` = 配对成功，可收发 data。

### 1.2 心跳与错误

- 心跳（双方，配对后每 ~10s 带 jitter）：`{type:"pair_status_query", device_sid, client_ts}` → 回 `pair_status_ack`；30s 无 ack 则重连。
- 错误帧 `{type:"error", code, message}`，code：`KICKED`（被顶掉/桌面重置配对）、`AUTH_FAILED`、`DEVICE_OFFLINE`（手机端应重试）、`INTERNAL`、`WRONG_PARAM`。
- 断线重连：指数退避 `min(10s, 500*2^attempt)`。

### 1.3 数据帧

配对后：`{type:"data", payload, client_ts, server_ts}`。payload 为 JSON 对象，按 `zcode_type` 区分：

**手机端 → 桌面端：**
| zcode_type | 字段 | 说明 |
|---|---|---|
| `bootstrap-request` | requestId | 获取初始状态（工作区+任务+视图） |
| `workspace-list-request` | requestId | 刷新任务列表 |
| `platform-request` | requestId, method, args | 调桌面辅助方法（isDockerAvailable 等） |
| `mobile-view-state-update` | viewState:{activeWorkspaceKey, activeTaskId?, updatedAt}, deviceInfo? | 同步手机当前视图 |
| `workspace-bridge-open` | requestId, bridgeSessionId, bridgeGeneration, recoveryId?, workspaceKey, taskId? | 打开会话桥 |
| `workspace-reconnect-request` | requestId, workspaceKey | 让桌面重连某工作区 |
| `rpc-frame` / `rpc-frame-ack` | 见 §2 | 桥内二进制帧 |

**桌面端 → 手机端：**
| zcode_type | 字段 |
|---|---|
| `bootstrap-response` | requestId, success, result:{windowControlSessionId, desktopAppVersion, workspaces[], tasks[], initialViewState, mobileViewState} |
| `workspace-list-response` | requestId, success, result:{workspaces[], tasks[], activeWorkspaceKey, activeTaskId} |
| `workspace-list-updated` | result（同上，任务变化时主动推送） |
| `platform-response` | requestId, method, success, result/error |
| `workspace-bridge-ready` | requestId, bridgeSessionId, bridgeGeneration?, recoveryId?, bridge:{bridgeSessionId, bridgeGeneration, recoveryId, workspaceKey, workspacePath, kind, initialTaskId, ...} |
| `workspace-bridge-error` | requestId, bridgeSessionId, reason(desktop-disconnected/workspace-closed/unsupported-action/unexpected-error), error |
| `workspace-reconnect-response` | requestId, workspaceKey, success, error? |
| `bridge-degraded` | bridgeSessionId, bridgeGeneration?, recoveryId?, reason:"rpc-transport-fault" |
| `app-error` | reason, error |

**task 对象字段**：`taskId, title, remoteSessionId, displayStatus, hasBackgroundWork, workflowActivity, unreadAt, pinned, archived, createdAt, updatedAt`。
**workspace 对象字段**：`workspacePath, workspaceIdentity, remoteSessionId, kind(local/remote), connectionState, lastConnectionError, label`（`workspaceKey` 由桌面端生成，随对象下发）。

## 2. rpc-frame 可靠分帧层（桥内二进制的载体）

桥建立后，任意方向的字节流被切成物理帧，作为 `data` payload 传输：

```json
{
  "zcode_type": "rpc-frame",
  "bridgeSessionId": "...", "bridgeGeneration": 1, "recoveryId": "可选",
  "seq": 1,                // 物理序号，桥内从 1 单调递增（发送方向独立计数）
  "messageSeq": 1,         // 逻辑消息序号，从 1 递增
  "fragmentIndex": 0, "fragmentCount": 1,
  "messageBytes": 1234,    // 完整消息字节数
  "checksum": {"algorithm": "crc32", "value": "<crc32(整条消息) 十进制字符串>"},
  "dataBase64": "<base64(分片)>"
}
```

- ACK 帧：`{zcode_type:"rpc-frame-ack", bridgeSessionId, ..., ackMessageSeq}`（累积确认；收完一条消息后回 ackMessageSeq=该消息序号）。
- 分片大小：二分搜索使 envelope JSON ≤ maxPhysicalFrameBytes（约 512KB，客户端亦受中继单帧上限约束）。
- 接收端校验：seq 严格连续（gap 即致命错误→degrade）、messageSeq 连续、分片数/字节数/crc32 匹配、重复帧幂等。
- 流控：未确认字节 > 1MB 标记 saturated，< 256KB 恢复；重放缓冲 ≤ 8MB / 45s。

## 3. 桥内消息序列化（ZCode 定制 JSON+二进制）

组装后的字节流为值序列，格式：1 字节类型 + 变长值。

| 类型字节 | 值 | 编码 |
|---|---|---|
| 0 | undefined | 无载荷 |
| 1 | string | varint 长度 + UTF-8 字节 |
| 2 | Buffer(Uint8Array) | varint 长度 + 原始字节 |
| 3 | VSBuffer | varint 长度 + 原始字节 |
| 4 | Array | varint 元素数 + 逐元素编码 |
| 5 | Object | varint 长度 + JSON 字符串（Uint8Array 值替换为 `{"__zcode_rpc_nested_uint8array_v1":true,"base64":"..."}`） |
| 6 | Int | varint（LEB128，小端 7 位组） |

varint：LEB128（低 7 位数据 + 最高位续传标志），与 protobuf 一致。

## 4. RPC 通道层（VS Code 风格）

### 4.1 客户端 → 服务端（请求）

`serialize([requestType, requestId, channelName, methodName])` + `serialize(arg)`（arg 通常为 `[参数对象]` 数组）。

requestType：`Promise=100`、`PromiseCancel=101`、`EventListen=102`、`EventDispose=103`。

### 4.2 服务端 → 客户端（响应）

`serialize([responseType, requestId])` + `serialize(data)`。

responseType：`Initialize=200`（连接就绪标志，服务端主动发）、`PromiseSuccess=201`、`PromiseError=202`（data={message,name,stack?}）、`PromiseErrorObj=203`、`EventFire=204`。

客户端须等 `Initialize` 后再发请求（实现时可设 3s 兜底）。

### 4.3 通道名与方法

| 通道 | 用途 | 关键方法 |
|---|---|---|
| `zcode-session` | 会话管理 | initializeWorkspace, getWorkspaceRuntimeIdentity, readWorkspacePresentation, createSession, resumeSession, listSessions, **readSession**, **readSessionMessages**({sessionId, afterMessageId?, limit?})→{messages}, **readSessionEvents**({sessionId, afterSeq?, limit?})→{events}, promoteDeferredDraftSession, closeSession, setModel, setThoughtLevel, setMode, respondProviderRuntimeHeaders |
| `zcode-task` | 任务/快照 | listTasks({workspacePath, workspaceIdentity?}), listTaskList, getTaskMeta, **getTaskSnapshotWithEtag**({taskId, workspacePath, workspaceIdentity?, clientMode?, messageLimit?, ifNoneMatch?})→{snapshot, etag}（命中缓存返回 {snapshot:null}）, getTaskSnapshotBody, getTaskSnapshotToolCallsSlice, getTaskSnapshotRef, renameTask, archiveTask, setTaskPinned, setTaskUnread, closeTask, resumeTask, …；事件 `onDynamicWorkspaceEvent` |
| `zcode-agent` | 代理运行时 | onAgentRuntimeRestarted, getSkillReferenceCatalog, listPlugins, syncAppRuntimePreferences, onDynamicCuaPermissionObservation |
| `broadcast` | 广播事件 | onMessage |
| 其他 | | file, media-preview, system, terminal, setting, credential, window-controller, conversation-share, off-peak-task, skills, mcp-sync, plugins, subagents, commands, hooks, memory, output-style, settings-sync, feedback, repo-wiki, prompt-attachment-transfer … |

`clientMode` 移动端取值：`"web-remote-replayable"`。

**任务快照结构**（`getTaskSnapshotWithEtag` 返回）：`{snapshot:{messages:[{id, role:"user"|"assistant", content, timestamp, syntheticTimeline?...}], meta, history}, etag}`。消息含工具调用等信息时字段可能扩展，渲染时做防御式处理。

## 5. 手机端一次连接的完整时序

```
1. WSS 连接 wss://zcode.z.ai/ws?mid=…
2. auth_init(role=terminal, device_sid) → auth_challenge → auth_response(proof) → auth_ack(pair_status)
   waiting: 桌面未开远程控制 / matched: 配对成功
3. (心跳 pair_status_query 每 10s)
4. data: bootstrap-request → bootstrap-response（工作区+任务列表）
5. 常驻列表页：workspace-list-updated 推送刷新；查看任务 →
   data: workspace-bridge-open {bridgeSessionId, bridgeGeneration:1, workspaceKey, taskId}
   → workspace-bridge-ready {bridge:{...}}
6. 桥内：等 Initialize → zcode-task.getTaskSnapshotWithEtag({taskId, workspacePath, clientMode:"web-remote-replayable"})
   → 渲染快照消息；轮询 ifNoneMatch=etag 增量刷新（也可 readSessionMessages 增量）
7. 退出会话页：EventDispose/关桥；退出 APP：WSS 关闭
```

## 6. 本机实测记录（2026-10-01）

- `probe/probe.mjs` 从本机持久化文件读取 deviceSid+passHash（凭证加密格式见 ZCode 开源仓库 `zai-org/ZCode` 的 credentialService 实现；`deviceSid` 与 `passHash` 属敏感配对凭证，请妥善保管，泄露后应在桌面端执行"重置配对"使其失效）。
- 实测：auth_init → challenge → response → **auth_ack pair_status=waiting**（无 AUTH_FAILED）。当时桌面端远程控制已停止（22:41 后无连接），"waiting" 即凭证被中继接受、等待桌面配对的正常状态。桌面端重新开启后再次运行探针应进入 matched 并能拿到 bootstrap 样例。
- 22:39-22:40 桌面日志显示官方网页客户端用同一持久凭证成功配对过（"dropped buffered outbound payloads" 说明当时处于 paired 且在发送数据）。
