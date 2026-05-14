import os from 'node:os';
import path from 'node:path';
import { WebSocket } from 'ws';
import { CodexBridge, type CodexTurnEvent } from './codexBridge.js';
import { EventEnvelope, createEvent, parseEvent } from './protocol.js';

type Workspace = {
  workspace_id: string;
  name: string;
  path_hint: string;
  absolute_path: string;
};

const backendUrl = process.env.CMC_BACKEND_WS ?? 'ws://127.0.0.1:8787/ws';
const userId = process.env.CMC_USER_ID ?? 'usr_demo';
const deviceId = process.env.CMC_DEVICE_ID ?? `dev_${os.hostname().replace(/[^a-zA-Z0-9_-]/g, '_')}`;
const deviceName = process.env.CMC_DEVICE_NAME ?? os.hostname();
const workspaces = loadWorkspaces();
const codexMode = process.env.CMC_CODEX_MODE ?? 'real';
const codexBridge = new CodexBridge();

let socket: WebSocket | null = null;
let reconnectTimer: NodeJS.Timeout | null = null;

connect();

function connect(): void {
  socket = new WebSocket(backendUrl);

  socket.on('open', () => {
    console.log(`[agent] connected to ${backendUrl}`);
    send(createEvent('client.hello', {
      role: 'agent',
      client_id: `agent_${deviceId}`,
      user_id: userId,
      device_id: deviceId,
      device_name: deviceName,
      platform: process.platform,
    }, { user_id: userId, device_id: deviceId }));
    publishWorkspaces();
  });

  socket.on('message', (data) => {
    const event = parseEvent(data.toString());
    if (!event) {
      return;
    }
    handleEvent(event);
  });

  socket.on('close', () => {
    console.log('[agent] disconnected');
    scheduleReconnect();
  });

  socket.on('error', (error) => {
    console.error(`[agent] websocket error: ${error.message}`);
  });
}

function scheduleReconnect(): void {
  if (reconnectTimer) {
    return;
  }

  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, 1500);
}

function handleEvent(event: EventEnvelope): void {
  if (event.type === 'client.ready') {
    console.log('[agent] registered');
    return;
  }

  if (event.type === 'session.create') {
    send(createEvent('session.ready', {
      message: 'Session is ready on desktop agent.',
    }, inheritIds(event)));
    return;
  }

  if (event.type === 'turn.start') {
    void handleTurn(event);
    return;
  }

  if (event.type === 'approval.resolved') {
    const approvalId = String(event.payload.approval_id ?? '');
    codexBridge.resolveApproval(approvalId, event.payload.decision === 'approved');
  }
}

async function handleTurn(event: EventEnvelope): Promise<void> {
  const prompt = String(event.payload.prompt ?? '').trim();
  const ids = inheritIds(event);
  const workspace = resolveWorkspace(event.workspace_id);

  if (!workspace) {
    send(createEvent('turn.failed', {
      summary: 'Workspace is not allowed on this device.',
    }, ids));
    return;
  }

  if (codexMode !== 'mock') {
    try {
      await codexBridge.startTurn({
        localSessionId: event.session_id ?? `session_${workspace.workspace_id}`,
        localTurnId: event.turn_id ?? `turn_${Date.now()}`,
        prompt,
        cwd: workspace.absolute_path,
        emitEvent: (codexEvent) => forwardCodexEvent(codexEvent, ids),
      });
    } catch (error) {
      send(createEvent('turn.failed', {
        summary: error instanceof Error ? error.message : String(error),
      }, ids));
    }
    return;
  }

  const lines = [
    `收到手机端指令：${prompt || '(空指令)'}`,
    '当前 Agent 使用 CMC_CODEX_MODE=mock，未连接真实 codex app-server。',
    `目标工作区：${resolveWorkspaceName(event.workspace_id)}`,
    '任务链路已跑通：App -> Backend -> Desktop Agent -> Backend -> App。',
  ];

  for (const line of lines) {
    await wait(450);
    send(createEvent('turn.delta', { text: `${line}\n` }, ids));
  }

  if (prompt.includes('删除') || prompt.toLowerCase().includes('delete')) {
    send(createEvent('approval.requested', {
      approval_id: `apv_${Date.now()}`,
      action_type: 'filesystem.delete',
      risk_level: 'high',
      summary: '检测到删除意图。真实执行前必须在手机端审批。',
    }, ids));
    return;
  }

  await wait(350);
  send(createEvent('turn.completed', {
    summary: '模拟任务已完成。',
  }, ids));
}

function forwardCodexEvent(
  codexEvent: CodexTurnEvent,
  ids: Omit<EventEnvelope, 'event_id' | 'type' | 'created_at' | 'payload'>,
): void {
  if (codexEvent.type === 'delta') {
    send(createEvent('turn.delta', { text: codexEvent.text }, ids));
    return;
  }

  if (codexEvent.type === 'diff') {
    send(createEvent('git.diff.updated', { diff: codexEvent.diff }, ids));
    return;
  }

  if (codexEvent.type === 'approval') {
    send(createEvent('approval.requested', {
      approval_id: codexEvent.approvalId,
      action_type: codexEvent.actionType,
      risk_level: codexEvent.riskLevel,
      summary: codexEvent.summary,
    }, ids));
    return;
  }

  if (codexEvent.type === 'failed') {
    send(createEvent('turn.failed', { summary: codexEvent.message }, ids));
    return;
  }

  send(createEvent('turn.completed', { summary: codexEvent.summary }, ids));
}

function publishWorkspaces(): void {
  send(createEvent('workspace.list', {
    workspaces: workspaces.map(({ workspace_id, name, path_hint }) => ({
      workspace_id,
      name,
      path_hint,
    })),
  }, { user_id: userId, device_id: deviceId }));
}

function loadWorkspaces(): Workspace[] {
  const raw = process.env.CMC_WORKSPACES ?? process.cwd();
  return raw.split(';')
    .map((item) => item.trim())
    .filter(Boolean)
    .map((absolutePath, index) => ({
      workspace_id: `wks_${index + 1}`,
      name: path.basename(absolutePath) || absolutePath,
      path_hint: abbreviatePath(absolutePath),
      absolute_path: absolutePath,
    }));
}

function abbreviatePath(value: string): string {
  const normalized = value.replace(/\\/g, '/');
  const parts = normalized.split('/').filter(Boolean);
  return parts.length <= 3 ? normalized : `.../${parts.slice(-3).join('/')}`;
}

function resolveWorkspaceName(workspaceId?: string): string {
  if (!workspaceId) {
    return workspaces[0]?.name ?? '未指定';
  }
  return workspaces.find((workspace) => workspace.workspace_id === workspaceId)?.name ?? workspaceId;
}

function resolveWorkspace(workspaceId?: string): Workspace | undefined {
  if (!workspaceId) {
    return workspaces[0];
  }
  return workspaces.find((workspace) => workspace.workspace_id === workspaceId);
}

function inheritIds(event: EventEnvelope): Omit<EventEnvelope, 'event_id' | 'type' | 'created_at' | 'payload'> {
  return {
    user_id: event.user_id ?? userId,
    device_id: event.device_id ?? deviceId,
    workspace_id: event.workspace_id,
    session_id: event.session_id,
    turn_id: event.turn_id,
  };
}

function send(event: EventEnvelope): void {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(event));
  }
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
