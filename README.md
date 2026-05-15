# Codex Mobile Control

Codex Mobile Control 是一个三端 Codex 手机远程控制原型：手机 App 作为控制台，Backend 作为消息路由层，Desktop Agent 作为电脑端执行器。它的核心目标不是重写 Codex，而是把 OpenAI Codex 本地运行能力安全地延伸到手机端。

本项目的大部分能力设计都参考 OpenAI 官方开源项目 [`openai/codex`](https://github.com/openai/codex)。Codex 官方仓库提供了本地 coding agent、CLI、desktop app 入口和 `codex app-server` 相关实现。本项目的 Desktop Agent 通过启动本机 `codex app-server`，再使用 WebSocket / JSON-RPC 与它通信。

## 架构

```text
Flutter mobile_app
  -> WebSocket
Node.js backend
  -> WebSocket
Node.js desktop-agent
  -> local WebSocket / JSON-RPC
codex app-server
  -> 本机 workspace / shell / git / filesystem
```

三端职责保持清晰：

| 模块 | 技术栈 | 职责 |
|---|---|---|
| `mobile_app` | Flutter / Dart | 设备选择、项目选择、会话控制、流式输出、审批操作 |
| `backend` | Node.js / TypeScript / `ws` | WebSocket 连接管理、设备状态、App 与 Agent 消息路由 |
| `desktop-agent` | Node.js / TypeScript / `ws` | 连接 Backend、上报 workspace、启动并桥接 `codex app-server` |

Backend 不直接执行命令，也不直接访问用户电脑文件系统。真正拥有本机权限的是 Desktop Agent。

## 与 OpenAI Codex 的关系

本项目把 OpenAI Codex 当作底层执行引擎，而不是自己实现一个 coding agent。

当前已使用或准备对齐的 Codex 能力包括：

- 本机 `codex app-server` 启动和 ready 检查。
- WebSocket JSON-RPC 调用。
- `initialize` / `thread/start` / `turn/start` 等会话生命周期。
- 流式输出事件，例如 assistant delta 和 reasoning summary delta。
- Git diff 更新事件。
- 命令执行、文件变更等审批请求。
- Codex 本地状态、session、rollout、workspace 信息读取。

后续加功能时，优先从官方仓库确认协议和实现方式：

```text
https://github.com/openai/codex
```

推荐优先查看这些方向：

- `codex-rs`：核心 agent、协议、turn、approval、sandbox、model 配置。
- `codex-cli`：CLI 参数、配置读取、登录和本地运行方式。
- `docs`：官方文档和用户可见能力说明。
- app / server 相关实现：`codex app-server` 的 WebSocket JSON-RPC 协议。

原则：**不要凭猜测扩展协议字段。先查 OpenAI Codex upstream 支持什么，再把字段映射到本项目的 App -> Backend -> Agent -> Codex 链路。**

## 当前功能

- Flutter App 连接远程 Backend WebSocket。
- Desktop Agent 连接 Backend 并注册为一台设备。
- Agent 上报可控制 workspace。
- App 查看在线设备和项目。
- App 创建或选择 Codex 会话。
- App 发送 `turn.start` 到指定设备。
- Backend 将事件路由到对应 Desktop Agent。
- Agent 启动真实 `codex app-server`。
- Agent 将 Codex 流式输出转发为 `turn.delta`。
- Agent 将 Codex diff 更新转发为 `git.diff.updated`。
- App 可展示输出、完成状态和审批卡片。
- 支持 `CMC_CODEX_MODE=mock` 在不启动真实 Codex 时调试 UI 和路由。

## 本地启动

安装 Node 依赖：

```powershell
npm install
```

启动 Backend：

```powershell
npm run dev:backend
```

启动 Desktop Agent：

```powershell
$env:CMC_DEVICE_ID="dev_local"
$env:CMC_DEVICE_NAME="Windows Dev Machine"
$env:CMC_WORKSPACES="C:/Users/XYQC/Downloads/codex-mobile-control"
npm run dev:agent
```

默认 Agent 会启动真实 `codex app-server`。开发 UI 或后端路由时可以切到 mock 模式：

```powershell
$env:CMC_CODEX_MODE="mock"
npm run dev:agent
```

启动 Flutter App：

```powershell
cd "C:/Users/XYQC/Downloads/codex-mobile-control/mobile_app"
flutter run
```

## 配置

Desktop Agent 支持环境变量和本地配置文件。环境变量优先级更高。

| 配置 | 含义 | 默认值 |
|---|---|---|
| `CMC_BACKEND_WS` | Backend WebSocket 地址 | `ws://127.0.0.1:8787/ws` |
| `CMC_USER_ID` | 当前用户 ID | `usr_demo` |
| `CMC_DEVICE_ID` | 当前设备 ID | 基于主机名生成 |
| `CMC_DEVICE_NAME` | 设备展示名 | 当前主机名 |
| `CMC_WORKSPACES` | 允许控制的 workspace，使用 `;` 分隔 | 空 |
| `CMC_CODEX_MODE` | `real` 或 `mock` | `real` |
| `CMC_CODEX_PORT` | 本机 `codex app-server` 端口 | 从 `8799` 起自动探测 |
| `CMC_CODEX_DEBUG` | 打印 Codex stdout / stderr | 关闭 |

Agent 首次启动会创建：

```text
%APPDATA%/codex-mobile-control/agent.config.json
%APPDATA%/codex-mobile-control/agent.state.json
```

## 通讯协议

App、Backend、Agent 使用统一事件信封：

```json
{
  "event_id": "evt_xxx",
  "type": "turn.start",
  "created_at": "2026-05-14T10:00:00.000Z",
  "user_id": "usr_demo",
  "device_id": "dev_local",
  "workspace_id": "wks_1",
  "session_id": "ses_1",
  "turn_id": "turn_1",
  "payload": {
    "prompt": "检查这个项目的架构"
  }
}
```

常用事件：

| 事件 | 方向 | 含义 |
|---|---|---|
| `client.hello` | App / Agent -> Backend | 注册连接角色 |
| `client.ready` | Backend -> App / Agent | 注册成功 |
| `device.snapshot` | Backend -> App | 当前设备列表 |
| `device.online` | Backend -> App | 设备上线 |
| `device.offline` | Backend -> App | 设备离线 |
| `workspace.list` | Agent -> Backend -> App | workspace 列表 |
| `session.history.request` | App -> Backend -> Agent | 请求会话历史 |
| `session.history` | Agent -> Backend -> App | 返回会话历史 |
| `turn.start` | App -> Backend -> Agent | 开始一轮 Codex 指令 |
| `turn.delta` | Agent -> Backend -> App | Codex 流式输出 |
| `git.diff.updated` | Agent -> Backend -> App | diff 更新 |
| `approval.requested` | Agent -> Backend -> App | Codex 请求审批 |
| `approval.resolved` | App -> Backend -> Agent | 用户审批结果 |
| `turn.completed` | Agent -> Backend -> App | 本轮完成 |
| `turn.failed` | Agent -> Backend -> App | 本轮失败 |

## Codex Bridge

`desktop-agent/src/codexBridge.ts` 是本项目和 OpenAI Codex 的边界层。

它做四件事：

1. 启动 `codex app-server`。
2. 等待 `/readyz` 返回成功。
3. 连接本机 Codex WebSocket。
4. 将本项目事件映射到 Codex JSON-RPC 请求和通知。

当前核心调用：

```text
initialize
thread/start
turn/start
```

当前核心回传：

```text
item/agentMessage/delta -> turn.delta
item/reasoning/summaryTextDelta -> turn.delta
turn/diff/updated -> git.diff.updated
turn/completed -> turn.completed
error -> turn.failed
```

## 如何扩展功能

新增功能时按这条链路扩展：

```text
Flutter UI
  -> EventEnvelope payload
  -> Backend 路由和校验
  -> Desktop Agent 参数校验
  -> CodexBridge 映射到 openai/codex 支持的 JSON-RPC 字段
```

示例：支持模型和推理强度选择。

1. 先去 `openai/codex` 确认 `codex app-server` 当前是否支持 model / reasoning effort 字段，以及字段名称。
2. 在 Flutter App 增加选择控件。
3. 在 `turn.start.payload` 增加受控字段，例如 `model`、`reasoning_effort`。
4. Backend 只做白名单和结构校验，不解释 Codex 私有语义。
5. Desktop Agent 做最终白名单校验。
6. `CodexBridge` 把字段映射给 `thread/start` 或 `turn/start`。
7. 如果 upstream 不支持，返回明确错误，不静默忽略。

示例事件：

```json
{
  "type": "turn.start",
  "payload": {
    "prompt": "重构这个模块",
    "model": "gpt-5.5",
    "reasoning_effort": "high"
  }
}
```

这个字段只是本项目的扩展示例，最终字段名必须以 OpenAI Codex upstream 的实际协议为准。

## 安全边界

当前项目仍是原型，不是生产级远程执行系统。继续产品化前至少需要补齐：

- App 用户鉴权。
- Agent 设备绑定和 device token。
- 生产环境 `wss://`。
- Backend 持久化设备、会话、审批和审计状态。
- 消息签名或至少 token 级别的连接鉴权。
- 危险操作审批闭环。
- workspace 白名单和路径越界校验。
- 结构化日志和敏感信息脱敏。
- Agent 进程生命周期管理。

由于 Desktop Agent 最终可以触发本机 Codex 执行命令、修改文件、读取项目状态，任何远程控制能力都必须默认按高风险能力设计。

## 开发原则

- KISS：保持三端职责简单，Backend 只做路由和状态。
- YAGNI：不提前实现团队、企业、云端执行等能力。
- DRY：事件类型、审批状态、Codex 字段映射保持单一来源。
- SOLID：Codex 适配逻辑集中在 `CodexBridge`，不要散落到 UI 或 Backend。
- Upstream first：涉及 Codex 内部能力时，优先参考 `openai/codex`，再做本项目适配。

## 验证

启动 Backend 和 Agent 后，可以用 Node 模拟手机端发送一轮 turn：

```powershell
node -e "const WebSocket=require('ws'); const ws=new WebSocket('ws://127.0.0.1:8787/ws'); const id=(p)=>p+'_'+Date.now()+'_'+Math.random().toString(16).slice(2); ws.on('open',()=>{ws.send(JSON.stringify({event_id:id('evt'),type:'client.hello',created_at:new Date().toISOString(),user_id:'usr_demo',payload:{role:'app',client_id:'probe_app',user_id:'usr_demo'}})); setTimeout(()=>ws.send(JSON.stringify({event_id:id('evt'),type:'turn.start',created_at:new Date().toISOString(),user_id:'usr_demo',device_id:'dev_local',workspace_id:'wks_1',session_id:'ses_probe',turn_id:'turn_probe',payload:{prompt:'只回复一句：手机远程链路已连接。不要运行命令，不要修改文件。'}})),800);}); ws.on('message',(d)=>{console.log(d.toString()); const s=d.toString(); if(s.includes('turn.completed')||s.includes('turn.failed')) setTimeout(()=>process.exit(0),500);}); setTimeout(()=>process.exit(2),60000);"
```

预期能看到 `turn.delta` 和 `turn.completed`。

## 参考

- OpenAI Codex 官方开源仓库：https://github.com/openai/codex
- 本项目三端方案：`docs/三端落地方案.md`
- Desktop Agent 启动说明：`docs/desktop-agent-startup.md`
