import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export type AgentConfig = {
  backendWs: string;
  userId: string;
  deviceId: string;
  deviceName: string;
  workspaces: string[];
  codexMode: string;
};

export type AgentThreadState = {
  threadId: string;
  cwd: string;
  updatedAt: string;
};

export type AgentState = {
  threads: Record<string, AgentThreadState>;
};

const appName = 'codex-mobile-control';

export function getAgentDataDir(): string {
  const baseDir = process.env.APPDATA ?? path.join(os.homedir(), '.config');
  return path.join(baseDir, appName);
}

export function getAgentConfigPath(): string {
  return path.join(getAgentDataDir(), 'agent.config.json');
}

export function getAgentStatePath(): string {
  return path.join(getAgentDataDir(), 'agent.state.json');
}

export function loadAgentConfig(): AgentConfig {
  const stored = readJson<Record<string, unknown>>(getAgentConfigPath()) ?? {};
  const deviceId = readString(process.env.CMC_DEVICE_ID)
    ?? readString(stored.deviceId)
    ?? `dev_${os.hostname().replace(/[^a-zA-Z0-9_-]/g, '_')}`;

  const config: AgentConfig = {
    backendWs: readString(process.env.CMC_BACKEND_WS)
      ?? readString(stored.backendWs)
      ?? 'ws://127.0.0.1:8787/ws',
    userId: readString(process.env.CMC_USER_ID)
      ?? readString(stored.userId)
      ?? 'usr_demo',
    deviceId,
    deviceName: readString(process.env.CMC_DEVICE_NAME)
      ?? readString(stored.deviceName)
      ?? os.hostname(),
    workspaces: readWorkspaceList(process.env.CMC_WORKSPACES)
      ?? readStringArray(stored.workspaces),
    codexMode: readString(process.env.CMC_CODEX_MODE)
      ?? readString(stored.codexMode)
      ?? 'real',
  };

  writeDefaultConfig(config);
  return config;
}

export function loadAgentState(): AgentState {
  const stored = readJson<Partial<AgentState>>(getAgentStatePath());
  return {
    threads: stored?.threads && typeof stored.threads === 'object' ? stored.threads : {},
  };
}

export function saveAgentState(state: AgentState): void {
  writeJson(getAgentStatePath(), state);
}

function writeDefaultConfig(config: AgentConfig): void {
  if (fs.existsSync(getAgentConfigPath())) {
    return;
  }

  writeJson(getAgentConfigPath(), config);
}

function readJson<T>(filePath: string): T | undefined {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8')) as T;
  } catch {
    return undefined;
  }
}

function writeJson(filePath: string, value: unknown): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function readString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

function readStringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === 'string' && Boolean(item.trim()))
    : [];
}

function readWorkspaceList(value: unknown): string[] | undefined {
  const text = readString(value);
  if (!text) {
    return undefined;
  }

  return text.split(';').map((item) => item.trim()).filter(Boolean);
}
