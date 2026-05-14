import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const CodexMobileControlApp());
}

class CodexMobileControlApp extends StatelessWidget {
  const CodexMobileControlApp({super.key});

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
      home: const ControlHomePage(),
    );
  }
}

class ControlHomePage extends StatefulWidget {
  const ControlHomePage({super.key});

  @override
  State<ControlHomePage> createState() => _ControlHomePageState();
}

class _ControlHomePageState extends State<ControlHomePage> {
  final TextEditingController _serverController = TextEditingController(text: 'ws://127.0.0.1:8787/ws');
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _connected = false;
  String? _selectedDeviceId;
  String? _selectedWorkspaceId;
  final String _sessionId = _newId('ses');
  final List<DeviceInfo> _devices = <DeviceInfo>[];
  final List<String> _logs = <String>[];
  ApprovalRequest? _pendingApproval;

  @override
  void dispose() {
    _subscription?.cancel();
    _channel?.sink.close();
    _serverController.dispose();
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedDevice = _devices.where((item) => item.deviceId == _selectedDeviceId).firstOrNull;
    final workspaces = selectedDevice?.workspaces ?? <WorkspaceInfo>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Codex 手机控制台'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(_connected ? Icons.link : Icons.link_off, size: 18),
              label: Text(_connected ? '已连接' : '未连接'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _serverController,
                      decoration: const InputDecoration(
                        labelText: 'Backend WebSocket',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _connected ? _disconnect : _connect,
                    icon: Icon(_connected ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                    label: Text(_connected ? '断开' : '连接'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedDeviceId,
                      items: _devices
                          .map((device) => DropdownMenuItem(
                                value: device.deviceId,
                                child: Text('${device.name} · ${device.status}'),
                              ))
                          .toList(),
                      onChanged: (value) => setState(() {
                        _selectedDeviceId = value;
                        _selectedWorkspaceId = _devices
                            .where((device) => device.deviceId == value)
                            .firstOrNull
                            ?.workspaces
                            .firstOrNull
                            ?.workspaceId;
                      }),
                      decoration: const InputDecoration(
                        labelText: '设备',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedWorkspaceId,
                      items: workspaces
                          .map((workspace) => DropdownMenuItem(
                                value: workspace.workspaceId,
                                child: Text(workspace.name),
                              ))
                          .toList(),
                      onChanged: (value) => setState(() => _selectedWorkspaceId = value),
                      decoration: const InputDecoration(
                        labelText: 'Workspace',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _logs.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _logs[index],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pendingApproval != null) ...[
                    _ApprovalCard(
                      request: _pendingApproval!,
                      onApprove: () => _resolveApproval(true),
                      onDeny: () => _resolveApproval(false),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _promptController,
                          minLines: 1,
                          maxLines: 4,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: '给电脑上的 Codex 发指令',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _canSend ? _sendTurn : null,
                        icon: const Icon(Icons.send),
                        label: const Text('发送'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _canSend {
    return _connected && _selectedDeviceId != null && _selectedWorkspaceId != null && _promptController.text.trim().isNotEmpty;
  }

  void _connect() {
    _disconnect();
    final channel = WebSocketChannel.connect(Uri.parse(_serverController.text.trim()));
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleRawMessage,
      onDone: () => setState(() => _connected = false),
      onError: (Object error) {
        _appendLog('连接错误：$error');
        setState(() => _connected = false);
      },
    );

    setState(() => _connected = true);
    _send(EventEnvelope(
      type: 'client.hello',
      payload: {
        'role': 'app',
        'client_id': 'app_flutter_demo',
        'user_id': 'usr_demo',
      },
    ));
  }

  void _disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    if (mounted) {
      setState(() => _connected = false);
    }
  }

  void _sendTurn() {
    final prompt = _promptController.text.trim();
    if (!_canSend) {
      return;
    }

    final turnId = _newId('turn');
    _appendLog('You: $prompt');
    _send(EventEnvelope(
      type: 'turn.start',
      deviceId: _selectedDeviceId,
      workspaceId: _selectedWorkspaceId,
      sessionId: _sessionId,
      turnId: turnId,
      payload: {'prompt': prompt},
    ));
    _promptController.clear();
    setState(() {});
  }

  void _handleRawMessage(dynamic raw) {
    final data = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = data['type'] as String;
    final payload = (data['payload'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

    switch (type) {
      case 'device.snapshot':
        _replaceDevices(payload['devices']);
      case 'device.online':
        _upsertDevice(DeviceInfo.fromJson(payload));
      case 'device.offline':
        _upsertDevice(DeviceInfo.fromJson(payload));
      case 'workspace.list':
        final device = payload['device'];
        if (device is Map) {
          _upsertDevice(DeviceInfo.fromJson(device.cast<String, dynamic>()));
        }
      case 'turn.delta':
        _appendLog('Codex: ${payload['text'] ?? ''}');
      case 'approval.requested':
        setState(() => _pendingApproval = ApprovalRequest.fromJson(payload));
        _appendLog('审批请求：${payload['summary'] ?? '需要审批'}');
      case 'turn.completed':
        _appendLog('完成：${payload['summary'] ?? 'turn completed'}');
      case 'turn.failed':
        _appendLog('失败：${payload['summary'] ?? 'turn failed'}');
      case 'error':
        _appendLog('错误：${payload['message'] ?? 'unknown error'}');
      default:
        _appendLog('事件 $type');
    }
  }

  void _replaceDevices(dynamic value) {
    if (value is! List) {
      return;
    }

    setState(() {
      _devices
        ..clear()
        ..addAll(value.whereType<Map>().map((item) => DeviceInfo.fromJson(item.cast<String, dynamic>())));
      _selectedDeviceId ??= _devices.firstOrNull?.deviceId;
      _selectedWorkspaceId ??= _devices.firstOrNull?.workspaces.firstOrNull?.workspaceId;
    });
  }

  void _upsertDevice(DeviceInfo device) {
    setState(() {
      final index = _devices.indexWhere((item) => item.deviceId == device.deviceId);
      if (index >= 0) {
        _devices[index] = device;
      } else {
        _devices.add(device);
      }
      _selectedDeviceId ??= device.deviceId;
      _selectedWorkspaceId ??= device.workspaces.firstOrNull?.workspaceId;
    });
  }

  void _send(EventEnvelope event) {
    _channel?.sink.add(jsonEncode(event.toJson()));
  }

  void _resolveApproval(bool approved) {
    final request = _pendingApproval;
    if (request == null || _selectedDeviceId == null) {
      return;
    }

    _send(EventEnvelope(
      type: 'approval.resolved',
      deviceId: _selectedDeviceId,
      workspaceId: _selectedWorkspaceId,
      sessionId: _sessionId,
      payload: {
        'approval_id': request.approvalId,
        'decision': approved ? 'approved' : 'denied',
      },
    ));
    _appendLog('${approved ? '已允许' : '已拒绝'}：${request.summary}');
    setState(() => _pendingApproval = null);
  }

  void _appendLog(String line) {
    setState(() => _logs.add(line.trimRight()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
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
  });

  final String deviceId;
  final String name;
  final String platform;
  final String status;
  final List<WorkspaceInfo> workspaces;

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final rawWorkspaces = json['workspaces'];
    return DeviceInfo(
      deviceId: json['device_id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Unknown device',
      platform: json['platform']?.toString() ?? 'unknown',
      status: json['status']?.toString() ?? 'offline',
      workspaces: rawWorkspaces is List
          ? rawWorkspaces.whereType<Map>().map((item) => WorkspaceInfo.fromJson(item.cast<String, dynamic>())).toList()
          : <WorkspaceInfo>[],
    );
  }
}

class WorkspaceInfo {
  const WorkspaceInfo({
    required this.workspaceId,
    required this.name,
    required this.pathHint,
  });

  final String workspaceId;
  final String name;
  final String pathHint;

  factory WorkspaceInfo.fromJson(Map<String, dynamic> json) {
    return WorkspaceInfo(
      workspaceId: json['workspace_id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Workspace',
      pathHint: json['path_hint']?.toString() ?? '',
    );
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
