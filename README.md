# Codex Mobile Control

三端 Codex 手机远程控制原型。

```text
mobile_app  Flutter 手机端
backend     Node.js WebSocket 后端
desktop-agent Node.js 电脑端 Agent
docs        产品与技术方案
```

## 本地启动

安装 Node 依赖：

```powershell
npm install
```

启动后端：

```powershell
npm run dev:backend
```

启动电脑端 Agent：

```powershell
$env:CMC_DEVICE_ID="dev_local"
$env:CMC_DEVICE_NAME="Windows Dev Machine"
$env:CMC_WORKSPACES="C:/Users/XYQC/Downloads/codex-mobile-control"
npm run dev:agent
```

默认 Agent 会启动真实 `codex app-server`，并通过 WebSocket 与它通信。开发 UI 或后端路由时可以切到 mock 模式：

```powershell
$env:CMC_CODEX_MODE="mock"
npm run dev:agent
```

启动 Flutter：

```powershell
cd "C:/Users/XYQC/Downloads/codex-mobile-control/mobile_app"
flutter run
```

默认后端 WebSocket 地址为：

```text
ws://127.0.0.1:8787/ws
```

## 当前完成范围

- 后端 WebSocket 连接管理
- App / Agent 角色注册
- 设备在线状态广播
- Workspace 上报
- `turn.start` 路由到 Agent
- Agent 接入真实 `codex app-server`
- Agent 支持 `CMC_CODEX_MODE=mock` 本地模拟
- Codex 流式输出转发到手机端
- Codex 审批请求转成手机端审批卡片
- Flutter 端基础连接、设备列表、工作区列表、聊天输出
- Flutter 端支持审批允许 / 拒绝

## 真实链路验证

后端和 Agent 启动后，可以用 Node 模拟手机端发起一次 turn：

```powershell
node -e "const WebSocket=require('ws'); const ws=new WebSocket('ws://127.0.0.1:8787/ws'); const id=(p)=>p+'_'+Date.now()+'_'+Math.random().toString(16).slice(2); ws.on('open',()=>{ws.send(JSON.stringify({event_id:id('evt'),type:'client.hello',created_at:new Date().toISOString(),user_id:'usr_demo',payload:{role:'app',client_id:'probe_app',user_id:'usr_demo'}})); setTimeout(()=>ws.send(JSON.stringify({event_id:id('evt'),type:'turn.start',created_at:new Date().toISOString(),user_id:'usr_demo',device_id:'dev_local',workspace_id:'wks_1',session_id:'ses_probe',turn_id:'turn_probe',payload:{prompt:'只回复一句：手机远程链路已连接。不要运行命令，不要修改文件。'}})),800);}); ws.on('message',(d)=>{console.log(d.toString()); const s=d.toString(); if(s.includes('turn.completed')||s.includes('turn.failed')) setTimeout(()=>process.exit(0),500);}); setTimeout(()=>process.exit(2),60000);"
```

验证通过时会看到 `turn.delta` 流式输出和 `turn.completed`。
