import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart';

import '../core/connection/connection_controller.dart';
import '../core/rpc/rpc_envelope.dart';
import '../core/session/session_event.dart';
import '../core/session/session_models.dart';
import '../core/session/session_repository.dart';
import '../core/session/surface_store.dart';

/// One session — human-transcript replay, live updates from the mux
/// stream, a composer (prompt/cancel), the pending-input queue, and backward
/// pagination. Session events are buffered while history loads so live frames
/// that race the snapshot are never lost.
class SessionPage extends StatefulWidget {
  const SessionPage({
    super.key,
    required this.gateway,
    required this.muxFrames,
    required this.hostFrames,
    required this.sessionId,
    this.title,
    this.initialRunning = false,
    this.connection,
    this.imagePicker,
    this.saveFile,
  });

  final SessionGateway gateway;
  final Stream<ServerRequest> muxFrames;
  final Stream<ServerRequest> hostFrames;
  final String sessionId;
  final String? title;
  final bool initialRunning;

  /// The live connection controller (optional): when present the page shows a
  /// reconnect banner while the transport is not connected.
  final ConnectionController? connection;

  /// Image picking seam (defaults to the file_selector dialog) — injectable
  /// for tests.
  final Future<List<({Uint8List bytes, String mediaType})>> Function()?
      imagePicker;

  /// Export save seam (defaults to a native save-location dialog + file
  /// write) — injectable for tests. Receives the suggested file name and the
  /// bytes; returns the saved path, or null when the user cancelled.
  final Future<String?> Function(String suggestedName, Uint8List bytes)?
      saveFile;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  static const _pageSize = 80;

  final SurfaceStore _store = SurfaceStore();
  final TextEditingController _inputController = TextEditingController();
  final List<SessionEvent> _pendingLive = [];

  StreamSubscription<ServerRequest>? _muxSub;
  StreamSubscription<ServerRequest>? _hostSub;
  bool _loading = true;
  bool _buffering = false;
  bool _repairing = false;
  bool _hasMore = false;
  bool _loadingOlder = false;
  bool _sending = false;
  bool _running = false;
  String? _title;
  String? _error;
  List<QueueItem> _queue = const [];

  /// The `session/subscribed.lastSeq` durable baseline (gap detection).
  int? _subscribedLastSeq;

  /// Highest applied projection seq per key (higher-seq-wins; a stale
  /// projection must never overwrite a newer one).
  final Map<String, int> _projectionSeqs = {};

  /// Current model selection (session.models) — shown in the app bar.
  ModelSelection? _model;

  /// Last-fetched model catalog, kept so UI labels can show display names
  /// (and effort names) instead of raw wire ids.
  ModelCatalog? _catalog;
  List<SkillEntry> _skills = const [];

  /// The session's current goal (rides the `goal` session projection).
  GoalSnapshot? _goal;

  /// The session's command catalog (commands.list), lazily fetched for the
  /// command picker and invalidated by `commands/change` frames.
  List<CommandEntry> _commands = const [];

  /// Images picked for the next send (bytes + media type), with a thumbnail
  /// strip above the input bar.
  final List<({Uint8List bytes, String mediaType})> _pendingImages = [];

  /// Connection phase (reconnect banner); null when no connection provided.
  ConnectionPhase? _connectionPhase;

  /// Loaded attachment bytes cache (session.attachment).
  final Map<String, Uint8List> _imageCache = {};

  /// Pending host approvals. The frame's rpcId is echoed through /api/respond
  /// (`{sessionId, approvalId, outcome}`) to allow once or reject.
  final List<
      ({String rpcId, String approvalId, String toolName, String? reason})>
      _pendingApprovals = [];

  /// rpcId of the question dialog currently open (null when none). Lets a
  /// `question/resolved` frame dismiss the dialog and stops a redundant
  /// cancel response after the host already settled the question.
  String? _pendingQuestionRpcId;

  @override
  void initState() {
    super.initState();
    _running = widget.initialRunning;
    _title = widget.title;
    _connectionPhase = widget.connection?.phase;
    widget.connection?.addListener(_onConnectionChanged);
    _store.addListener(_onStoreChanged);
    _muxSub = widget.muxFrames.listen(_onMuxFrame, onError: (_) {});
    _hostSub = widget.hostFrames.listen(_onHostFrame, onError: (_) {});
    _loadInitial();
  }

  @override
  void dispose() {
    widget.connection?.removeListener(_onConnectionChanged);
    _store.removeListener(_onStoreChanged);
    _muxSub?.cancel();
    _hostSub?.cancel();
    _inputController.dispose();
    super.dispose();
  }

  void _onConnectionChanged() {
    if (!mounted) return;
    setState(() => _connectionPhase = widget.connection?.phase);
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _onHostFrame(ServerRequest frame) {
    if (frame.frameType != 'host/session-status') return;
    final payload = frame.payloadMap;
    if (payload == null || payload['sessionId'] != widget.sessionId) return;
    final running = payload['running'];
    if (running is bool && mounted) setState(() => _running = running);
  }

  void _onMuxFrame(ServerRequest frame) {
    // Global registry notification: any command may have appeared or gone;
    // the next picker open repulls (official soft invalidation).
    if (frame.frameType == 'commands/change') {
      _commands = const [];
      return;
    }
    final payload = frame.payloadMap;
    if (payload == null || payload['sessionId'] != widget.sessionId) return;
    switch (frame.frameType) {
      case 'session/subscribed':
        // Durable baseline for gap detection: if we already hold a window and
        // its tail lags the host's durable baseline, events were missed.
        final lastSeq = payload['lastSeq'];
        if (lastSeq is int) {
          _subscribedLastSeq = lastSeq;
          final tailSeq = _tailSeq;
          if (!_loading && !_buffering && tailSeq != null && lastSeq > tailSeq) {
            _repairGap();
          }
        }
      case 'session/event':
        final eventJson = payload['event'];
        if (eventJson is! Map<String, dynamic>) return;
        final event = SessionEvent.fromJson(eventJson);
        if (_loading || _buffering || _repairing) {
          _pendingLive.add(event);
          return;
        }
        // A seq gap means reconnect-window loss: buffer and repull the tail
        // page instead of appending a hole (official acceptLiveEvent).
        final tailSeq = _tailSeq;
        if (tailSeq != null && event.seq > tailSeq + 1) {
          _pendingLive.add(event);
          _repairGap();
          return;
        }
        _store.apply(event);
      case 'session/queue':
        if (!mounted) return;
        setState(() => _queue = QueueSnapshot.fromJson(payload).items);
      case 'question/requested':
        if (!mounted) return;
        unawaited(_showQuestionDialog(QuestionBatch.fromFrame(frame)));
      case 'question/resolved':
        // The host settled the ask elsewhere (answered/cancelled by another
        // path): dismiss the open dialog so the UI does not linger.
        final questionRpcId = payload['questionRpcId'];
        if (questionRpcId is String &&
            questionRpcId == _pendingQuestionRpcId) {
          _pendingQuestionRpcId = null;
          if (mounted) Navigator.of(context).pop();
        }
      case 'approval/requested':
        if (!mounted) return;
        final approvalId = payload['approvalId'];
        final toolName = payload['toolName'];
        if (approvalId is String && toolName is String) {
          setState(() {
            _pendingApprovals.add((
              rpcId: frame.rpcId,
              approvalId: approvalId,
              toolName: toolName,
              reason: payload['reason'] as String?,
            ));
          });
        }
      case 'approval/resolved':
        if (!mounted) return;
        final approvalId = payload['approvalId'];
        if (approvalId is String) {
          setState(() {
            _pendingApprovals
                .removeWhere((a) => a.approvalId == approvalId);
          });
        }
      case 'session/projection':
        final key = payload['key'];
        if (key is! String) return;
        final seq = (payload['seq'] as num?)?.toInt() ?? -1;
        final known = _projectionSeqs[key];
        if (known != null && seq <= known) return; // stale: higher-seq-wins
        if (key == 'title') {
          final value = payload['value'];
          if (value is String && value.isNotEmpty && mounted) {
            _projectionSeqs[key] = seq;
            setState(() => _title = value);
          }
        } else if (key == 'goal') {
          // Whole-value projection: `{goal: {...}, roundsStarted, …}` or null
          // when cleared.
          final value = payload['value'];
          if (!mounted) return;
          _projectionSeqs[key] = seq;
          setState(() {
            _goal = value is Map<String, dynamic>
                ? GoalSnapshot.fromProjection(value)
                : null;
          });
        }
    }
  }

  /// The current window tail seq (null while no events are loaded).
  int? get _tailSeq => _store.log.isEmpty ? null : _store.log.last.seq;

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _buffering = true;
    try {
      final page =
          await widget.gateway.history(widget.sessionId, maxMessages: _pageSize);
      if (!mounted) return;
      _store.load(page.events);
      _seedProjections(page);
      _flushPending();
      // Parity with official doOpen: a subscribed baseline beyond the loaded
      // tail means the snapshot predates the reconnect window — repull once.
      final baseline = _subscribedLastSeq;
      final tailSeq = _tailSeq;
      if (baseline != null && tailSeq != null && baseline > tailSeq) {
        final repulled =
            await widget.gateway.history(widget.sessionId, maxMessages: _pageSize);
        if (!mounted) return;
        _store.load(repulled.events);
        _seedProjections(repulled);
        _flushPending();
        setState(() {
          _loading = false;
          _hasMore = repulled.hasMore;
        });
        return;
      }
      setState(() {
        _loading = false;
        _hasMore = page.hasMore;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    } finally {
      _buffering = false;
    }
  }

  /// Resync-lite: repull the tail page and stitch the buffered live events
  /// through the shared load path — no loading flash (official repairGap).
  Future<void> _repairGap() async {
    if (_repairing || _loading || _buffering) return;
    _repairing = true;
    _buffering = true;
    try {
      final page =
          await widget.gateway.history(widget.sessionId, maxMessages: _pageSize);
      if (!mounted) return;
      _store.load(page.events);
      _seedProjections(page);
      _flushPending();
      setState(() => _hasMore = page.hasMore);
    } catch (e) {
      if (!mounted) return;
      // Keep the current window; the next subscribed/event gap check retries.
      _flushPending();
    } finally {
      _buffering = false;
      _repairing = false;
    }
  }

  /// Seed projection values from a history tail page under the same
  /// higher-seq-wins rule as push frames (official ProjectionValueStore.seed):
  /// a stale baseline cannot overwrite a newer frame. Seeds both `title` and
  /// the `goal` projection (whole value) so reopening a session with an active
  /// goal shows it immediately.
  void _seedProjections(HistoryPage page) {
    final title = page.title;
    if (title != null && title.isNotEmpty) {
      final asOfSeq = page.projectionAsOfSeq ?? -1;
      final known = _projectionSeqs['title'];
      if (known != null && asOfSeq <= known) return;
      if (_title != null && _title!.isNotEmpty) {
        // Keep an externally supplied title (widget.title); only frame updates
        // may supersede it.
        return;
      }
      _projectionSeqs['title'] = asOfSeq;
      _title = title;
    }
    final goalRaw = page.projectionValues?['goal'];
    if (goalRaw is Map<String, dynamic>) {
      final asOfSeq = page.projectionAsOfSeq ?? -1;
      final known = _projectionSeqs['goal'];
      if (known == null || asOfSeq > known) {
        _projectionSeqs['goal'] = asOfSeq;
        _goal = GoalSnapshot.fromProjection(goalRaw);
      }
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || _store.log.isEmpty) return;
    setState(() => _loadingOlder = true);
    _buffering = true;
    try {
      final beforeSeq = _store.log.first.seq;
      final page = await widget.gateway
          .history(widget.sessionId, beforeSeq: beforeSeq, maxMessages: _pageSize);
      if (!mounted) return;
      final combined = [...page.events, ..._store.log];
      _store.load(combined);
      _flushPending();
      setState(() => _hasMore = page.hasMore);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载更早失败：$e')));
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
      _buffering = false;
    }
  }

  void _flushPending() {
    for (final event in _pendingLive) {
      _store.apply(event);
    }
    _pendingLive.clear();
  }

  Future<void> _send({bool steer = false}) async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingImages.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      // A leading slash routes to commands.execute (pure admission semantics),
      // never to the model; a command line never carries images.
      if (text.startsWith('/') && _pendingImages.isEmpty) {
        await _executeCommand(text);
        _inputController.clear();
        return;
      }
      final content = <Map<String, dynamic>>[
        for (final image in _pendingImages)
          {
            'type': 'image',
            'mediaType': image.mediaType,
            'data': base64Encode(image.bytes),
          },
        if (text.isNotEmpty) {'type': 'text', 'text': text},
      ];
      await widget.gateway.prompt(
        widget.sessionId,
        content,
        mode: steer ? 'steer' : 'queue',
      );
      _inputController.clear();
      _pendingImages.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_sendErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Route a slash line through commands.execute. Admission misses report
  /// locally (unknown/malformed); an admitted failure surfaces its handler
  /// text; success is not echoed — the host durably logs the lifecycle
  /// (`command/run`/`command/done`) which streams in as session events.
  Future<void> _executeCommand(String line) async {
    final execution =
        await widget.gateway.commandsExecute(widget.sessionId, line);
    if (!mounted) return;
    if (execution == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('未知或格式错误的命令：$line')));
    } else if (execution.kind == 'error' && execution.text != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('命令执行失败：${execution.text}')));
    }
  }

  /// Friendlier surface for host rejections: a model without vision support
  /// refuses image input with an attachment-error — point the user at the
  /// model picker instead of the raw RPC error.
  static String _sendErrorMessage(Object e) {
    if (e is SessionApiException) {
      final code = e.code ?? '';
      final message = e.message;
      if (code.contains('attachment') ||
          message.contains('does not support image') ||
          message.contains('image input')) {
        return '图片发送失败：$message'
            '（当前模型可能不支持图片输入，可在「模型」中选择支持视觉的模型）';
      }
    }
    return '发送失败：$e';
  }

  Future<void> _pickImages() async {
    try {
      final List<({Uint8List bytes, String mediaType})> images;
      if (widget.imagePicker != null) {
        images = await widget.imagePicker!();
      } else {
        images = await _pickImagesFromDisk();
      }
      if (!mounted) return;
      if (images.isEmpty) return; // cancelled, or nothing readable
      setState(() => _pendingImages.addAll(images));
    } catch (e) {
      // Never fail silently: a picker/platform error must be visible.
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_pickerErrorMessage(e))));
    }
  }

  static String _pickerErrorMessage(Object e) {
    if (e is MissingPluginException) {
      return '打开文件选择器失败：文件选择插件未注册。'
          '请重新构建应用后再试（$e）';
    }
    return '打开文件选择器失败：$e';
  }

  static String _mediaTypeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  Future<List<({Uint8List bytes, String mediaType})>>
      _pickImagesFromDisk() async {
    const typeGroup = XTypeGroup(
      label: '图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    final files = await openFiles(acceptedTypeGroups: [typeGroup]);
    final images = <({Uint8List bytes, String mediaType})>[];
    for (final file in files) {
      try {
        images.add((
          bytes: await file.readAsBytes(),
          mediaType: _mediaTypeFor(file.name),
        ));
      } catch (_) {
        // Skip unreadable files; keep the rest.
      }
    }
    return images;
  }

  Future<void> _showQuestionDialog(QuestionBatch batch) async {
    if (batch.questions.isEmpty) return;
    _pendingQuestionRpcId = batch.rpcId;
    final answers = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => _QuestionDialog(batch: batch),
    );
    final resolvedElsewhere = _pendingQuestionRpcId == null;
    if (_pendingQuestionRpcId == batch.rpcId) _pendingQuestionRpcId = null;
    if (answers == null || !mounted) {
      // User cancelled (or a question/resolved frame already dismissed the
      // dialog — then the host settled it and no cancel response is due).
      if (!resolvedElsewhere) {
        try {
          await widget.gateway.cancelQuestion(widget.sessionId, batch.rpcId);
        } catch (_) {
          // Cancel is best-effort; the host settles pending asks on timeout.
        }
      }
      return;
    }
    try {
      await widget.gateway.answerQuestion(
        widget.sessionId,
        batch.rpcId,
        answers,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('回答失败：$e')));
    }
  }

  Future<Uint8List> _loadImage(ImageRefView ref) async {
    final cached = _imageCache[ref.attachmentId];
    if (cached != null) return cached;
    final bytes =
        await widget.gateway.attachment(widget.sessionId, ref.attachmentId);
    _imageCache[ref.attachmentId] = bytes;
    return bytes;
  }

  void _openSubagent(String sessionId, {String? title}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(
          gateway: widget.gateway,
          muxFrames: widget.muxFrames,
          hostFrames: widget.hostFrames,
          sessionId: sessionId,
          // Seed the detail page with the producer label; the subagent's own
          // title projection (higher-seq-wins) replaces it when it arrives.
          title: title,
          connection: widget.connection,
        ),
      ),
    );
  }

  Future<void> _editQueueItem(String itemId, String currentText) async {
    final controller = TextEditingController(text: currentText);
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑待发消息'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '消息内容'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (edited == null || edited.trim().isEmpty || !mounted) return;
    await _queueAction(itemId, {
      'kind': 'edit',
      'content': [
        {'type': 'text', 'text': edited.trim()}
      ],
    });
  }

  Future<void> _cancel() async {
    try {
      await widget.gateway.cancel(widget.sessionId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('取消失败：$e')));
    }
  }

  Future<void> _queueAction(String itemId, Map<String, dynamic> action) async {
    try {
      await widget.gateway.updateQueue(widget.sessionId, itemId, action);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('队列操作失败：$e')));
    }
  }

  Future<void> _showModelPicker() async {
    final ModelCatalog catalog;
    try {
      catalog = await widget.gateway.sessionModels(widget.sessionId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('获取模型失败：$e')));
      return;
    }
    if (!mounted) return;
    _catalog = catalog;
    final selected = await showDialog<ModelSelection>(
      context: context,
      builder: (context) => _ModelPickerDialog(catalog: catalog),
    );
    if (selected == null || !mounted) return;
    try {
      final confirmed = await widget.gateway.selectModel(
        widget.sessionId,
        selected.provider,
        selected.model,
        reasoningEffort: selected.reasoningEffort,
      );
      if (!mounted) return;
      setState(() => _model = confirmed);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('切换模型失败：$e')));
    }
  }

  /// Export the session log as a ZIP archive (GET /api/session.export) and
  /// save it via the native save-location dialog (or the injected seam).
  Future<void> _exportSession() async {
    try {
      final bytes = await widget.gateway.exportSession(widget.sessionId);
      if (!mounted) return;
      final suggestedName = '${widget.sessionId}.zip';
      final savedPath = widget.saveFile != null
          ? await widget.saveFile!(suggestedName, bytes)
          : await _saveWithDialog(suggestedName, bytes);
      if (savedPath == null || !mounted) return; // user cancelled
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出：$savedPath')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  Future<String?> _saveWithDialog(String suggestedName, Uint8List bytes) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return null;
    await File(location.path).writeAsBytes(bytes);
    return location.path;
  }

  /// Goals panel: shows the current goal (from the `goal` projection) with
  /// create / edit / pause / resume / complete / clear actions.
  Future<void> _showGoalPanel() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('目标',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (_goal == null)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('当前未设定目标。', style: TextStyle(color: Colors.grey)),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(_goal!.objective,
                    maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  '阶段：${_goalPhaseLabel(_goal!.phase)}'
                  ' · 已运行 ${_goal!.roundsStarted} 轮'
                  ' · 上限 ${_goal!.maxGoalRounds == 0 ? '不限' : '${_goal!.maxGoalRounds} 轮'}'
                  '${_goal!.blockedReasonMessage != null ? '\n受阻：${_goal!.blockedReasonMessage}' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(_goal == null ? '设定目标' : '编辑目标'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            if (_goal != null && _goal!.phase == 'paused')
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('恢复'),
                onTap: () => Navigator.pop(context, 'resume'),
              ),
            if (_goal != null && _goal!.phase != 'paused')
              ListTile(
                leading: const Icon(Icons.pause),
                title: const Text('暂停'),
                onTap: () => Navigator.pop(context, 'pause'),
              ),
            if (_goal != null && _goal!.phase != 'complete')
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('标记完成'),
                onTap: () => Navigator.pop(context, 'complete'),
              ),
            if (_goal != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('清除目标'),
                onTap: () => Navigator.pop(context, 'clear'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    final goal = _goal;
    switch (action) {
      case 'edit':
        await _editGoalDialog(goal);
      case 'resume':
        await _goalMutation((ref) => widget.gateway.goalResume(widget.sessionId, ref));
      case 'pause':
        await _goalMutation((ref) => widget.gateway.goalPause(widget.sessionId, ref));
      case 'complete':
        await _goalMutation((ref) => widget.gateway.goalComplete(widget.sessionId, ref));
      case 'clear':
        if (goal != null) {
          await _goalMutation((ref) async {
            await widget.gateway.goalClear(widget.sessionId, ref);
            return ref;
          });
        }
    }
  }

  static String _goalPhaseLabel(String phase) {
    switch (phase) {
      case 'active':
        return '进行中';
      case 'paused':
        return '已暂停';
      case 'blocked':
        return '受阻';
      case 'complete':
        return '已完成';
      default:
        return phase;
    }
  }

  Future<void> _goalMutation(
      Future<GoalRef> Function(GoalRef ref) mutate) async {
    final goal = _goal;
    if (goal == null) return;
    try {
      await mutate(GoalRef(id: goal.id, revision: goal.revision));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('目标操作失败：$e')));
    }
  }

  Future<void> _editGoalDialog(GoalSnapshot? goal) async {
    final objectiveController =
        TextEditingController(text: goal?.objective ?? '');
    final roundsController = TextEditingController(
        text: goal?.maxGoalRounds != 0 ? '${goal?.maxGoalRounds}' : '');
    final edited = await showDialog<({String objective, int? maxGoalRounds})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(goal == null ? '设定目标' : '编辑目标'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: objectiveController,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: '目标描述', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: roundsController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: '最大自动轮数（留空为不限）',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final objective = objectiveController.text.trim();
              if (objective.isEmpty) return;
              final rounds = int.tryParse(roundsController.text.trim());
              Navigator.pop(context,
                  (objective: objective, maxGoalRounds: rounds));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (edited == null || !mounted) return;
    try {
      if (goal == null) {
        await widget.gateway
            .goalCreate(widget.sessionId, edited.objective,
                maxGoalRounds: edited.maxGoalRounds);
      } else {
        await widget.gateway.goalEdit(
          widget.sessionId,
          GoalRef(id: goal.id, revision: goal.revision),
          objective: edited.objective,
          maxGoalRounds: edited.maxGoalRounds,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存目标失败：$e')));
    }
  }

  /// Subagent panel: the current session's child catalog (subagent.list) —
  /// open a child, interrupt a continuable one, surface diagnostics.
  Future<void> _showSubagentPanel() async {
    final SubagentList list;
    try {
      list = await widget.gateway.subagents(widget.sessionId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('获取子代理失败：$e')));
      return;
    }
    if (!mounted) return;
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('子代理',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (!list.parentAvailable)
              const ListTile(
                leading: Icon(Icons.warning_amber_outlined),
                title: Text('父会话不可用'),
              ),
            if (list.entries.isEmpty && list.parentAvailable)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('暂无子代理。', style: TextStyle(color: Colors.grey)),
              ),
            for (final entry in list.entries)
              if (entry.kind == 'child')
                ListTile(
                  leading: Icon(
                    entry.activity == 'running'
                        ? Icons.play_circle_outline
                        : Icons.account_tree_outlined,
                    size: 20,
                  ),
                  title: Text(
                    entry.label ?? entry.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      entry.mode == 'one-shot' ? '一次性' : '可续接',
                      entry.activity == 'running' ? '运行中' : '空闲',
                      if (entry.hasChildren) '有子代理',
                    ].join(' · '),
                  ),
                  trailing: entry.mode == 'continuable'
                      ? IconButton(
                          tooltip: '中断',
                          icon: const Icon(Icons.stop_circle_outlined),
                          onPressed: () => Navigator.pop(
                              context, 'interrupt:${entry.id}|${entry.mode}'),
                        )
                      : null,
                  onTap: () => Navigator.pop(context, 'open:${entry.id}'),
                )
              else
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(entry.id),
                  subtitle: Text('诊断：${entry.reason ?? '未知'}'),
                ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.startsWith('open:')) {
      _openSubagent(result.substring('open:'.length));
    } else if (result.startsWith('interrupt:')) {
      final spec = result.substring('interrupt:'.length);
      final parts = spec.split('|');
      if (parts.length < 2) return;
      try {
        await widget.gateway
            .interruptSubagent(widget.sessionId, parts[0], parts[1]);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('中断子代理失败：$e')));
      }
    }
  }

  Future<void> _showRenameDialog() async {
    final controller = TextEditingController(text: _title ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '会话标题'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    try {
      final renamed = await widget.gateway.renameSession(widget.sessionId, trimmed);
      if (!mounted) return;
      setState(() => _title = renamed);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
  }

  Future<void> _showSkillPicker() async {
    if (_skills.isEmpty) {
      try {
        _skills = await widget.gateway.listSkills(widget.sessionId);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取技能失败：$e')));
        return;
      }
    }
    if (!mounted || _skills.isEmpty) return;
    final skill = await showModalBottomSheet<SkillEntry>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('技能', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final entry in _skills)
              ListTile(
                leading: const Icon(Icons.bolt_outlined),
                title: Text(entry.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: entry.description.isEmpty
                    ? null
                    : Text(entry.description,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(context, entry),
              ),
          ],
        ),
      ),
    );
    if (skill == null || !mounted) return;
    // Invocation is a plain prompt whose `/name` token the host recognizes.
    final current = _inputController.text;
    final insert = current.isEmpty || current.endsWith(' ')
        ? '/${skill.name} '
        : ' /${skill.name} ';
    _inputController.text = '$current$insert';
    _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length);
  }

  Future<void> _showCommandPicker() async {
    if (_commands.isEmpty) {
      try {
        _commands = await widget.gateway.commandsList(widget.sessionId);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('获取命令失败：$e')));
        return;
      }
    }
    if (!mounted || _commands.isEmpty) return;
    final command = await showModalBottomSheet<CommandEntry>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('命令', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final entry in _commands)
              ListTile(
                leading: const Icon(Icons.terminal_outlined),
                title: Text('/${entry.name}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    if (entry.description.isNotEmpty) entry.description,
                    if (entry.inputHint != null && entry.inputHint!.isNotEmpty)
                      '输入：${entry.inputHint}',
                  ].join('\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, entry),
              ),
          ],
        ),
      ),
    );
    if (command == null || !mounted) return;
    // Selecting fills the input; sending routes through commands.execute
    // (server-side, no model round-trip).
    final current = _inputController.text;
    final insert = current.isEmpty || current.endsWith(' ')
        ? '/${command.name} '
        : ' /${command.name} ';
    _inputController.text = '$current$insert';
    _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length);
  }

  /// Human-readable model label: display name + effort display name, falling
  /// back to the raw wire ids when the catalog has no entry.
  String _modelLabel(ModelSelection model) {
    final entry = _catalog?.groups
        .expand((g) => g.models)
        .where((m) => m.id == model.model)
        .firstOrNull;
    final name = entry?.name ?? model.model;
    String? effort = model.reasoningEffort;
    if (effort != null) {
      final efforts = entry?.reasoning?.efforts ?? const <ModelReasoningEffort>[];
      final named = efforts.where((e) => e.id == effort).firstOrNull;
      effort = named?.name ?? effort;
    }
    return '模型：$name${effort != null ? '（$effort）' : ''}';
  }

  /// Answer a pending approval (allow once / reject): echoes the frame's
  /// rpcId through /api/respond. The host emits approval/resolved on settle,
  /// which removes the notice.
  Future<void> _answerApproval(
    ({String rpcId, String approvalId, String toolName, String? reason})
        approval, {
    required bool allow,
  }) async {
    try {
      await widget.gateway.approveOrReject(
        widget.sessionId,
        approval.rpcId,
        approval.approvalId,
        allow: allow,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('审批响应失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '选择模型',
            icon: const Icon(Icons.tune),
            onPressed: _showModelPicker,
          ),
          IconButton(
            tooltip: _goal == null ? '设定目标' : '目标',
            icon: const Icon(Icons.flag_outlined),
            onPressed: _showGoalPanel,
          ),
          IconButton(
            tooltip: '子代理',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: _showSubagentPanel,
          ),
          IconButton(
            tooltip: '导出会话日志（ZIP）',
            icon: const Icon(Icons.download_outlined),
            onPressed: _exportSession,
          ),
          IconButton(
            tooltip: '重命名会话',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _showRenameDialog,
          ),
          if (_running)
            IconButton(
              tooltip: '中断当前回合',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: _sending ? null : _cancel,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_connectionPhase != null &&
              _connectionPhase != ConnectionPhase.connected)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _connectionPhase == ConnectionPhase.connecting
                            ? '正在连接服务…'
                            : '连接已断开，正在重连（第 ${widget.connection?.attempt ?? 0} 次）…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => widget.connection?.reconnect(),
                      child: const Text('立即重连'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: _buildBody()),
          if (_pendingApprovals.isNotEmpty)
            for (final approval in _pendingApprovals)
              _ApprovalNotice(
                toolName: approval.toolName,
                reason: approval.reason,
                onAllow: () => _answerApproval(approval, allow: true),
                onReject: () => _answerApproval(approval, allow: false),
              ),
          if (model != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _modelLabel(model),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          if (_pendingImages.isNotEmpty) _PendingImageStrip(
            images: _pendingImages,
            onRemove: (index) =>
                setState(() => _pendingImages.removeAt(index)),
          ),
          if (_queuedItems.isNotEmpty || _steeringItems.isNotEmpty)
            _QueueStrip(
              queued: _queuedItems,
              steering: _steeringItems,
              onRemove: (id) => _queueAction(id, {'kind': 'remove'}),
              onSteer: (id) => _queueAction(id, {'kind': 'steer'}),
              onEdit: (id, text) => _editQueueItem(id, text),
            ),
          _buildInputBar(),
        ],
      ),
    );
  }

  /// Normal pending next-turn input (the only user-operable queue rows).
  List<QueueItem> get _queuedItems =>
      _queue.where((i) => i.placement == 'queued').toList();

  /// In-flight steering rows: shown read-only, never operated as queued items.
  List<QueueItem> get _steeringItems =>
      _queue.where((i) => i.placement == 'steering').toList();

  Widget _buildInputBar() {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: '图片',
              icon: const Icon(Icons.image_outlined),
              onPressed: _pickImages,
            ),
            IconButton(
              tooltip: '技能',
              icon: const Icon(Icons.bolt_outlined),
              onPressed: _showSkillPicker,
            ),
            IconButton(
              tooltip: '命令',
              icon: const Icon(Icons.tag),
              onPressed: _showCommandPicker,
            ),
            if (_running)
              IconButton(
                tooltip: '中断',
                icon: Icon(Icons.stop_circle_outlined,
                    color: theme.colorScheme.error),
                onPressed: _sending ? null : _cancel,
              ),
            Expanded(
              child: TextField(
                controller: _inputController,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: '输入消息，回车发送…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              tooltip: '发送（长按立即引导 steer）',
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              onPressed: _sending ? null : _send,
              onLongPress: _sending ? null : () => _send(steer: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：$_error'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadInitial, child: const Text('重试')),
          ],
        ),
      );
    }
    final messages = _store.messages;
    final streaming = _store.streaming;
    final hasStreaming = streaming != null && !streaming.isEmpty;
    if (messages.isEmpty && !hasStreaming) {
      return const Center(child: Text('新会话，输入消息开始对话'));
    }
    // reverse:true — index 0 is laid out at the visual bottom.
    // Slots (visual top → bottom): [load-older] [oldest … newest] [streaming]
    final s = hasStreaming ? 1 : 0;
    final m = _hasMore ? 1 : 0;
    final itemCount = messages.length + s + m;
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (_hasMore && index == itemCount - 1) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _loadingOlder
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton.icon(
                      onPressed: _loadOlder,
                      icon: const Icon(Icons.expand_less),
                      label: const Text('加载更早的消息'),
                    ),
            ),
          );
        }
        if (hasStreaming && index == 0) {
          return _StreamingBubble(streaming: streaming);
        }
        final messageIndex = index - s; // 0 = newest message
        final message = messages[messages.length - 1 - messageIndex];
        return _MessageBubble(
          message: message,
          onOpenSubagent: (id) => _openSubagent(
            id,
            title: message.producerLabel ?? message.sourceKind,
          ),
          imageLoader: _loadImage,
        );
      },
    );
  }
}

/// Pending next-turn input: user-operable queued rows (remove/steer) plus a
/// read-only steering notice. `context` placement never appears here.
class _QueueStrip extends StatelessWidget {
  const _QueueStrip({
    required this.queued,
    required this.steering,
    required this.onRemove,
    required this.onSteer,
    required this.onEdit,
  });

  final List<QueueItem> queued;
  final List<QueueItem> steering;
  final void Function(String id) onRemove;
  final void Function(String id) onSteer;
  final void Function(String id, String text) onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (queued.isNotEmpty) ...[
            Row(
              children: [
                Icon(Icons.hourglass_bottom,
                    size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Text('待处理队列', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in queued) ...[
                    _QueueChip(
                      item: item,
                      onRemove: () => onRemove(item.id),
                      onSteer: () => onSteer(item.id),
                      onEdit: () => onEdit(item.id, item.text),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ],
          if (steering.isNotEmpty) ...[
            if (queued.isNotEmpty) const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.directions,
                    size: 14, color: theme.colorScheme.tertiary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '正在引导：${steering.map((s) => s.text.replaceAll('\n', ' ')).join('；')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _QueueChip extends StatelessWidget {
  const _QueueChip({
    required this.item,
    required this.onRemove,
    required this.onSteer,
    required this.onEdit,
  });

  final QueueItem item;
  final VoidCallback onRemove;
  final VoidCallback onSteer;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule,
              size: 13, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              item.text.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: '编辑',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: '立即引导（steer）',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            icon: const Icon(Icons.play_arrow),
            onPressed: onSteer,
          ),
          IconButton(
            tooltip: '移除',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.onOpenSubagent,
    this.imageLoader,
  });

  final MessageView message;
  final void Function(String sessionId)? onOpenSubagent;
  final Future<Uint8List> Function(ImageRefView ref)? imageLoader;

  @override
  Widget build(BuildContext context) {
    if (message.kind == MessageKind.context) {
      return _ContextRow(message: message, onOpenSubagent: onOpenSubagent);
    }
    final isUser = message.kind == MessageKind.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Card(
          color: isUser
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _content(context),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    switch (message.kind) {
      case MessageKind.user:
        if (message.text.isEmpty && message.images.isEmpty) {
          return const SizedBox.shrink();
        }
        return _body(context);
      case MessageKind.assistant:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!message.complete)
              Text('（部分输出，回合已中断）',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.orange)),
            if (message.reasoning != null && message.reasoning!.isNotEmpty)
              _ReasoningBlock(reasoning: message.reasoning!),
            ..._bodyParts(context),
            for (final call in message.toolCalls) _ToolCallCard(call: call),
          ],
        );
      case MessageKind.toolResult:
        return _ToolResultCard(
          toolCallId: message.toolResultToolCallId,
          isError: message.toolIsError,
          text: message.text,
        );
      case MessageKind.command:
        return _CommandCard(message: message);
      case MessageKind.context:
        return const SizedBox.shrink(); // handled above
    }
  }

  Widget _body(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: _bodyParts(context),
      );

  List<Widget> _bodyParts(BuildContext context) => [
        if (message.text.isNotEmpty) _Markdown(text: message.text),
        for (final image in message.images)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _AttachmentImage(
              width: image.width,
              height: image.height,
              loader: imageLoader == null
                  ? null
                  : () => imageLoader!(image),
            ),
          ),
      ];
}

/// A slash command's durable lifecycle row (`command/run` → `command/done`):
/// shows `/name args` and its outcome (pending / success / error + text).
/// Mirrors the official chat view's per-command row.
class _CommandCard extends StatelessWidget {
  const _CommandCard({required this.message});

  final MessageView message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = message.commandName;
    final args = message.commandArgs;
    final line = StringBuffer('/');
    if (name != null && name.isNotEmpty) {
      line.write(name);
      if (args != null && args.isNotEmpty) line.write(' $args');
    } else {
      line.write('命令 ${message.commandId ?? '?'}');
    }
    final outcome = message.commandOutcome;
    final status = outcome == null
        ? '执行中…'
        : outcome == 'success'
            ? '完成'
            : '失败';
    final statusColor = outcome == null
        ? theme.colorScheme.primary
        : outcome == 'success'
            ? Colors.green
            : theme.colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.terminal, size: 14, color: theme.colorScheme.outline),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                line.toString(),
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
              Text(
                (message.commandOutcomeText != null &&
                        message.commandOutcomeText!.isNotEmpty)
                    ? '$status：${message.commandOutcomeText}'
                    : status,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: statusColor),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Markdown rendering for settled (non-streaming) message text. Streaming
/// previews stay plain text — see [_StreamingBubble] — to avoid re-parsing
/// markdown on every chunk.
class _Markdown extends StatelessWidget {
  const _Markdown({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MarkdownBody(
      data: text,
      selectable: true,
      syntaxHighlighter: _DshSyntaxHighlighter(
        fenceLanguages: _fenceLanguages(text),
      ),
      styleSheet: MarkdownStyleSheet(
        p: theme.textTheme.bodyMedium,
        code: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}

/// Scan [markdown] for GFM fenced code blocks (``` or ~~~) and map each
/// block's code text (normalized) to its info-string language. flutter_markdown_plus
/// only hands the syntax highlighter the code text — never the fence language —
/// so this pre-scan re-associates them. Blocks whose code cannot be matched
/// (indented code, unusual fences) simply render unhighlighted.
Map<String, String> _fenceLanguages(String markdown) {
  final languages = <String, String>{};
  final lines = markdown.split('\n');
  final fenceRe = RegExp(r'^(\s*)(`{3,}|~{3,})\s*(.*)$');
  for (var i = 0; i < lines.length; i++) {
    final open = fenceRe.firstMatch(lines[i]);
    if (open == null) continue;
    final indent = open.group(1)!;
    final fence = open.group(2)!;
    final info = open.group(3)!.trim();
    final language = info.split(RegExp(r'\s+')).firstWhere(
          (word) => word.isNotEmpty,
          orElse: () => '',
        );
    final closer = RegExp(
      '^${RegExp.escape(indent)}${RegExp.escape(fence[0])}{${fence.length},}\\s*\$',
    );
    final content = <String>[];
    var closed = false;
    for (var j = i + 1; j < lines.length; j++) {
      if (closer.hasMatch(lines[j])) {
        closed = true;
        i = j;
        break;
      }
      content.add(lines[j]);
    }
    if (closed) {
      languages[content.join('\n').replaceAll('\r', '').trimRight()] = language;
    }
  }
  return languages;
}

/// Code-block syntax highlighting via package:highlight, mapped onto the
/// markdown highlighter contract. The fence language comes from
/// [_fenceLanguages]; blocks without a language render plain monospace —
/// package:highlight refuses to parse with a null language, which previously
/// crashed every fenced code block.
class _DshSyntaxHighlighter extends SyntaxHighlighter {
  _DshSyntaxHighlighter({Map<String, String>? fenceLanguages})
      : _fenceLanguages = fenceLanguages ?? const {};

  final Highlight _highlight = Highlight();
  final Map<String, String> _fenceLanguages;

  static const Map<String, Color> _palette = {
    'keyword': Color(0xFFBB86FC),
    'string': Color(0xFF6EE7B7),
    'number': Color(0xFFFCA5A5),
    'comment': Color(0xFF94A3B8),
    'built_in': Color(0xFF93C5FD),
    'title': Color(0xFFFCD34D),
    'type': Color(0xFF7DD3FC),
  };

  @override
  TextSpan format(String source) {
    final language = _fenceLanguages[source.replaceAll('\r', '').trimRight()];
    if (language == null || language.isEmpty) {
      return TextSpan(
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        text: source,
      );
    }
    final result = _highlight.parse(source, language: language.toLowerCase());
    final nodes = result.nodes;
    return TextSpan(
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      children: [
        if (nodes != null)
          for (final node in nodes)
            TextSpan(
              text: node.value,
              style: node.className == null
                  ? null
                  : TextStyle(color: _palette[node.className]),
            ),
      ],
    );
  }
}

/// A non-user `user/message` (injected context: system prompt snapshot, skill
/// catalog, subagent notices, background-job notices, …). Rendered as a
/// muted, non-interactive system row — never a user bubble. The row shows the
/// producer label and, when expanded, the actual injected content.
class _ContextRow extends StatefulWidget {
  const _ContextRow({required this.message, this.onOpenSubagent});

  final MessageView message;
  final void Function(String sessionId)? onOpenSubagent;

  @override
  State<_ContextRow> createState() => _ContextRowState();
}

class _ContextRowState extends State<_ContextRow> {
  bool _expanded = false;

  String get _label =>
      widget.message.producerLabel ?? widget.message.sourceKind ?? '上下文';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final form = widget.message.contextForm;
    final content = widget.message.text;
    final hasContent = content.isNotEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: hasContent
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              borderRadius: BorderRadius.circular(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline,
                      size: 13, color: theme.colorScheme.outline),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '系统：$_label${form != null ? ' · $form' : ''}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasContent)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: theme.colorScheme.outline,
                    ),
                ],
              ),
            ),
            if (_expanded && hasContent)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _Markdown(text: content),
              ),
            if (widget.onOpenSubagent != null &&
                widget.message.senderSessionId != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.account_tree_outlined, size: 14),
                  label: const Text('打开子代理会话'),
                  onPressed: () => widget.onOpenSubagent!(
                      widget.message.senderSessionId!),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SelectableText extends StatelessWidget {
  const _SelectableText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text,
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

/// Pending-approval card: asks the user to allow once or reject; the answer
/// echoes the frame's rpcId through /api/respond and the host's
/// `approval/resolved` frame removes the card.
class _ApprovalNotice extends StatelessWidget {
  const _ApprovalNotice({
    required this.toolName,
    this.reason,
    this.onAllow,
    this.onReject,
  });

  final String toolName;
  final String? reason;
  final VoidCallback? onAllow;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined,
                  size: 14, color: theme.colorScheme.tertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '等待审批：$toolName'
                  '${reason != null && reason!.isNotEmpty ? ' — $reason' : ''}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (onAllow != null || onReject != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onReject != null)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onReject,
                    child: const Text('拒绝'),
                  ),
                if (onAllow != null)
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onAllow,
                    child: const Text('允许一次'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Loads one attachment's bytes and renders the image; shows a spinner while
/// loading and an error placeholder on failure. Bytes are cached by the
/// owner (SessionPage), so scrolling back is instant.
class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({this.loader, this.width, this.height});

  final Future<Uint8List> Function()? loader;
  final int? width;
  final int? height;

  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader?.call();
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    final theme = Theme.of(context);
    if (future == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 280,
              maxHeight: 280,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                snapshot.data!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _error(theme),
              ),
            ),
          );
        }
        if (snapshot.hasError) return _error(theme);
        return const Padding(
          padding: EdgeInsets.all(8),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
    );
  }

  Widget _error(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.broken_image_outlined,
          size: 28, color: theme.colorScheme.outline),
    );
  }
}

/// Thumbnails of images picked for the next send, with per-image removal.
class _PendingImageStrip extends StatelessWidget {
  const _PendingImageStrip({required this.images, required this.onRemove});

  final List<({Uint8List bytes, String mediaType})> images;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < images.length; i++) ...[
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      images[i].bytes,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 56,
                        height: 56,
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => onRemove(i),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(2),
                        child: const Icon(Icons.close,
                            size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasoningBlock extends StatefulWidget {
  const _ReasoningBlock({required this.reasoning});

  final String reasoning;

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_expanded ? Icons.unfold_less : Icons.unfold_more,
                  size: 14, color: Colors.grey),
              const SizedBox(width: 4),
              Text('思考过程', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
            ),
            child: _SelectableText(widget.reasoning),
          ),
      ],
    );
  }
}

class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({required this.call});

  final ToolCallView call;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = widget.call;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.build_circle_outlined,
                    size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    call.name.isEmpty ? '工具调用' : call.name,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (call.arguments.isNotEmpty)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
              ],
            ),
            if (_expanded && call.arguments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  call.arguments,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace', fontSize: 11),
                  maxLines: 20,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolResultCard extends StatefulWidget {
  const _ToolResultCard({
    required this.toolCallId,
    required this.isError,
    required this.text,
  });

  final String? toolCallId;
  final bool isError;
  final String text;

  @override
  State<_ToolResultCard> createState() => _ToolResultCardState();
}

class _ToolResultCardState extends State<_ToolResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        widget.isError ? theme.colorScheme.error : theme.colorScheme.tertiary;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.isError
                      ? Icons.error_outline
                      : Icons.inventory_2_outlined,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.isError ? '工具执行失败' : '工具结果',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (widget.toolCallId != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.toolCallId!,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: Colors.grey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (widget.text.isNotEmpty)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
              ],
            ),
            if (_expanded && widget.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  widget.text,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace', fontSize: 11),
                  maxLines: 30,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.streaming});

  final StreamingAssistant streaming;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (streaming.reasoning.isNotEmpty) ...[
                  Text('思考中…', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 4),
                ],
                if (streaming.text.isEmpty && streaming.toolCalls.isEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text('正在思考…',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  )
                else
                  // Plain text while streaming: re-parsing markdown on every
                  // chunk would be expensive; the final assistant/message
                  // renders markdown instead.
                  _SelectableText(streaming.text),
                for (final call in streaming.toolCalls)
                  _ToolCallCard(call: call),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Model picker: the provider-grouped catalog with the current selection
/// marked. Selecting a model with advertised reasoning efforts asks for the
/// effort level; selecting pops with the chosen [ModelSelection].
class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({required this.catalog});

  final ModelCatalog catalog;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  ({ModelProviderGroup group, ModelEntry entry})? _selected;
  String? _effort;

  @override
  void initState() {
    super.initState();
    // Two-block layout: the reasoning-level block is visible immediately when
    // the current model advertises levels — no click required to reveal it.
    final current = widget.catalog.current;
    if (current.provider.isEmpty) return;
    for (final group in widget.catalog.groups) {
      if (group.id != current.provider) continue;
      for (final entry in group.models) {
        if (entry.id != current.model) continue;
        final reasoning = entry.reasoning;
        final efforts = reasoning?.efforts ?? const <ModelReasoningEffort>[];
        if (efforts.isEmpty) return;
        _selected = (group: group, entry: entry);
        _effort = current.reasoningEffort ??
            reasoning?.defaultEffort ??
            efforts.first.id;
        return;
      }
    }
  }

  void _pickModel(ModelProviderGroup group, ModelEntry entry) {
    final reasoning = entry.reasoning;
    final efforts = reasoning?.efforts ?? const <ModelReasoningEffort>[];
    if (efforts.isEmpty) {
      // No effort choice: select immediately.
      Navigator.pop(
        context,
        ModelSelection(provider: group.id, model: entry.id),
      );
      return;
    }
    setState(() {
      _selected = (group: group, entry: entry);
      _effort = reasoning?.defaultEffort ?? efforts.first.id;
    });
  }

  /// Display name for an effort id, falling back to the raw id.
  static String _effortName(List<ModelReasoningEffort> efforts, String id) {
    return efforts.where((e) => e.id == id).firstOrNull?.name ?? id;
  }

  /// '当前：' header — display names instead of raw provider/model ids.
  String _currentLabel(ModelSelection current) {
    final group = widget.catalog.groups
        .where((g) => g.id == current.provider)
        .firstOrNull;
    final entry =
        group?.models.where((m) => m.id == current.model).firstOrNull;
    final name = entry?.name ?? current.model;
    String? effort = current.reasoningEffort;
    if (effort != null) {
      final efforts = entry?.reasoning?.efforts ?? const <ModelReasoningEffort>[];
      effort = _effortName(efforts, effort);
    }
    return '当前：$name${effort != null ? '（$effort）' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.catalog.current;
    final selected = _selected;
    final efforts = selected?.entry.reasoning?.efforts ??
        const <ModelReasoningEffort>[];
    return AlertDialog(
      title: const Text('选择模型'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (current.provider.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _currentLabel(current),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              for (final group in widget.catalog.groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 2),
                  child: Text(
                    group.name,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (final model in group.models)
                  ListTile(
                    dense: true,
                    selected: selected != null &&
                        selected.group.id == group.id &&
                        selected.entry.id == model.id,
                    title: Text(model.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: model.description == null ||
                            model.description!.isEmpty
                        ? null
                        : Text(model.description!,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: current.provider == group.id &&
                            current.model == model.id
                        ? const Icon(Icons.check, size: 16)
                        : null,
                    onTap: () => _pickModel(group, model),
                  ),
              ],
              if (selected != null && efforts.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('推理等级（${selected.entry.name}）',
                    style: theme.textTheme.titleSmall),
                RadioGroup<String>(
                  groupValue: _effort,
                  onChanged: (value) {
                    if (value != null) setState(() => _effort = value);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final effort in efforts)
                        RadioListTile<String>(
                          dense: true,
                          title: Text(effort.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: effort.description == null
                              ? null
                              : Text(effort.description!,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                          value: effort.id,
                        ),
                    ],
                  ),
                ),
              ],
              if (widget.catalog.failures.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final failure in widget.catalog.failures)
                  Text(
                    '${failure.name} 不可用：${failure.message}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: selected == null
              ? null
              : () => Navigator.pop(
                    context,
                    ModelSelection(
                      provider: selected.group.id,
                      model: selected.entry.id,
                      reasoningEffort: _effort,
                    ),
                  ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// Model-asked question dialog (mux `question/requested`). Pops with the
/// wire answer list `[{id, selected: [labels], custom?}]` when submitted.
class _QuestionDialog extends StatefulWidget {
  const _QuestionDialog({required this.batch});

  final QuestionBatch batch;

  @override
  State<_QuestionDialog> createState() => _QuestionDialogState();
}

class _QuestionDialogState extends State<_QuestionDialog> {
  final Map<String, Set<String>> _selected = {};
  final Map<String, TextEditingController> _custom = {};
  final Map<String, String> _singleLabel = {};

  static String _intentLabel(String kind) {
    switch (kind) {
      case 'plan-review':
        return '计划评审';
      default:
        return kind;
    }
  }

  @override
  void initState() {
    super.initState();
    // Honour the presentation intent: default to the approve option so the
    // one-tap answer matches what the asker offered (plan-review approves the
    // plan shown in `detail`).
    for (final question in widget.batch.questions) {
      final intent = question.intent;
      if (intent == null || question.multiSelect || question.options.isEmpty) {
        continue;
      }
      if (question.options.any((o) => o.label == intent.approve)) {
        _singleLabel[question.id] = intent.approve;
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final answers = <Map<String, dynamic>>[];
    for (final question in widget.batch.questions) {
      final custom = _custom[question.id]?.text.trim() ?? '';
      if (question.options.isEmpty) {
        // Free-text question: single-select semantics → custom only.
        answers.add({
          'id': question.id,
          'selected': <String>[],
          if (custom.isNotEmpty) 'custom': custom,
        });
        continue;
      }
      if (question.multiSelect) {
        final selected = (_selected[question.id] ?? const <String>{}).toList();
        answers.add({
          'id': question.id,
          'selected': selected,
          if (custom.isNotEmpty) 'custom': custom,
        });
        continue;
      }
      final label = _singleLabel[question.id];
      answers.add({
        'id': question.id,
        'selected': label == null ? <String>[] : [label],
        if (custom.isNotEmpty) 'custom': custom,
      });
    }
    Navigator.of(context).pop(answers);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('模型提问'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final question in widget.batch.questions) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (question.header != null &&
                          question.header!.isNotEmpty)
                        Text(question.header!,
                            style: theme.textTheme.titleSmall),
                      Text(question.question,
                          style: theme.textTheme.bodyMedium),
                      if (question.intent != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '意图：${_intentLabel(question.intent!.kind)}'
                            '（默认选择「${question.intent!.approve}」）',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (question.detail != null &&
                          question.detail!.isNotEmpty)
                        Text(question.detail!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: Colors.grey)),
                    ],
                  ),
                ),
                if (question.options.isEmpty)
                  TextField(
                    controller: _custom.putIfAbsent(
                        question.id, TextEditingController.new),
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: '输入回答…',
                      border: OutlineInputBorder(),
                    ),
                  )
                else if (question.multiSelect)
                  for (final option in question.options)
                    CheckboxListTile(
                      dense: true,
                      title: Text(option.label,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: option.description == null
                          ? null
                          : Text(option.description!,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                      value: (_selected[question.id] ??
                              const <String>{})
                          .contains(option.label),
                      onChanged: (checked) {
                        setState(() {
                          final set =
                              _selected.putIfAbsent(question.id, () => <String>{});
                          if (checked == true) {
                            set.add(option.label);
                          } else {
                            set.remove(option.label);
                          }
                        });
                      },
                    )
                else
                  RadioGroup<String>(
                    groupValue: _singleLabel[question.id],
                    onChanged: (value) => setState(() {
                      if (value != null) {
                        _singleLabel[question.id] = value;
                      }
                    }),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final option in question.options)
                          RadioListTile<String>(
                            dense: true,
                            title: Text(option.label,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: option.description == null
                                ? null
                                : Text(option.description!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                            value: option.label,
                          ),
                      ],
                    ),
                  ),
                // WebUI parity: a free-form answer input sits below the
                // options (custom text accompanies the chosen labels).
                if (question.options.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                      controller: _custom.putIfAbsent(
                          question.id, TextEditingController.new),
                      maxLines: 2,
                      decoration: const InputDecoration(
                        hintText: '补充回答（可选）…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('提交回答'),
        ),
      ],
    );
  }
}