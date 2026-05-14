import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { WebSocket } from 'ws';
import { loadAgentConfig } from './agentConfig.js';
import { CodexBridge, type CodexTurnEvent } from './codexBridge.js';
import { EventEnvelope, WorkspaceSummary, createEvent, parseEvent } from './protocol.js';

type Workspace = {
  workspace_id: string;
  name: string;
  path_hint: string;
  absolute_path: string;
};

type CodexSessionIndexEntry = {
  id?: string;
  thread_name?: string;
  updated_at?: string;
};

type CodexSessionSummary = {
  session_id: string;
  title: string;
  updated_at?: string;
  cwd?: string;
};

type CodexThreadRow = {
  id?: string;
  cwd?: string;
  title?: string;
  updated_at?: number;
  rollout_path?: string;
};

type SessionHistoryMessage = {
  role: 'user' | 'assistant';
  text: string;
  timestamp?: string;
};

const agentConfig = loadAgentConfig();
const backendUrl = agentConfig.backendWs;
const userId = agentConfig.userId;
const deviceId = agentConfig.deviceId;
const deviceName = agentConfig.deviceName;
const workspaces = loadWorkspaces();
const codexMode = agentConfig.codexMode;
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

  if (event.type === 'session.history.request') {
    handleSessionHistoryRequest(event);
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

function handleSessionHistoryRequest(event: EventEnvelope): void {
  const sessionId = event.session_id ?? String(event.payload.session_id ?? '');
  const history = sessionId ? loadSessionHistory(sessionId) : [];
  send(createEvent('session.history', {
    session_id: sessionId,
    messages: history,
  }, inheritIds(event)));
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
  const sessionsByWorkspace = loadCodexSessionsByWorkspace();
  console.log(
    `[agent] publishing ${workspaces.length} workspaces, ` +
    `${Array.from(sessionsByWorkspace.values()).reduce((count, sessions) => count + sessions.length, 0)} sessions`,
  );
  send(createEvent('workspace.list', {
    workspaces: workspaces.map(({ workspace_id, name, path_hint }) => ({
      workspace_id,
      name,
      path_hint,
      sessions: sessionsByWorkspace.get(workspace_id) ?? [],
    } satisfies WorkspaceSummary)),
  }, { user_id: userId, device_id: deviceId }));
}

function loadWorkspaces(): Workspace[] {
  const codexRoots = loadCodexWorkspaceRoots();
  const roots = [...agentConfig.workspaces, ...codexRoots, process.cwd()];

  return uniqueNormalizedPaths(roots)
    .map((item) => item.trim())
    .filter(Boolean)
    .map((absolutePath, index) => ({
      workspace_id: createWorkspaceId(absolutePath, index),
      name: path.basename(absolutePath) || absolutePath,
      path_hint: abbreviatePath(absolutePath),
      absolute_path: absolutePath,
    }));
}

function loadCodexWorkspaceRoots(): string[] {
  const statePath = path.join(getCodexHome(), '.codex-global-state.json');
  try {
    const state = JSON.parse(fs.readFileSync(statePath, 'utf8')) as {
      'electron-saved-workspace-roots'?: unknown;
      'active-workspace-roots'?: unknown;
    };
    return [
      ...readStringArray(state['active-workspace-roots']),
      ...readStringArray(state['electron-saved-workspace-roots']),
    ];
  } catch {
    return [];
  }
}

function loadCodexSessionsByWorkspace(): Map<string, CodexSessionSummary[]> {
  const sqliteSessions = loadCodexSessionsFromStateDb();
  if (sqliteSessions.size > 0) {
    return sqliteSessions;
  }

  const sessionIndex = loadCodexSessionIndex();
  const cwdBySessionId = scanCodexSessionCwds(sessionIndex.flatMap((entry) => entry.id ? [entry.id] : []));
  const workspaceByPath = new Map(workspaces.map((workspace) => [normalizePath(workspace.absolute_path), workspace]));
  const result = new Map<string, CodexSessionSummary[]>();

  for (const entry of sessionIndex) {
    if (!entry.id) {
      continue;
    }

    const cwd = cwdBySessionId.get(entry.id);
    const workspace = cwd ? workspaceByPath.get(normalizePath(cwd)) : undefined;
    if (!workspace) {
      continue;
    }

    const sessions = result.get(workspace.workspace_id) ?? [];
    sessions.push({
      session_id: entry.id,
      title: entry.thread_name?.trim() || '未命名会话',
      updated_at: entry.updated_at,
      cwd,
    });
    result.set(workspace.workspace_id, sessions);
  }

  for (const [workspaceId, sessions] of result) {
    result.set(
      workspaceId,
      sessions
        .sort((left, right) => String(right.updated_at ?? '').localeCompare(String(left.updated_at ?? '')))
        .slice(0, 20),
    );
  }

  return result;
}

function loadCodexSessionsFromStateDb(): Map<string, CodexSessionSummary[]> {
  const dbPath = path.join(getCodexHome(), 'state_5.sqlite');
  if (!fs.existsSync(dbPath)) {
    return new Map();
  }

  const workspaceByPath = new Map(workspaces.map((workspace) => [normalizePath(workspace.absolute_path), workspace]));
  const result = new Map<string, CodexSessionSummary[]>();

  let rows: CodexThreadRow[];
  try {
    const workspacePaths = Array.from(workspaceByPath.keys());
    if (workspacePaths.length === 0) {
      return new Map();
    }

    const pathList = workspacePaths.map((item) => sqlStringLiteral(item)).join(',');
    const output = execFileSync('sqlite3', [
      '-json',
      dbPath,
      `
        select id, cwd, title, updated_at
        from threads
        where archived = 0
          and lower(replace(replace(cwd, '\\\\?\\', ''), '\\', '/')) in (${pathList})
        order by updated_at desc
        limit 500;
      `,
    ], { encoding: 'utf8', maxBuffer: 1024 * 1024 * 4, windowsHide: true });
    rows = JSON.parse(output) as CodexThreadRow[];
  } catch (error) {
    console.warn(`[agent] failed to read Codex state database: ${error instanceof Error ? error.message : String(error)}`);
    return new Map();
  }

  for (const row of rows) {
    if (!row.id || !row.cwd) {
      continue;
    }

    const workspace = workspaceByPath.get(normalizePath(row.cwd));
    if (!workspace) {
      continue;
    }

    const sessions = result.get(workspace.workspace_id) ?? [];
    if (sessions.length >= 20) {
      continue;
    }

    sessions.push({
      session_id: row.id,
      title: row.title?.trim() || '未命名会话',
      updated_at: typeof row.updated_at === 'number'
        ? new Date(row.updated_at * 1000).toISOString()
        : undefined,
      cwd: row.cwd,
    });
    result.set(workspace.workspace_id, sessions);
  }

  return result;
}

function loadSessionHistory(sessionId: string): SessionHistoryMessage[] {
  const rolloutPath = findRolloutPathForSession(sessionId);
  if (!rolloutPath) {
    return [];
  }

  const messages: SessionHistoryMessage[] = [];
  let lines: string[];
  try {
    lines = fs.readFileSync(rolloutPath, 'utf8').split(/\r?\n/);
  } catch {
    return [];
  }

  for (const line of lines) {
    if (!line.trim()) {
      continue;
    }

    try {
      const item = JSON.parse(line) as {
        timestamp?: string;
        type?: string;
        payload?: Record<string, unknown>;
      };
      const message = extractHistoryMessage(item);
      if (message) {
        messages.push(message);
      }
    } catch {
      continue;
    }
  }

  return messages.slice(-40);
}

function findRolloutPathForSession(sessionId: string): string | undefined {
  const dbPath = path.join(getCodexHome(), 'state_5.sqlite');
  if (fs.existsSync(dbPath)) {
    try {
      const output = execFileSync('sqlite3', [
        '-json',
        dbPath,
        `select rollout_path from threads where id = ${sqlStringLiteral(sessionId)} limit 1;`,
      ], { encoding: 'utf8', maxBuffer: 1024 * 128, windowsHide: true });
      const rows = JSON.parse(output) as Array<{ rollout_path?: string }>;
      const rolloutPath = rows[0]?.rollout_path;
      if (rolloutPath) {
        return normalizeFilePath(rolloutPath);
      }
    } catch {
      // Fall through to filesystem scan.
    }
  }

  const sessionsDir = path.join(getCodexHome(), 'sessions');
  const stack = [sessionsDir];
  while (stack.length > 0) {
    const current = stack.pop()!;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (entry.name.includes(sessionId) && entry.name.endsWith('.jsonl')) {
        return fullPath;
      }
    }
  }

  return undefined;
}

function extractHistoryMessage(item: {
  timestamp?: string;
  type?: string;
  payload?: Record<string, unknown>;
}): SessionHistoryMessage | undefined {
  if (item.type === 'event_msg' && item.payload?.type === 'user_message') {
    const text = String(item.payload.message ?? '').trim();
    return text ? { role: 'user', text, timestamp: item.timestamp } : undefined;
  }

  if (item.type !== 'response_item') {
    return undefined;
  }

  if (item.payload?.type === 'message') {
    const role = item.payload.role === 'user' ? 'user' : 'assistant';
    const text = extractContentText(item.payload.content);
    return text ? { role, text, timestamp: item.timestamp } : undefined;
  }

  if (item.payload?.type === 'reasoning') {
    return undefined;
  }

  return undefined;
}

function extractContentText(value: unknown): string {
  if (typeof value === 'string') {
    return value.trim();
  }

  if (!Array.isArray(value)) {
    return '';
  }

  return value
    .map((entry) => {
      if (!entry || typeof entry !== 'object') {
        return '';
      }
      const record = entry as Record<string, unknown>;
      return typeof record.text === 'string' ? record.text : '';
    })
    .filter(Boolean)
    .join('\n')
    .trim();
}

function loadCodexSessionIndex(): CodexSessionIndexEntry[] {
  const indexPath = path.join(getCodexHome(), 'session_index.jsonl');
  try {
    return fs.readFileSync(indexPath, 'utf8')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => JSON.parse(line) as CodexSessionIndexEntry);
  } catch {
    return [];
  }
}

function scanCodexSessionCwds(sessionIds: string[]): Map<string, string> {
  const wanted = new Set(sessionIds);
  const result = new Map<string, string>();
  const sessionsDir = path.join(getCodexHome(), 'sessions');
  const stack = [sessionsDir];

  while (stack.length > 0 && result.size < wanted.size) {
    const current = stack.pop()!;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }

      if (!entry.name.endsWith('.jsonl')) {
        continue;
      }

      const sessionId = Array.from(wanted).find((id) => !result.has(id) && entry.name.includes(id));
      if (!sessionId) {
        continue;
      }

      const firstLine = readFirstLine(fullPath);
      if (!firstLine) {
        continue;
      }

      try {
        const value = JSON.parse(firstLine) as { type?: string; payload?: { cwd?: string } };
        if (value.type === 'session_meta' && typeof value.payload?.cwd === 'string') {
          result.set(sessionId, value.payload.cwd);
        }
      } catch {
        continue;
      }
    }
  }

  return result;
}

function readFirstLine(filePath: string): string | undefined {
  try {
    const fd = fs.openSync(filePath, 'r');
    try {
      const buffer = Buffer.alloc(8192);
      const bytesRead = fs.readSync(fd, buffer, 0, buffer.length, 0);
      const text = buffer.subarray(0, bytesRead).toString('utf8');
      return text.split(/\r?\n/, 1)[0];
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return undefined;
  }
}

function sqlStringLiteral(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function getCodexHome(): string {
  return process.env.CODEX_HOME ?? path.join(os.homedir(), '.codex');
}

function readStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];
}

function uniqueNormalizedPaths(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];

  for (const value of values) {
    const trimmed = value.trim();
    if (!trimmed) {
      continue;
    }

    const normalized = normalizePath(trimmed);
    if (seen.has(normalized)) {
      continue;
    }

    seen.add(normalized);
    result.push(trimmed);
  }

  return result;
}

function createWorkspaceId(absolutePath: string, index: number): string {
  return `wks_${index + 1}_${Buffer.from(normalizePath(absolutePath)).toString('base64url').slice(0, 10)}`;
}

function abbreviatePath(value: string): string {
  const normalized = value.replace(/\\/g, '/');
  const parts = normalized.split('/').filter(Boolean);
  return parts.length <= 3 ? normalized : `.../${parts.slice(-3).join('/')}`;
}

function normalizePath(value: string): string {
  let withoutExtendedPrefix = value;
  const uncPrefix = '\\\\?\\UNC\\';
  const localPrefix = '\\\\?\\';

  if (withoutExtendedPrefix.toLowerCase().startsWith(uncPrefix.toLowerCase())) {
    withoutExtendedPrefix = `\\\\${withoutExtendedPrefix.slice(uncPrefix.length)}`;
  } else if (withoutExtendedPrefix.startsWith(localPrefix)) {
    withoutExtendedPrefix = withoutExtendedPrefix.slice(localPrefix.length);
  }

  return path.resolve(withoutExtendedPrefix).replace(/\\/g, '/').toLowerCase();
}

function normalizeFilePath(value: string): string {
  let withoutExtendedPrefix = value;
  const uncPrefix = '\\\\?\\UNC\\';
  const localPrefix = '\\\\?\\';

  if (withoutExtendedPrefix.toLowerCase().startsWith(uncPrefix.toLowerCase())) {
    withoutExtendedPrefix = `\\\\${withoutExtendedPrefix.slice(uncPrefix.length)}`;
  } else if (withoutExtendedPrefix.startsWith(localPrefix)) {
    withoutExtendedPrefix = withoutExtendedPrefix.slice(localPrefix.length);
  }

  return withoutExtendedPrefix;
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
