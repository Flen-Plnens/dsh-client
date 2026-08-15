import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/connection/connection_controller.dart';
import '../core/rpc/rpc_envelope.dart';
import '../core/session/session_repository.dart';
import '../core/transport/http_ws_transport.dart';
import 'about_dialog.dart';
import 'session_list_page.dart';

/// Connectivity screen: service address → connect → status + session list.
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  static const _maxLogLines = 200;

  final TextEditingController _addressController = TextEditingController();
  ConnectionController? _controller;
  HttpWsTransport? _transport;
  StreamSubscription<ServerRequest>? _muxSub;
  StreamSubscription<ServerRequest>? _hostSub;
  final List<_LogLine> _log = [];
  String? _addressError;
  bool _showDebugLog = false;

  @override
  void initState() {
    super.initState();
    // Prefer the address this DSH instance announces to its own shell.
    final webUrl = Platform.environment['DSH_WEB_URL'];
    _addressController.text =
        (webUrl != null && webUrl.isNotEmpty) ? webUrl : 'http://127.0.0.1:3080';
  }

  @override
  void dispose() {
    _muxSub?.cancel();
    _hostSub?.cancel();
    _controller?.dispose();
    _transport?.close();
    _addressController.dispose();
    super.dispose();
  }

  void _connect() {
    final address = _addressController.text;
    final HttpWsTransport transport;
    try {
      transport = HttpWsTransport.fromAddress(address);
    } on FormatException catch (e) {
      setState(() => _addressError = e.message);
      return;
    }
    setState(() => _addressError = null);

    final controller = ConnectionController(transport);
    _controller = controller;
    _transport = transport;
    controller.addListener(_onControllerChanged);
    _muxSub = controller.muxFrames.listen(
      (frame) => _pushLog('mux', frame),
    );
    _hostSub = controller.hostFrames.listen(
      (frame) => _pushLog('host', frame),
    );
    controller.start();
  }

  void _disconnect() {
    _controller?.stop();
    setState(() {});
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _openSessionList() {
    final controller = _controller;
    final transport = _transport;
    if (controller == null || transport == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionListPage(
          gateway: SessionRepository(transport),
          muxFrames: controller.muxFrames,
          hostFrames: controller.hostFrames,
          connection: controller,
        ),
      ),
    );
  }

  void _pushLog(String stream, ServerRequest frame) {
    if (!mounted) return;
    setState(() {
      _log.insert(
        0,
        _LogLine(
          stream: stream,
          type: frame.frameType ?? '(unknown)',
          detail: _describeFrame(frame),
        ),
      );
      if (_log.length > _maxLogLines) _log.removeRange(_maxLogLines, _log.length);
    });
  }

  String _describeFrame(ServerRequest frame) {
    final payload = frame.payloadMap;
    if (payload == null) return '';
    switch (frame.frameType) {
      case 'session/subscribed':
        return 'lastSeq=${payload['lastSeq']}';
      case 'session/event':
        final event = payload['event'];
        if (event is Map<String, dynamic>) {
          final type = event['type'] ?? '?';
          final seq = event['seq'];
          return '$type (seq=$seq)';
        }
        return '';
      case 'session/projection':
        return 'key=${payload['key']} seq=${payload['seq']}';
      case 'host/session-status':
        return 'running=${payload['running']}';
      default:
        final keys = payload.keys.take(4).join(', ');
        return keys.isEmpty ? '' : '{$keys}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final connected = controller?.isConnected ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text(kAppName),
        actions: [
          IconButton(
            tooltip: '关于',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDshAboutDialog(context),
          ),
          IconButton(
            tooltip: '调试日志',
            icon: Icon(_showDebugLog
                ? Icons.bug_report
                : Icons.bug_report_outlined),
            onPressed: () => setState(() => _showDebugLog = !_showDebugLog),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _addressController,
                    enabled: !connected,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: '服务地址',
                      hintText: 'http://127.0.0.1:3080',
                      border: const OutlineInputBorder(),
                      errorText: _addressError,
                      prefixIcon: const Icon(Icons.dns_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                if (connected)
                  FilledButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('断开'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.link),
                    label: const Text('连接'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _StatusCard(controller: controller),
            if (connected && _transport != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _openSessionList(),
                icon: const Icon(Icons.forum_outlined),
                label: const Text('进入会话'),
              ),
            ],
            if (_showDebugLog) ...[
              const SizedBox(height: 16),
              const Text('调试：下行帧日志（mux / host）',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Expanded(
                child: _log.isEmpty
                    ? const Center(
                        child: Text('尚未收到任何帧',
                            style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        reverse: true,
                        itemCount: _log.length,
                        itemBuilder: (context, index) {
                          final line = _log[index];
                          return ListTile(
                            dense: true,
                            leading: Text(line.stream,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  color: line.stream == 'mux'
                                      ? Colors.teal
                                      : Colors.indigo,
                                  fontWeight: FontWeight.bold,
                                )),
                            title: Text(line.type,
                                style:
                                    const TextStyle(fontFamily: 'monospace')),
                            subtitle: line.detail.isEmpty
                                ? null
                                : Text(line.detail,
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12)),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final ConnectionController? controller;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.circle_outlined),
          title: Text('未连接'),
          subtitle: Text('填写服务地址后点击「连接」'),
        ),
      );
    }

    final phase = controller.phase;
    final (Color color, String label) = switch (phase) {
      ConnectionPhase.disconnected => (Colors.grey, '未连接'),
      ConnectionPhase.connecting => (Colors.amber, '连接中…'),
      ConnectionPhase.connected => (Colors.green, '已连接'),
      ConnectionPhase.reconnecting =>
        (Colors.orange, '重连中（第 ${controller.attempt} 次）'),
    };

    final host = controller.host;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: color),
                const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            if (host != null) ...[
              const SizedBox(height: 8),
              Text('DSH 版本：${host.version}',
                  style: const TextStyle(fontFamily: 'monospace')),
              Text('工作目录：${host.cwd}',
                  style: const TextStyle(fontFamily: 'monospace')),
              if (host.provider != null || host.model != null)
                Text('模型：${host.provider} / ${host.model}',
                    style: const TextStyle(fontFamily: 'monospace')),
              Text('已附加会话：${host.attachedSessions}',
                  style: const TextStyle(fontFamily: 'monospace')),
            ],
            if (controller.lastError != null) ...[
              const SizedBox(height: 8),
              Text('最近错误：${controller.lastError}',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

class _LogLine {
  const _LogLine({required this.stream, required this.type, required this.detail});

  final String stream;
  final String type;
  final String detail;
}
