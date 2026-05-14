import http from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';
import { ClientRole, EventEnvelope, WorkspaceSummary, createEvent, parseEvent } from './protocol.js';

type Client = {
  id: string;
  role: ClientRole;
  userId: string;
  deviceId?: string;
  socket: WebSocket;
};

type DeviceState = {
  deviceId: string;
  userId: string;
  name: string;
  platform: string;
  status: 'online' | 'offline';
  workspaces: WorkspaceSummary[];
  agent?: Client;
  lastSeenAt: string;
};

const port = Number(process.env.PORT ?? 8787);
const users = new Map<string, Set<Client>>();
const devices = new Map<string, DeviceState>();

const server = http.createServer((request, response) => {
  if (request.url === '/health') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ ok: true }));
    return;
  }

  response.writeHead(404);
  response.end('Not found');
});

const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (socket) => {
  let client: Client | null = null;

  socket.on('message', (data) => {
    const event = parseEvent(data.toString());
    if (!event) {
      send(socket, createEvent('error', { message: 'Invalid event envelope' }));
      return;
    }

    if (event.type === 'client.hello') {
      client = registerClient(socket, event);
      return;
    }

    if (!client) {
      send(socket, createEvent('error', { message: 'client.hello required before other events' }));
      return;
    }

    if (event.type === 'app.ping') {
      send(socket, createEvent('app.pong', {
        ping_id: event.payload.ping_id,
        sent_at_ms: event.payload.sent_at_ms,
      }, { user_id: client.userId }));
      return;
    }

    routeEvent(client, event);
  });

  socket.on('close', () => {
    if (!client) {
      return;
    }

    unregisterClient(client);
  });
});

server.listen(port, () => {
  console.log(`[backend] listening on ws://127.0.0.1:${port}/ws`);
});

function registerClient(socket: WebSocket, event: EventEnvelope): Client {
  const role = event.payload.role === 'agent' ? 'agent' : 'app';
  const userId = String(event.payload.user_id ?? 'usr_demo');
  const deviceId = event.payload.device_id ? String(event.payload.device_id) : undefined;

  const client: Client = {
    id: String(event.payload.client_id ?? `${role}_${Date.now()}`),
    role,
    userId,
    deviceId,
    socket,
  };

  if (!users.has(userId)) {
    users.set(userId, new Set());
  }
  users.get(userId)?.add(client);

  if (role === 'agent' && deviceId) {
    const state: DeviceState = {
      deviceId,
      userId,
      name: String(event.payload.device_name ?? deviceId),
      platform: String(event.payload.platform ?? process.platform),
      status: 'online',
      workspaces: [],
      agent: client,
      lastSeenAt: new Date().toISOString(),
    };
    devices.set(deviceId, state);
    broadcastToApps(userId, createEvent('device.online', publicDevice(state), { user_id: userId, device_id: deviceId }));
  }

  send(socket, createEvent('client.ready', { role, user_id: userId, device_id: deviceId }));
  sendDeviceSnapshot(userId, socket);
  return client;
}

function unregisterClient(client: Client): void {
  users.get(client.userId)?.delete(client);

  if (client.role !== 'agent' || !client.deviceId) {
    return;
  }

  const state = devices.get(client.deviceId);
  if (!state) {
    return;
  }

  state.status = 'offline';
  state.agent = undefined;
  state.lastSeenAt = new Date().toISOString();
  broadcastToApps(client.userId, createEvent('device.offline', publicDevice(state), {
    user_id: client.userId,
    device_id: client.deviceId,
  }));
}

function routeEvent(sender: Client, event: EventEnvelope): void {
  if (sender.role === 'app') {
    routeAppEvent(sender, event);
    return;
  }

  routeAgentEvent(sender, event);
}

function routeAppEvent(sender: Client, event: EventEnvelope): void {
  if (!event.device_id) {
    send(sender.socket, createEvent('error', { message: 'device_id is required' }));
    return;
  }

  const device = devices.get(event.device_id);
  if (!device || device.userId !== sender.userId || !device.agent || device.status !== 'online') {
    send(sender.socket, createEvent('error', { message: 'Target device is not online' }, { device_id: event.device_id }));
    return;
  }

  send(device.agent.socket, event);
}

function routeAgentEvent(sender: Client, event: EventEnvelope): void {
  if (!sender.deviceId) {
    return;
  }

  const device = devices.get(sender.deviceId);
  if (device) {
    device.lastSeenAt = new Date().toISOString();
  }

  if (event.type === 'workspace.list' && device) {
    device.workspaces = Array.isArray(event.payload.workspaces)
      ? (event.payload.workspaces as WorkspaceSummary[])
      : [];
    broadcastToApps(sender.userId, createEvent('workspace.list', {
      device: publicDevice(device),
      workspaces: device.workspaces,
    }, { user_id: sender.userId, device_id: sender.deviceId }));
    return;
  }

  broadcastToApps(sender.userId, event);
}

function sendDeviceSnapshot(userId: string, socket: WebSocket): void {
  const visibleDevices = Array.from(devices.values())
    .filter((device) => device.userId === userId)
    .map(publicDevice);

  send(socket, createEvent('device.snapshot', { devices: visibleDevices }, { user_id: userId }));
}

function publicDevice(device: DeviceState): Record<string, unknown> {
  return {
    device_id: device.deviceId,
    name: device.name,
    platform: device.platform,
    status: device.status,
    workspaces: device.workspaces,
    last_seen_at: device.lastSeenAt,
  };
}

function broadcastToApps(userId: string, event: EventEnvelope): void {
  for (const client of users.get(userId) ?? []) {
    if (client.role === 'app') {
      send(client.socket, event);
    }
  }
}

function send(socket: WebSocket, event: EventEnvelope): void {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(event));
  }
}
