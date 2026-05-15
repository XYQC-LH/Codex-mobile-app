import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String _backendWebSocketUrl = 'ws://103.143.81.22:8787/ws';
const String _backendHealthUrl = 'http://103.143.81.22:8787/health';
const String _uiStateStorageKey = 'codex_mobile_control.ui_state';

void main() {
  runApp(const CodexMobileControlApp());
}

class CodexMobileControlApp extends StatelessWidget {
  const CodexMobileControlApp({super.key, this.autoConnect = true});

  final bool autoConnect;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Codex Control',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: ControlHomePage(autoConnect: autoConnect),
    );
  }
}

enum _HomeStep { devices, projects, console }

typedef SessionSelectionCallback =
    void Function(String workspaceId, String sessionId);

enum ConsoleLogRole { user, assistant, system }

class ConsoleLogEntry {
  const ConsoleLogEntry({required this.role, required this.text});

  final ConsoleLogRole role;
  final String text;

  Map<String, dynamic> toJson() {
    return {
      'role': role.name,
      'text': text,
    };
  }

  factory ConsoleLogEntry.fromJson(Map<String, dynamic> json) {
    return ConsoleLogEntry(
      role: ConsoleLogRole.values.firstWhere(
        (item) => item.name == json['role']?.toString(),
        orElse: () => ConsoleLogRole.system,
      ),
      text: json['text']?.toString() ?? '',
    );
  }
}

class ControlHomePage extends StatefulWidget {
  const ControlHomePage({super.key, this.autoConnect = true});

  final bool autoConnect;

  @override
  State<ControlHomePage> createState() => _ControlHomePageState();
}

class _ControlHomePageState extends State<ControlHomePage>
    with WidgetsBindingObserver {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _latencyTimer;
  Timer? _refreshTimer;
  _HomeStep _step = _HomeStep.devices;
  bool _restoringState = true;
  bool _connected = false;
  bool _connecting = false;
  int? _latencyMs;
  bool _loadingHistory = false;
  String? _selectedDeviceId;
  String? _selectedWorkspaceId;
  String? _selectedSessionId;
  final Set<String> _expandedWorkspaceIds = <String>{};
  final List<DeviceInfo> _devices = <DeviceInfo>[];
  final List<ConsoleLogEntry> _logs = <ConsoleLogEntry>[];
  ApprovalRequest? _pendingApproval;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreUiState());
    if (widget.autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startAutoRefresh();
        unawaited(_connect(silent: true));
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _latencyTimer?.cancel();
    _refreshTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startAutoRefresh();
      _refreshConnection();
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _refreshTimer?.cancel();
      _latencyTimer?.cancel();
      _schedulePersistUiState();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedDevice = _selectedDevice;
    final selectedWorkspace = _selectedWorkspace;
    final selectedSession = _selectedSession;

    return PopScope(
      canPop: _step == _HomeStep.devices,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step != _HomeStep.devices) {
          _goBack();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        leading: _step == _HomeStep.devices
            ? null
            : IconButton(
                onPressed: _goBack,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
              ),
        title: Text(_titleForStep),
        actions: [
          _ServerStatusBadge(
            connected: _connected,
            connecting: _connecting,
            latencyMs: _latencyMs,
          ),
          IconButton(
            onPressed: _connecting ? null : _connect,
            icon: const Icon(Icons.refresh),
            tooltip: '重新连接',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: switch (_step) {
          _HomeStep.devices => _DeviceSelectionPage(
            connected: _connected,
            connecting: _connecting,
            devices: _devices,
            onReconnect: _connect,
            onDeviceSelected: _openDevice,
          ),
          _HomeStep.projects => _ProjectSelectionPage(
            device: selectedDevice,
            expandedWorkspaceIds: _expandedWorkspaceIds,
            selectedWorkspaceId: _selectedWorkspaceId,
            selectedSessionId: _selectedSessionId,
            onWorkspaceToggled: _toggleWorkspaceExpanded,
            onCreateSession: _createSessionForWorkspace,
            onSessionSelected: _openSession,
          ),
          _HomeStep.console => _ConsolePage(
            device: selectedDevice,
            workspace: selectedWorkspace,
            session: selectedSession,
            logs: _logs,
            loadingHistory: _loadingHistory,
            pendingApproval: _pendingApproval,
            promptController: _promptController,
            scrollController: _scrollController,
            canSend: _canSend,
            onSend: _sendTurn,
            onPromptChanged: () => setState(() {}),
            onApprove: () => _resolveApproval(true),
            onDeny: () => _resolveApproval(false),
          ),
        },
      ),
      ),
    );
  }

  String get _titleForStep {
    return switch (_step) {
      _HomeStep.devices => '选择设备',
      _HomeStep.projects => '选择项目',
      _HomeStep.console => '会话控制',
    };
  }

  Future<void> _restoreUiState() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_uiStateStorageKey);
    if (raw == null || raw.isEmpty) {
      if (mounted) {
        setState(() => _restoringState = false);
      }
      return;
    }

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final stepName = json['step']?.toString();
      final logs = json['logs'];
      if (!mounted) {
        return;
      }

      setState(() {
        _step = _HomeStep.values.firstWhere(
          (item) =>
              item.name == stepName ||
              (stepName == 'sessions' && item == _HomeStep.projects),
          orElse: () => _HomeStep.devices,
        );
        _selectedDeviceId = json['selectedDeviceId']?.toString();
        _selectedWorkspaceId = json['selectedWorkspaceId']?.toString();
        _selectedSessionId = json['selectedSessionId']?.toString();
        final expandedWorkspaceIds = json['expandedWorkspaceIds'];
        _expandedWorkspaceIds
          ..clear()
          ..addAll(expandedWorkspaceIds is List
              ? expandedWorkspaceIds
                    .map((item) => item.toString())
                    .where((item) => item.isNotEmpty)
              : const <String>[]);
        _logs
          ..clear()
          ..addAll(logs is List
              ? logs
                  .whereType<Map>()
                  .map((item) => ConsoleLogEntry.fromJson(
                        item.cast<String, dynamic>(),
                      ))
                  .where((item) => item.text.trim().isNotEmpty)
              : const <ConsoleLogEntry>[]);
        _loadingHistory = false;
        _restoringState = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _restoringState = false);
      }
    }
  }

  Future<void> _persistUiState() async {
    if (_restoringState) {
      return;
    }

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _uiStateStorageKey,
      jsonEncode({
        'step': _step.name,
        'selectedDeviceId': _selectedDeviceId,
        'selectedWorkspaceId': _selectedWorkspaceId,
        'selectedSessionId': _selectedSessionId,
        'expandedWorkspaceIds': _expandedWorkspaceIds.toList(),
        'logs': _logs.take(80).map((item) => item.toJson()).toList(),
      }),
    );
  }

  void _schedulePersistUiState() {
    unawaited(_persistUiState());
  }

  DeviceInfo? get _selectedDevice {
    return _devices.where((item) => item.deviceId == _selectedDeviceId).firstOrNull;
  }

  WorkspaceInfo? get _selectedWorkspace {
    return _selectedDevice?.workspaces
        .where((item) => item.workspaceId == _selectedWorkspaceId)
        .firstOrNull;
  }

  SessionInfo? get _selectedSession {
    return _selectedWorkspace?.sessions
        .where((item) => item.sessionId == _selectedSessionId)
        .firstOrNull;
  }

  bool get _canSend {
    return _connected &&
        _selectedDeviceId != null &&
        _selectedWorkspaceId != null &&
        _selectedSessionId != null &&
        _promptController.text.trim().isNotEmpty;
  }

  Future<void> _connect({bool silent = false}) async {
    if (_connecting) {
      return;
    }

    _disconnect(updateState: false);
    if (!silent) {
      _appendLog('正在连接服务器...', role: ConsoleLogRole.system);
    }
    final channel = WebSocketChannel.connect(Uri.parse(_backendWebSocketUrl));
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleRawMessage,
      onDone: () {
        _latencyTimer?.cancel();
        if (mounted) {
          setState(() {
            _connected = false;
            _connecting = false;
            _latencyMs = null;
          });
        }
      },
      onError: (Object error) {
        if (!silent) {
          _appendLog('连接错误：$error', role: ConsoleLogRole.system);
        }
        _latencyTimer?.cancel();
        if (mounted) {
          setState(() {
            _connected = false;
            _connecting = false;
            _latencyMs = null;
          });
        }
      },
    );

    setState(() {
      _connected = false;
      _connecting = true;
      _latencyMs = null;
    });

    try {
      await channel.ready.timeout(const Duration(seconds: 8));
      if (!silent) {
        _appendLog('服务器已连接，正在注册 App...', role: ConsoleLogRole.system);
      }
      _send(
        EventEnvelope(
          type: 'client.hello',
          payload: {
            'role': 'app',
            'client_id': 'app_flutter_demo',
            'user_id': 'usr_demo',
          },
        ),
      );
    } catch (error) {
      if (!silent) {
        _appendLog('连接失败：$error', role: ConsoleLogRole.system);
      }
      _disconnect();
    }
  }

  void _disconnect({bool updateState = true}) {
    _latencyTimer?.cancel();
    _latencyTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    if (mounted && updateState) {
      setState(() {
        _connected = false;
        _connecting = false;
        _latencyMs = null;
      });
    }
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshConnection(),
    );
  }

  void _refreshConnection() {
    if (_connecting) {
      return;
    }

    if (!_connected) {
      unawaited(_connect(silent: true));
      return;
    }
  }

  void _startLatencyProbe() {
    _latencyTimer?.cancel();
    unawaited(_measureLatency());
    _latencyTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_measureLatency()),
    );
  }

  Future<void> _measureLatency() async {
    if (!_connected) {
      return;
    }

    final stopwatch = Stopwatch()..start();
    try {
      final request = await HttpClient()
          .getUrl(Uri.parse(_backendHealthUrl))
          .timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));
      await response.drain<void>();
      if (mounted) {
        setState(() => _latencyMs = stopwatch.elapsedMilliseconds);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _latencyMs = null);
      }
    } finally {
      stopwatch.stop();
    }
  }

  void _goBack() {
    setState(() {
      _step = switch (_step) {
        _HomeStep.projects => _HomeStep.devices,
        _HomeStep.console => _HomeStep.projects,
        _HomeStep.devices => _HomeStep.devices,
      };
    });
    _schedulePersistUiState();
  }

  void _openDevice(String deviceId) {
    setState(() {
      _selectedDeviceId = deviceId;
      _selectedWorkspaceId = null;
      _selectedSessionId = null;
      _step = _HomeStep.projects;
    });
    _schedulePersistUiState();
  }

  void _toggleWorkspaceExpanded(String workspaceId) {
    setState(() {
      _selectedWorkspaceId = workspaceId;
      if (_expandedWorkspaceIds.contains(workspaceId)) {
        _expandedWorkspaceIds.remove(workspaceId);
      } else {
        _expandedWorkspaceIds.add(workspaceId);
      }
    });
    _schedulePersistUiState();
  }

  void _openSession(String workspaceId, String sessionId) {
    setState(() {
      _selectedWorkspaceId = workspaceId;
      _selectedSessionId = sessionId;
      _expandedWorkspaceIds.add(workspaceId);
      _step = _HomeStep.console;
      _logs
        ..clear()
        ..add(const ConsoleLogEntry(
          role: ConsoleLogRole.system,
          text: '正在加载历史对话...',
        ));
      _loadingHistory = true;
    });
    _scrollToBottom(jump: true);
    _schedulePersistUiState();
    _requestSessionHistory(sessionId);
  }

  void _createSessionForWorkspace(String workspaceId) {
    final sessionId = _newId('ses');
    setState(() {
      _selectedWorkspaceId = workspaceId;
      _selectedSessionId = sessionId;
      _expandedWorkspaceIds.add(workspaceId);
      _step = _HomeStep.console;
      _logs.clear();
      _loadingHistory = false;
    });
    _appendLog('已为当前项目创建新会话。', role: ConsoleLogRole.system);
    _schedulePersistUiState();
  }

  void _requestSessionHistory(String sessionId) {
    if (_selectedDeviceId == null || _selectedWorkspaceId == null) {
      return;
    }

    _send(
      EventEnvelope(
        type: 'session.history.request',
        deviceId: _selectedDeviceId,
        workspaceId: _selectedWorkspaceId,
        sessionId: sessionId,
        payload: {'session_id': sessionId},
      ),
    );
  }

  void _sendTurn() {
    final prompt = _promptController.text.trim();
    if (!_canSend) {
      return;
    }

    final turnId = _newId('turn');
    _appendLog(prompt, role: ConsoleLogRole.user);
    _send(
      EventEnvelope(
        type: 'turn.start',
        deviceId: _selectedDeviceId,
        workspaceId: _selectedWorkspaceId,
        sessionId: _selectedSessionId,
        turnId: turnId,
        payload: {'prompt': prompt},
      ),
    );
    _promptController.clear();
    setState(() {});
    _schedulePersistUiState();
  }

  void _handleRawMessage(dynamic raw) {
    final data = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = data['type'] as String;
    final payload =
        (data['payload'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    switch (type) {
      case 'client.ready':
        setState(() {
          _connected = true;
          _connecting = false;
        });
        _startLatencyProbe();
      case 'device.snapshot':
        _replaceDevices(payload['devices']);
      case 'device.online':
      case 'device.offline':
        _upsertDevice(DeviceInfo.fromJson(payload));
      case 'workspace.list':
        final device = payload['device'];
        if (device is Map) {
          _upsertDevice(DeviceInfo.fromJson(device.cast<String, dynamic>()));
        }
      case 'session.history':
        _replaceSessionHistory(payload);
      case 'session.status':
        _applySessionStatus(data, payload);
      case 'turn.delta':
        _appendAssistantDelta('${payload['text'] ?? ''}');
      case 'approval.requested':
        setState(() => _pendingApproval = ApprovalRequest.fromJson(payload));
        _appendLog('审批请求：${payload['summary'] ?? '需要审批'}');
      case 'turn.completed':
        _appendLog('完成：${payload['summary'] ?? 'turn completed'}');
      case 'turn.failed':
        _appendLog('失败：${payload['summary'] ?? 'turn failed'}');
      case 'error':
        if (payload['message']?.toString() == 'device_id is required') {
          return;
        }
        _appendLog('错误：${payload['message'] ?? 'unknown error'}');
      default:
        _appendLog('事件 $type');
    }
  }

  void _replaceSessionHistory(Map<String, dynamic> payload) {
    final rawMessages = payload['messages'];
    if (rawMessages is! List) {
      setState(() => _loadingHistory = false);
      return;
    }

    final entries = rawMessages
        .whereType<Map>()
        .map((item) {
          final role = item['role']?.toString() == 'user'
              ? ConsoleLogRole.user
              : ConsoleLogRole.assistant;
          final text = item['text']?.toString().trim() ?? '';
          return text.isEmpty ? null : ConsoleLogEntry(role: role, text: text);
        })
        .whereType<ConsoleLogEntry>()
        .toList();

    setState(() {
      _logs
        ..clear()
        ..addAll(entries.isEmpty
            ? const [
                ConsoleLogEntry(
                  role: ConsoleLogRole.system,
                  text: '这个历史会话没有可展示的对话内容。',
                ),
              ]
            : entries);
      _loadingHistory = false;
    });
    _scrollToBottom(jump: true);
    _schedulePersistUiState();
  }

  void _replaceDevices(dynamic value) {
    if (value is! List) {
      return;
    }

    setState(() {
      _devices
        ..clear()
        ..addAll(
          value.whereType<Map>().map(
            (item) => DeviceInfo.fromJson(item.cast<String, dynamic>()),
          ),
        );

      _expandRunningWorkspaces();
      _reconcileSelectedContext();
    });
    _schedulePersistUiState();
  }

  void _upsertDevice(DeviceInfo device) {
    setState(() {
      final index = _devices.indexWhere(
        (item) => item.deviceId == device.deviceId,
      );
      if (index >= 0) {
        _devices[index] = device;
      } else {
        _devices.add(device);
      }
      _expandRunningWorkspaces();
      _reconcileSelectedContext();
    });
    _schedulePersistUiState();
  }

  void _applySessionStatus(
    Map<String, dynamic> envelope,
    Map<String, dynamic> payload,
  ) {
    final deviceId = envelope['device_id']?.toString();
    final workspaceId = envelope['workspace_id']?.toString();
    final sessionId = envelope['session_id']?.toString();
    if (deviceId == null || workspaceId == null || sessionId == null) {
      return;
    }

    final status = SessionRuntimeStatus.fromWire(payload['status']);
    final runningTurnId = payload['turn_id']?.toString() ??
        envelope['turn_id']?.toString();
    final lastStatusAt = payload['updated_at']?.toString() ??
        envelope['created_at']?.toString();

    setState(() {
      final deviceIndex = _devices.indexWhere(
        (item) => item.deviceId == deviceId,
      );
      if (deviceIndex < 0) {
        return;
      }

      _devices[deviceIndex] = _devices[deviceIndex].copyWithSessionStatus(
        workspaceId: workspaceId,
        sessionId: sessionId,
        status: status,
        runningTurnId: status == SessionRuntimeStatus.running
            ? runningTurnId
            : null,
        lastStatusAt: lastStatusAt,
      );
      _expandRunningWorkspaces();
    });
    _schedulePersistUiState();
  }

  void _send(EventEnvelope event) {
    _channel?.sink.add(jsonEncode(event.toJson()));
  }

  void _resolveApproval(bool approved) {
    final request = _pendingApproval;
    if (request == null || _selectedDeviceId == null) {
      return;
    }

    _send(
      EventEnvelope(
        type: 'approval.resolved',
        deviceId: _selectedDeviceId,
        workspaceId: _selectedWorkspaceId,
        sessionId: _selectedSessionId,
        payload: {
          'approval_id': request.approvalId,
          'decision': approved ? 'approved' : 'denied',
        },
      ),
    );
    _appendLog('${approved ? '已允许' : '已拒绝'}：${request.summary}');
    setState(() => _pendingApproval = null);
    _schedulePersistUiState();
  }

  void _appendLog(
    String line, {
    ConsoleLogRole role = ConsoleLogRole.system,
  }) {
    final text = line.trimRight();
    if (text.isEmpty) {
      return;
    }

    setState(() {
      if (_isDuplicateLastLog(role, text)) {
        return;
      }

      _logs.add(ConsoleLogEntry(role: role, text: text));
    });
    _scrollToBottom();
    _schedulePersistUiState();
  }

  void _appendAssistantDelta(String text) {
    if (text.isEmpty) {
      return;
    }

    setState(() {
      final lastIndex = _logs.length - 1;
      if (lastIndex >= 0 && _logs[lastIndex].role == ConsoleLogRole.assistant) {
        final previous = _logs[lastIndex].text;
        _logs[lastIndex] = ConsoleLogEntry(
          role: ConsoleLogRole.assistant,
          text: '$previous$text'.trimRight(),
        );
      } else {
        _logs.add(ConsoleLogEntry(
          role: ConsoleLogRole.assistant,
          text: text.trimRight(),
        ));
      }
    });
    _scrollToBottom();
    _schedulePersistUiState();
  }

  void _reconcileSelectedContext() {
    final selectedDevice = _selectedDevice;
    if (_selectedDeviceId != null && selectedDevice == null) {
      return;
    }

    final selectedWorkspace = _selectedWorkspace;
    if (_selectedWorkspaceId != null && selectedWorkspace == null) {
      _selectedWorkspaceId = null;
      _selectedSessionId = null;
      if (_step.index > _HomeStep.projects.index) {
        _step = _HomeStep.projects;
      }
      return;
    }

    if (_selectedSessionId != null &&
        selectedWorkspace != null &&
        !_selectedWorkspaceHasSession(_selectedSessionId!)) {
      return;
    }
  }

  bool _selectedWorkspaceHasSession(String sessionId) {
    return _selectedWorkspace?.sessions
            .any((item) => item.sessionId == sessionId) ??
        false;
  }

  void _expandRunningWorkspaces() {
    for (final device in _devices) {
      for (final workspace in device.workspaces) {
        if (workspace.runningSessionCount > 0) {
          _expandedWorkspaceIds.add(workspace.workspaceId);
        }
      }
    }
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final target = _scrollController.position.maxScrollExtent;
        if (jump) {
          _scrollController.jumpTo(target);
        } else {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  bool _isDuplicateLastLog(ConsoleLogRole role, String text) {
    if (_logs.isEmpty) {
      return false;
    }

    final previous = _logs.last;
    return previous.role == role &&
        _normalizeLogText(previous.text) == _normalizeLogText(text);
  }

  String _normalizeLogText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

class _ServerStatusBadge extends StatelessWidget {
  const _ServerStatusBadge({
    required this.connected,
    required this.connecting,
    required this.latencyMs,
  });

  final bool connected;
  final bool connecting;
  final int? latencyMs;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color background;
    final Color foreground;
    final IconData icon;
    final String status;

    if (connected) {
      background = const Color(0xFFE5F7ED);
      foreground = const Color(0xFF138A4B);
      icon = Icons.cloud_done_outlined;
      status = '服务器';
    } else if (connecting) {
      background = const Color(0xFFFFF2D6);
      foreground = const Color(0xFFA05A00);
      icon = Icons.cloud_sync_outlined;
      status = '连接中';
    } else {
      background = colorScheme.errorContainer.withValues(alpha: 0.45);
      foreground = colorScheme.error;
      icon = Icons.cloud_off_outlined;
      status = '离线';
    }

    return Container(
      constraints: const BoxConstraints(minWidth: 88),
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: foreground.withValues(alpha: 0.22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: foreground),
              const SizedBox(width: 4),
              Text(
                status,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          Text(
            connected && latencyMs != null ? '${latencyMs}ms' : '--',
            style: TextStyle(
              color: foreground.withValues(alpha: 0.86),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceSelectionPage extends StatelessWidget {
  const _DeviceSelectionPage({
    required this.connected,
    required this.connecting,
    required this.devices,
    required this.onReconnect,
    required this.onDeviceSelected,
  });

  final bool connected;
  final bool connecting;
  final List<DeviceInfo> devices;
  final VoidCallback onReconnect;
  final ValueChanged<String> onDeviceSelected;

  @override
  Widget build(BuildContext context) {
    if (connecting) {
      return const _EmptyState(
        icon: Icons.cloud_sync_outlined,
        title: '正在连接服务器',
        subtitle: '连接成功后会自动读取在线电脑 Agent。',
      );
    }

    if (!connected) {
      return _EmptyState(
        icon: Icons.cloud_off_outlined,
        title: '服务器未连接',
        subtitle: '请确认手机网络可以访问远程 WebSocket。',
        action: FilledButton.icon(
          onPressed: onReconnect,
          icon: const Icon(Icons.refresh),
          label: const Text('重新连接'),
        ),
      );
    }

    if (devices.isEmpty) {
      return const _EmptyState(
        icon: Icons.computer_outlined,
        title: '等待电脑 Agent 上线',
        subtitle: '电脑端 Agent 连接后，这里会显示可控制的设备。',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final device = devices[index];
        return _InfoCard(
          onTap: () => onDeviceSelected(device.deviceId),
          title: device.name,
          subtitle: '${device.deviceId} · ${device.platform}',
          trailing: _StatusPill(
            label: device.status == 'online' ? '在线' : '离线',
            positive: device.status == 'online',
          ),
          chips: [
            '${device.workspaces.length} 个项目',
            '${device.sessionCount} 个会话',
            '最后同步 ${device.lastSeenLabel}',
          ],
        );
      },
    );
  }
}

class _ProjectSelectionPage extends StatelessWidget {
  const _ProjectSelectionPage({
    required this.device,
    required this.expandedWorkspaceIds,
    required this.selectedWorkspaceId,
    required this.selectedSessionId,
    required this.onWorkspaceToggled,
    required this.onCreateSession,
    required this.onSessionSelected,
  });

  final DeviceInfo? device;
  final Set<String> expandedWorkspaceIds;
  final String? selectedWorkspaceId;
  final String? selectedSessionId;
  final ValueChanged<String> onWorkspaceToggled;
  final ValueChanged<String> onCreateSession;
  final SessionSelectionCallback onSessionSelected;

  @override
  Widget build(BuildContext context) {
    final workspaces = device?.workspaces ?? <WorkspaceInfo>[];

    if (device == null) {
      return const _EmptyState(
        icon: Icons.computer_outlined,
        title: '未选择设备',
        subtitle: '请返回设备页重新选择。',
      );
    }

    if (workspaces.isEmpty) {
      return _EmptyState(
        icon: Icons.folder_off_outlined,
        title: '暂无项目',
        subtitle: '${device!.name} 还没有上报可控制的 Codex 项目。',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: workspaces.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _ContextHeader(
            title: device!.name,
            subtitle: '选择这台设备上的 Codex 项目',
          );
        }

        final workspace = workspaces[index - 1];
        final isExpanded = expandedWorkspaceIds.contains(workspace.workspaceId);
        return _WorkspaceDrawerCard(
          workspace: workspace,
          expanded: isExpanded,
          selected: workspace.workspaceId == selectedWorkspaceId,
          selectedSessionId: selectedSessionId,
          onToggle: () => onWorkspaceToggled(workspace.workspaceId),
          onCreateSession: () => onCreateSession(workspace.workspaceId),
          onSessionSelected: (sessionId) => onSessionSelected(
            workspace.workspaceId,
            sessionId,
          ),
        );
      },
    );
  }
}

class _ConsolePage extends StatelessWidget {
  const _ConsolePage({
    required this.device,
    required this.workspace,
    required this.session,
    required this.logs,
    required this.loadingHistory,
    required this.pendingApproval,
    required this.promptController,
    required this.scrollController,
    required this.canSend,
    required this.onSend,
    required this.onPromptChanged,
    required this.onApprove,
    required this.onDeny,
  });

  final DeviceInfo? device;
  final WorkspaceInfo? workspace;
  final SessionInfo? session;
  final List<ConsoleLogEntry> logs;
  final bool loadingHistory;
  final ApprovalRequest? pendingApproval;
  final TextEditingController promptController;
  final ScrollController scrollController;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onPromptChanged;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    if (device == null || workspace == null) {
      return const _EmptyState(
        icon: Icons.forum_outlined,
        title: '未选择会话',
        subtitle: '请返回项目页重新选择。',
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: _ContextHeader(
            title: workspace!.name,
            subtitle: session?.isRunning == true
                ? '${session?.title ?? '新建会话'} · 运行中'
                : session?.title ?? '新建会话 · ${device!.name}',
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: loadingHistory
                ? const Center(child: CircularProgressIndicator())
                : logs.isEmpty
                ? const _EmptyPanel(
                    icon: Icons.terminal_outlined,
                    title: '等待指令',
                    subtitle: '发送后会在这里显示 Codex 响应、工具状态和执行结果。',
                  )
                : ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: logs.length,
                    itemBuilder: (context, index) =>
                        _ConsoleBubble(entry: logs[index]),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pendingApproval != null) ...[
                _ApprovalCard(
                  request: pendingApproval!,
                  onApprove: onApprove,
                  onDeny: onDeny,
                ),
                const SizedBox(height: 12),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: promptController,
                      minLines: 1,
                      maxLines: 4,
                      onChanged: (_) => onPromptChanged(),
                      decoration: const InputDecoration(
                        labelText: '给当前 Codex 会话发指令',
                        hintText: '输入任务',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: canSend ? onSend : null,
                    child: const Icon(Icons.send),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConsoleBubble extends StatelessWidget {
  const _ConsoleBubble({required this.entry});

  final ConsoleLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = entry.role == ConsoleLogRole.user;
    final isSystem = entry.role == ConsoleLogRole.system;

    if (isSystem) {
      return Align(
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            entry.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.74,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isUser ? colorScheme.primary : colorScheme.surface,
            border: Border.all(
              color: isUser
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(8),
              topRight: const Radius.circular(8),
              bottomLeft: Radius.circular(isUser ? 8 : 2),
              bottomRight: Radius.circular(isUser ? 2 : 8),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isUser ? '你' : 'Codex',
                style: TextStyle(
                  color: isUser
                      ? colorScheme.onPrimary.withValues(alpha: 0.72)
                      : colorScheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                entry.text,
                style: TextStyle(
                  color: isUser ? colorScheme.onPrimary : colorScheme.onSurface,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextHeader extends StatelessWidget {
  const _ContextHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.onTap,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.chips = const [],
  });

  final VoidCallback onTap;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 10),
                    trailing!,
                  ],
                ],
              ),
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: chips.map((label) => _SmallChip(label)).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceDrawerCard extends StatelessWidget {
  const _WorkspaceDrawerCard({
    required this.workspace,
    required this.expanded,
    required this.selected,
    required this.selectedSessionId,
    required this.onToggle,
    required this.onCreateSession,
    required this.onSessionSelected,
  });

  final WorkspaceInfo workspace;
  final bool expanded;
  final bool selected;
  final String? selectedSessionId;
  final VoidCallback onToggle;
  final VoidCallback onCreateSession;
  final ValueChanged<String> onSessionSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.35)
                : colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                workspace.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                workspace.pathHint,
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _WorkspaceStatusIndicator(workspace: workspace),
                            const SizedBox(height: 10),
                            Icon(
                              expanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        _SmallChip('${workspace.sessions.length} 个历史会话'),
                        if (workspace.runningSessionCount > 0)
                          _SmallChip('${workspace.runningSessionCount} 个运行中'),
                        _SmallChip(expanded ? '点击收起' : '点击展开'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) ...[
              Divider(
                height: 1,
                color: colorScheme.outlineVariant.withValues(alpha: 0.9),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: onCreateSession,
                        icon: const Icon(Icons.add_comment_outlined, size: 18),
                        label: const Text('新建会话'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (workspace.sessions.isEmpty)
                      const _EmptyPanel(
                        icon: Icons.forum_outlined,
                        title: '暂无历史会话',
                        subtitle: '可以直接在这个项目下新建一个会话。',
                      )
                    else
                      ...workspace.sessions.map(
                        (session) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _SessionDrawerTile(
                            session: session,
                            selected:
                                session.sessionId == selectedSessionId,
                            onTap: () => onSessionSelected(session.sessionId),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SessionDrawerTile extends StatelessWidget {
  const _SessionDrawerTile({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final SessionInfo session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: 0.38)
          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      session.updatedAtLabel == null
                          ? '历史会话'
                          : '最近更新 ${session.updatedAtLabel}',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _SessionStatusIndicator(session: session, selected: selected),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionStatusIndicator extends StatelessWidget {
  const _SessionStatusIndicator({required this.session, required this.selected});

  final SessionInfo session;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    if (session.isRunning) {
      return const _RunningPill();
    }

    if (session.status == SessionRuntimeStatus.failed) {
      return const _StatusPill(label: '失败', positive: false);
    }

    return _StatusPill(label: selected ? '当前' : '可续写', positive: true);
  }
}

class _WorkspaceStatusIndicator extends StatelessWidget {
  const _WorkspaceStatusIndicator({required this.workspace});

  final WorkspaceInfo workspace;

  @override
  Widget build(BuildContext context) {
    if (workspace.runningSessionCount > 0) {
      return _RunningPill(
        label: workspace.runningSessionCount == 1
            ? '1 个运行中'
            : '${workspace.runningSessionCount} 个运行中',
      );
    }

    if (workspace.failedSessionCount > 0) {
      return _StatusPill(
        label: workspace.failedSessionCount == 1
            ? '1 个失败'
            : '${workspace.failedSessionCount} 个失败',
        positive: false,
      );
    }

    return const SizedBox.shrink();
  }
}

class _RunningPill extends StatelessWidget {
  const _RunningPill({this.label = '运行中'});

  final String label;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xFF1D4ED8);
    const background = Color(0xFFEFF6FF);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: foreground,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallChip extends StatelessWidget {
  const _SmallChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.positive});

  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final Color foreground = positive
        ? const Color(0xFF138A4B)
        : const Color(0xFFA05A00);
    final Color background = positive
        ? const Color(0xFFE5F7ED)
        : const Color(0xFFFFF2D6);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colorScheme.primary),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.request,
    required this.onApprove,
    required this.onDeny,
  });

  final ApprovalRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.28),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${request.actionType} · ${request.riskLevel}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(request.summary),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: onDeny,
                icon: const Icon(Icons.close),
                label: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: onApprove,
                icon: const Icon(Icons.check),
                label: const Text('允许'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class EventEnvelope {
  EventEnvelope({
    required this.type,
    required this.payload,
    this.deviceId,
    this.workspaceId,
    this.sessionId,
    this.turnId,
  });

  final String type;
  final Map<String, dynamic> payload;
  final String? deviceId;
  final String? workspaceId;
  final String? sessionId;
  final String? turnId;

  Map<String, dynamic> toJson() {
    return {
      'event_id': _newId('evt'),
      'type': type,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'user_id': 'usr_demo',
      if (deviceId != null) 'device_id': deviceId,
      if (workspaceId != null) 'workspace_id': workspaceId,
      if (sessionId != null) 'session_id': sessionId,
      if (turnId != null) 'turn_id': turnId,
      'payload': payload,
    };
  }
}

class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.status,
    required this.workspaces,
    this.lastSeenAt,
  });

  final String deviceId;
  final String name;
  final String platform;
  final String status;
  final List<WorkspaceInfo> workspaces;
  final String? lastSeenAt;

  int get sessionCount {
    return workspaces.fold<int>(
      0,
      (count, workspace) => count + workspace.sessions.length,
    );
  }

  String get lastSeenLabel {
    return _formatTimestamp(lastSeenAt) ?? '--';
  }

  DeviceInfo copyWithSessionStatus({
    required String workspaceId,
    required String sessionId,
    required SessionRuntimeStatus status,
    String? runningTurnId,
    String? lastStatusAt,
  }) {
    return DeviceInfo(
      deviceId: deviceId,
      name: name,
      platform: platform,
      status: this.status,
      workspaces: workspaces.map((workspace) {
        if (workspace.workspaceId != workspaceId) {
          return workspace;
        }

        return workspace.copyWithSessionStatus(
          sessionId: sessionId,
          status: status,
          runningTurnId: runningTurnId,
          lastStatusAt: lastStatusAt,
        );
      }).toList(),
      lastSeenAt: lastSeenAt,
    );
  }

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final rawWorkspaces = json['workspaces'];
    return DeviceInfo(
      deviceId: json['device_id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Unknown device',
      platform: json['platform']?.toString() ?? 'unknown',
      status: json['status']?.toString() ?? 'offline',
      lastSeenAt: json['last_seen_at']?.toString(),
      workspaces: rawWorkspaces is List
          ? rawWorkspaces
                .whereType<Map>()
                .map(
                  (item) =>
                      WorkspaceInfo.fromJson(item.cast<String, dynamic>()),
                )
                .toList()
          : <WorkspaceInfo>[],
    );
  }
}

class WorkspaceInfo {
  const WorkspaceInfo({
    required this.workspaceId,
    required this.name,
    required this.pathHint,
    required this.sessions,
  });

  final String workspaceId;
  final String name;
  final String pathHint;
  final List<SessionInfo> sessions;

  int get runningSessionCount {
    return sessions.where((session) => session.isRunning).length;
  }

  int get failedSessionCount {
    return sessions
        .where((session) => session.status == SessionRuntimeStatus.failed)
        .length;
  }

  WorkspaceInfo copyWithSessionStatus({
    required String sessionId,
    required SessionRuntimeStatus status,
    String? runningTurnId,
    String? lastStatusAt,
  }) {
    var found = false;
    final updatedSessions = sessions.map((session) {
      if (session.sessionId != sessionId) {
        return session;
      }

      found = true;
      return session.copyWithStatus(
        status: status,
        runningTurnId: runningTurnId,
        lastStatusAt: lastStatusAt,
      );
    }).toList();

    if (!found) {
      updatedSessions.insert(
        0,
        SessionInfo(
          sessionId: sessionId,
          title: '新建会话',
          status: status,
          runningTurnId: runningTurnId,
          lastStatusAt: lastStatusAt,
        ),
      );
    }

    return WorkspaceInfo(
      workspaceId: workspaceId,
      name: name,
      pathHint: pathHint,
      sessions: updatedSessions,
    );
  }

  factory WorkspaceInfo.fromJson(Map<String, dynamic> json) {
    final rawSessions = json['sessions'];
    return WorkspaceInfo(
      workspaceId: json['workspace_id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Workspace',
      pathHint: json['path_hint']?.toString() ?? '',
      sessions: rawSessions is List
          ? rawSessions
                .whereType<Map>()
                .map(
                  (item) => SessionInfo.fromJson(item.cast<String, dynamic>()),
                )
                .toList()
          : <SessionInfo>[],
    );
  }
}

class SessionInfo {
  const SessionInfo({
    required this.sessionId,
    required this.title,
    this.updatedAt,
    this.status = SessionRuntimeStatus.idle,
    this.runningTurnId,
    this.lastStatusAt,
  });

  final String sessionId;
  final String title;
  final String? updatedAt;
  final SessionRuntimeStatus status;
  final String? runningTurnId;
  final String? lastStatusAt;

  String? get updatedAtLabel => _formatTimestamp(updatedAt);
  bool get isRunning => status == SessionRuntimeStatus.running;

  SessionInfo copyWithStatus({
    required SessionRuntimeStatus status,
    String? runningTurnId,
    String? lastStatusAt,
  }) {
    return SessionInfo(
      sessionId: sessionId,
      title: title,
      updatedAt: updatedAt,
      status: status,
      runningTurnId: runningTurnId,
      lastStatusAt: lastStatusAt,
    );
  }

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      sessionId: json['session_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名会话',
      updatedAt: json['updated_at']?.toString(),
      status: SessionRuntimeStatus.fromWire(json['status']),
      runningTurnId: json['running_turn_id']?.toString(),
      lastStatusAt: json['last_status_at']?.toString(),
    );
  }
}

enum SessionRuntimeStatus {
  idle,
  running,
  failed;

  static SessionRuntimeStatus fromWire(Object? value) {
    return switch (value?.toString()) {
      'running' => SessionRuntimeStatus.running,
      'failed' => SessionRuntimeStatus.failed,
      _ => SessionRuntimeStatus.idle,
    };
  }
}

class ApprovalRequest {
  const ApprovalRequest({
    required this.approvalId,
    required this.actionType,
    required this.riskLevel,
    required this.summary,
  });

  final String approvalId;
  final String actionType;
  final String riskLevel;
  final String summary;

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    return ApprovalRequest(
      approvalId: json['approval_id']?.toString() ?? '',
      actionType: json['action_type']?.toString() ?? 'unknown',
      riskLevel: json['risk_level']?.toString() ?? 'high',
      summary: json['summary']?.toString() ?? '需要审批',
    );
  }
}

String _newId(String prefix) {
  final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final random = Random().nextInt(1 << 32).toRadixString(36);
  return '${prefix}_${now}_$random';
}

String? _formatTimestamp(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }

  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value;
  }

  final local = parsed.toLocal();
  final now = DateTime.now();
  final sameYear = local.year == now.year;
  final date = sameYear
      ? '${_twoDigits(local.month)}-${_twoDigits(local.day)}'
      : '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)}';

  return '$date ${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
