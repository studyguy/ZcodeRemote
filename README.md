# ZcodeRemote

> 非官方的 [ZCode](https://github.com/zai-org/ZCode) 鸿蒙（HarmonyOS NEXT）伴侣客户端 —— **扫码绑定一次，打开即连**，在手机上实时查看桌面端的对话与任务、远程发消息、审批权限。

> ⚠️ 本项目与 Z.ai 无隶属关系。协议逆向自开源的 ZCode 客户端（Apache-2.0），桌面端版本升级可能导致协议变化，见[故障排查](#-故障排查)。

---

## 📖 这是什么

ZCode 桌面端很强，但人一旦离开电脑就失联：任务跑着不敢走、想追问一句要跑回工位。**ZcodeRemote** 把桌面端的远程控制能力搬到鸿蒙手机上——用桌面端的「移动端远程控制」二维码**扫码绑定一次**，凭证存入系统加密资产库，此后打开 App 即自动连接：任务列表按项目分组实时同步，会话以 Markdown 结构化渲染，你可以随时发消息、中断生成、审批工具权限，甚至切换模型与思考强度。适合需要「离开工位也能盯任务、插一句」的重度 ZCode 用户。

## 🚀 快速开始

**使用（三步绑定）**：

1. 桌面端打开 ZCode 的「移动端远程控制」，出现二维码
2. App 首页点「扫码绑定」（也可截图识别或粘贴二维码链接内容），确认绑定
3. 完成。此后打开 App 自动连接；电脑重启无需重新扫码

> 需要重新扫码的情况：桌面端执行了「重置配对」，或更换绑定的电脑。

**构建（DevEco Studio）**：

1. 打开 `app/` 目录，等待同步（按 API 12+ 编写，高版本 SDK 按提示升级即可）
2. `File → Project Structure → Signing Configs → Automatically generate signature`（需华为开发者账号，个人免费档即可）
3. 手机开启 USB 调试并连接，点 Run ▶；或命令行 `./build-and-install.sh`
4. 产物：`app/entry/build/default/outputs/default/`

也可以用 `./serve-hap.sh` 在局域网内分发 HAP，手机浏览器下载安装。

## ✨ 核心功能

- **一次绑定，永久直连**：扫码凭证存入系统加密资产库（AssetStoreKit），打开即连
- **任务列表**：按项目分组（支持折叠/展开），未归档任务实时同步，独立对话归入「任务」组置底
- **会话查看**：结构化渲染（Markdown、思考过程折叠卡、工具调用卡片），上下文占用进度条，自动跟随最新消息
- **远程交互**：发送消息、停止生成、工具权限审批、用户输入问答（AskUserQuestion / 计划审批）
- **模型切换**：模型 / 思考强度（low/high/max）/ 模式（Build/Plan/Edit/Yolo）在线切换，与桌面端同步
- **日夜间主题**：跟随系统或手动切换

## 📱 兼容性与要求

| 平台 | 状态 |
|---|---|
| HarmonyOS NEXT / 5.x+（API 12+，实测 HarmonyOS 7.0） | ✅ 本仓库的应用 |
| iOS / Android / 桌面 | ❌ 无客户端，但 [`research/protocol.md`](research/protocol.md) 是完整的协议规范，[`probe/test_protocol.js`](probe/test_protocol.js) 是跨平台参考实现（任何有 Node.js 的环境可运行），欢迎按协议移植 |

服务端要求：桌面端 ZCode **3.14.4+**（remote/v4 协议）。协议通过 `wss://<host>/ws` 中继，支持私有化部署（绑定链接的域名即连接端点）。

## 🔒 安全与隐私

- 配对凭证（`hash`）保存在手机**系统加密资产库**（AssetStoreKit），卸载应用即销毁
- 与中继的通信使用 HMAC-SHA256 挑战-应答握手，明文密钥不上传
- 无任何遥测 / 数据采集；所有流量仅经过你选择的中继服务器
- 二维码内容等同凭证：**不要截图外传**；若疑似泄露，在桌面端「重置配对」即可使其立即失效
- App 仅申请 `INTERNET` 与 `CAMERA` 两个权限

## 🔍 故障排查

App 内的错误均带分类标签（如 `[AUTH]`、`[DESKTOP_OFFLINE]`），对照下表处理；深入排查用 `hdc shell "hilog -x | grep ZCRemote"`。

| 现象 / 错误分类 | 原因与处理 |
|---|---|
| 一直「等待桌面端」 | 桌面端远程控制开关未开启，开启后约 10 秒自动配对 |
| `[AUTH]` 凭证被拒绝 | 桌面端执行过「重置配对」，重新扫码绑定 |
| `[DESKTOP_OFFLINE]` | 桌面端暂时离线，恢复后自动重连 |
| `[TIMEOUT]` / 会话页「自动刷新已暂停」 | 桌面端正忙或工作区已关闭；点「重新连接并刷新」 |
| 任务列表缺任务 | 已归档任务不显示；其他窗口的任务需在对应窗口开启远程控制 |
| 上下文分母与模型标称不符 | session 层可能登记的是压缩阈值；可在 `service/ZcodeService.ets` 的 `MODEL_CONTEXT_WINDOW_OVERRIDES` 补充你模型的标称窗口 |

## 🧩 项目结构

| 目录 | 内容 |
|---|---|
| [`app/`](app/) | 鸿蒙 APP（DevEco Studio / ArkTS），构建指南见其 README |
| [`HANDOFF.md`](HANDOFF.md) | 开发/接手文档：当前架构与安全边界、坑清单、验证流程（接手或 AI 工具先读） |
| [`research/`](research/) | 协议逆向成果：完整协议规范（分层帧格式、鉴权、RPC 通道、方法签名） |
| [`probe/`](probe/) | Node 探针与工具：连接测试、快照抓取、协议层单元测试；内含 ZCode 上游代码切片（出处见 [NOTICE.md](NOTICE.md)） |

## 📜 许可与致谢

- 协议逆向自开源的 [zai-org/ZCode](https://github.com/zai-org/ZCode)（Apache-2.0）
- 本项目以 [MIT](LICENSE) 发布；probe 目录中来自上游的代码切片遵循上游协议（见 [NOTICE.md](NOTICE.md)）
