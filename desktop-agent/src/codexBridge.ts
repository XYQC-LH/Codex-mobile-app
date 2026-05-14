import { spawn, type ChildProcessByStdio } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { once } from 'node:events';
import type { Readable } from 'node:stream';
import { WebSocket } from 'ws';

type JsonRpcId = number;

type JsonRpcResponse = {
  id: JsonRpcId;
  result?: unknown;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
};

type JsonRpcRequest = {
  id: JsonRpcId;
  method: string;
  params?: unknown;
};

type JsonRpcNotification = {
  method: string;
  params?: Record<string, unknown>;
};

export type CodexTurnEvent =
  | { type: 'delta'; text: string }
  | { type: 'diff'; diff: string }
  | { type: 'approval'; approvalId: string; actionType: string; riskLevel: string; summary: string }
  | { type: 'completed'; summary: string }
  | { type: 'failed'; message: string };

type ThreadState = {
  threadId: string;
  cwd: string;
};

export class CodexBridge extends EventEmitter {
  private process: ChildProcessByStdio<null, Readable, Readable> | null = null;
  private socket: WebSocket | null = null;
  private nextRequestId = 1;
  private port = 8799;
  private readonly pending = new Map<JsonRpcId, {
    resolve: (value: unknown) => void;
    reject: (error: Error) => void;
  }>();
  private readonly threads = new Map<string, ThreadState>();
  private readonly activeTurns = new Map<string, {
    localSessionId: string;
    localTurnId: string;
    emitEvent: (event: CodexTurnEvent) => void;
  }>();

  async start(): Promise<void> {
    if (this.socket?.readyState === WebSocket.OPEN) {
      return;
    }

    this.port = Number(process.env.CMC_CODEX_PORT ?? await findPort(8799));
    const child = spawn('codex', ['app-server', '--listen', `ws://127.0.0.1:${this.port}`], {
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: process.platform === 'win32',
    });
    this.process = child;

    child.stdout.on('data', (chunk) => {
      const text = chunk.toString();
      if (process.env.CMC_CODEX_DEBUG === '1') {
        process.stdout.write(`[codex] ${text}`);
      }
    });
    child.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      if (process.env.CMC_CODEX_DEBUG === '1') {
        process.stderr.write(`[codex] ${text}`);
      }
    });
    child.on('exit', (code) => {
      this.socket = null;
      this.rejectAll(new Error(`codex app-server exited with code ${code ?? 'unknown'}`));
    });

    await waitForReady(`http://127.0.0.1:${this.port}/readyz`, 10_000);
    await this.connectSocket();
    await this.request('initialize', {
      clientInfo: {
        name: 'codex-mobile-control-agent',
        version: '0.1.0',
      },
    });
    this.sendNotification('initialized');
  }

  async stop(): Promise<void> {
    this.socket?.close();
    this.socket = null;
    this.process?.kill();
    this.process = null;
  }

  async startTurn(params: {
    localSessionId: string;
    localTurnId: string;
    prompt: string;
    cwd: string;
    emitEvent: (event: CodexTurnEvent) => void;
  }): Promise<void> {
    await this.start();
    const thread = await this.getOrCreateThread(params.localSessionId, params.cwd);
    this.activeTurns.set(thread.threadId, {
      localSessionId: params.localSessionId,
      localTurnId: params.localTurnId,
      emitEvent: params.emitEvent,
    });

    try {
      await this.request('turn/start', {
        threadId: thread.threadId,
        cwd: params.cwd,
        approvalPolicy: 'on-request',
        approvalsReviewer: 'user',
        input: [{
          type: 'text',
          text: params.prompt,
          text_elements: [],
        }],
      });
    } catch (error) {
      this.activeTurns.delete(thread.threadId);
      params.emitEvent({
        type: 'failed',
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  resolveApproval(approvalId: string, approved: boolean): void {
    const requestId = Number(approvalId);
    if (!Number.isFinite(requestId)) {
      return;
    }

    this.sendResponse(requestId, {
      decision: approved ? 'accept' : 'decline',
    });
  }

  private async getOrCreateThread(localSessionId: string, cwd: string): Promise<ThreadState> {
    const existing = this.threads.get(localSessionId);
    if (existing) {
      return existing;
    }

    const response = await this.request('thread/start', {
      cwd,
      approvalPolicy: 'on-request',
      approvalsReviewer: 'user',
      sandbox: 'workspace-write',
      ephemeral: false,
      serviceName: 'codex-mobile-control',
      sessionStartSource: 'startup',
      threadSource: 'user',
    }) as Record<string, unknown>;

    const thread = response.thread as { id?: string } | undefined;
    if (!thread?.id) {
      throw new Error('codex thread/start returned no thread id');
    }

    const state = { threadId: thread.id, cwd };
    this.threads.set(localSessionId, state);
    return state;
  }

  private async connectSocket(): Promise<void> {
    const socket = new WebSocket(`ws://127.0.0.1:${this.port}`);
    this.socket = socket;

    socket.on('message', (data) => this.handleMessage(data.toString()));
    socket.on('close', () => {
      this.socket = null;
    });
    socket.on('error', (error) => {
      this.emit('error', error);
    });

    await once(socket, 'open');
  }

  private handleMessage(raw: string): void {
    let message: JsonRpcResponse | JsonRpcNotification;
    try {
      message = JSON.parse(raw) as JsonRpcResponse | JsonRpcNotification;
    } catch {
      return;
    }

    if ('id' in message && ('result' in message || 'error' in message)) {
      this.handleResponse(message);
      return;
    }

    if ('method' in message) {
      this.handleNotification(message);
    }
  }

  private handleResponse(message: JsonRpcResponse): void {
    const pending = this.pending.get(message.id);
    if (!pending) {
      return;
    }

    this.pending.delete(message.id);
    if (message.error) {
      pending.reject(new Error(message.error.message));
      return;
    }

    pending.resolve(message.result);
  }

  private handleNotification(message: JsonRpcNotification): void {
    const params = message.params ?? {};
    const threadId = typeof params.threadId === 'string' ? params.threadId : undefined;
    const active = threadId ? this.activeTurns.get(threadId) : undefined;

    if (message.method === 'item/agentMessage/delta' && active) {
      active.emitEvent({ type: 'delta', text: String(params.delta ?? '') });
      return;
    }

    if (message.method === 'item/reasoning/summaryTextDelta' && active) {
      active.emitEvent({ type: 'delta', text: String(params.delta ?? '') });
      return;
    }

    if (message.method === 'turn/diff/updated' && active) {
      active.emitEvent({ type: 'diff', diff: String(params.diff ?? '') });
      return;
    }

    if (message.method === 'turn/completed' && active) {
      const turn = params.turn as { status?: string; error?: { message?: string } | null } | undefined;
      this.activeTurns.delete(threadId!);
      if (turn?.status === 'failed') {
        active.emitEvent({ type: 'failed', message: turn.error?.message ?? 'Codex turn failed' });
        return;
      }
      active.emitEvent({ type: 'completed', summary: 'Codex turn completed.' });
      return;
    }

    if (message.method === 'error' && active) {
      const error = params.error as { message?: string } | undefined;
      active.emitEvent({ type: 'failed', message: error?.message ?? 'Codex error' });
      return;
    }
  }

  private handleServerRequest(message: JsonRpcRequest): void {
    const params = (message.params ?? {}) as Record<string, unknown>;
    const threadId = typeof params.threadId === 'string' ? params.threadId : undefined;
    const active = threadId ? this.activeTurns.get(threadId) : undefined;

    if (!active) {
      this.sendResponse(message.id, { decision: 'decline' });
      return;
    }

    if (message.method === 'item/commandExecution/requestApproval') {
      active.emitEvent({
        type: 'approval',
        approvalId: String(message.id),
        actionType: 'command.execution',
        riskLevel: 'high',
        summary: String(params.command ?? params.reason ?? 'Codex requests command execution approval.'),
      });
      return;
    }

    if (message.method === 'item/fileChange/requestApproval') {
      active.emitEvent({
        type: 'approval',
        approvalId: String(message.id),
        actionType: 'file.change',
        riskLevel: 'high',
        summary: String(params.reason ?? params.grantRoot ?? 'Codex requests file change approval.'),
      });
      return;
    }

    this.sendResponse(message.id, { decision: 'decline' });
  }

  private request(method: string, params?: unknown): Promise<unknown> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error('codex app-server socket is not open'));
    }

    const id = this.nextRequestId++;
    const payload: JsonRpcRequest = { id, method, params };
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      socket.send(JSON.stringify(payload));
    });
  }

  private sendNotification(method: string, params?: unknown): void {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify({ method, params }));
    }
  }

  private sendResponse(id: number, result: unknown): void {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify({ id, result }));
    }
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
  }
}

async function waitForReady(url: string, timeoutMs: number): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
    } catch {
      // app-server is still starting.
    }
    await wait(200);
  }
  throw new Error(`Timed out waiting for codex app-server at ${url}`);
}

async function findPort(start: number): Promise<number> {
  for (let port = start; port < start + 50; port += 1) {
    if (await isPortFree(port)) {
      return port;
    }
  }
  throw new Error('No free port found for codex app-server');
}

function isPortFree(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const tester = new WebSocket(`ws://127.0.0.1:${port}`);
    const done = (free: boolean) => {
      tester.removeAllListeners();
      tester.close();
      resolve(free);
    };
    tester.once('open', () => done(false));
    tester.once('error', () => done(true));
  });
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
