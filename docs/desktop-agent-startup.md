# Desktop Agent persistence and startup

The desktop agent is the machine-side long-running process. It connects to the backend, publishes allowed workspaces, and starts the real `codex app-server` when a mobile turn arrives.

## Local state

The agent creates local files on first launch:

```text
%APPDATA%/codex-mobile-control/agent.config.json
%APPDATA%/codex-mobile-control/agent.state.json
```

`agent.config.json` stores:

- `backendWs`
- `userId`
- `deviceId`
- `deviceName`
- `workspaces`
- `codexMode`

Environment variables still take precedence, so development overrides such as `CMC_WORKSPACES` continue to work.

`agent.state.json` stores the local session to Codex thread mapping. This lets the agent reuse existing Codex threads after the process restarts.

## Windows logon startup

Build once before installing startup:

```powershell
npm run build
npm run startup:install --workspace desktop-agent
```

Uninstall startup:

```powershell
npm run startup:uninstall --workspace desktop-agent
```

The task starts only the desktop agent. In production, the backend should run as an independent server-side service. During local development, start the backend separately with:

```powershell
npm run dev:backend
```

Agent logs are written to:

```text
%LOCALAPPDATA%/codex-mobile-control/logs/desktop-agent.log
```
