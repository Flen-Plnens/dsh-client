/// Session/workspace domain access (M1) and live-event routing.
///
/// [SessionRepository] implements the wire calls over [RpcTransport];
/// [SessionEventRouter] fans `session/event` mux frames into attached
/// [SurfaceStore]s so the UI streams live events per open session.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../rpc/rpc_envelope.dart';
import '../transport/rpc_transport.dart';
import 'session_event.dart';
import 'session_models.dart';
import 'surface_store.dart';

/// A business-level failure surfaced from the gateway (RPC error branch).
class SessionApiException implements Exception {
  const SessionApiException(this.message, {this.code, this.rpcError});

  final String message;
  final String? code;
  final RpcError? rpcError;

  @override
  String toString() =>
      'SessionApiException(${code ?? 'error'}): $message';
}

/// Gateway interface the UI depends on (fake-able in widget tests).
abstract class SessionGateway {
  Future<List<SessionSummary>> listSessions();
  Future<WorkspaceListResult> listWorkspaces();
  Future<HistoryPage> history(String sessionId, {int? beforeSeq, int maxMessages});
  Future<String> createSession({String? workspaceId, String? cwd});

  /// Fork the session at the given seq (session.fork; `atSeq` anchors the
  /// completed-turn cut). Returns the child session id — the fork child keeps
  /// `parentSessionId` but has no `origin`, so it stays visible in the lists.
  Future<String> forkSession(String sessionId, {int? atSeq});

  /// Submit a user prompt (M2). `mode: "queue"` lands it in the next-turn
  /// inbox when the agent is busy; `"steer"` interrupts the active turn.
  Future<void> prompt(
    String sessionId,
    List<Map<String, dynamic>> content, {
    String mode = 'queue',
  });

  /// Abort the active turn; pending inbox work is preserved.
  Future<void> cancel(String sessionId);

  /// Mutate one pending queue item: `edit` / `remove` / `steer`.
  Future<void> updateQueue(
    String sessionId,
    String itemId,
    Map<String, dynamic> action,
  );

  /// Browse one directory level (absent path = the host home directory).
  Future<DirectoryListing> listDirectory({String? path});

  /// Create one child directory (name must be a single plain path segment).
  Future<String> createDirectory(String path, String name);

  /// Open the host's native folder picker; null when the user cancelled.
  /// Loopback-only (host.pickDirectory is a privileged method).
  Future<String?> pickDirectory();

  /// Adopt an existing host directory as a Workspace.
  Future<WorkspaceCreateResult> createWorkspace(String path);

  /// The session's model catalog: current selection + routable provider
  /// groups (session.models).
  Future<ModelCatalog> sessionModels(String sessionId);

  /// Switch the session's model (session.selectModel; also persists as the
  /// deployment default). [reasoningEffort] is adapter-validated when given.
  Future<ModelSelection> selectModel(
    String sessionId,
    String provider,
    String model, {
    String? reasoningEffort,
  });

  /// The user-invocable skill catalog (skill.list); invocation is a plain
  /// prompt whose `/name` token the host recognizes.
  Future<List<SkillEntry>> listSkills(String sessionId);

  /// Rename the session (session.rename); returns the normalized title.
  Future<String> renameSession(String sessionId, String title);

  /// Answer a model-asked question batch (mux `question/requested`): echoes
  /// the frame's rpcId through POST /api/respond.
  Future<void> answerQuestion(
    String sessionId,
    String rpcId,
    List<Map<String, dynamic>> answers,
  );

  /// Cancel a pending question (user dismissed the dialog): the host routes
  /// by rpcId and settles the ask as cancelled. A `not-accepted` receipt is
  /// benign — the question was already resolved elsewhere.
  Future<void> cancelQuestion(String sessionId, String rpcId);

  /// Answer a pending approval (mux `approval/requested`): echoes the frame's
  /// rpcId with `{sessionId, approvalId, outcome}` (allowed-once | rejected).
  Future<void> approveOrReject(
    String sessionId,
    String rpcId,
    String approvalId, {
    required bool allow,
  });

  /// Fetch one durable image attachment's bytes (session.attachment).
  Future<Uint8List> attachment(String sessionId, String attachmentId);

  /// Rename a workspace (workspace.rename).
  Future<void> renameWorkspace(String workspaceId, String title);

  /// Remove a workspace registration (workspace.delete; the directory and its
  /// session logs are untouched).
  Future<void> deleteWorkspace(String workspaceId);

  /// Archive a session (workspace.archiveSession): hidden from grouping
  /// surfaces, log and position preserved.
  Future<void> archiveSession(String sessionId);

  /// Content search over session history (session.search; query 1..500 chars,
  /// no NUL). Result page is host-capped at 20 rows.
  Future<SearchPage> sessionSearch(String query);

  /// The session's human-command catalog (commands.list, scoped to the
  /// session's agent).
  Future<List<CommandEntry>> commandsList(String sessionId);

  /// Execute a slash command line (commands.execute). Returns null for an
  /// admission miss (unknown or malformed command); the admitted outcome is
  /// durably logged as `command/run` + `command/done` session events.
  Future<CommandExecution?> commandsExecute(String sessionId, String line);

  /// Move a workspace before another (workspace.insertBefore; anchor omitted
  /// appends to the end). Returns the complete durable display order.
  Future<List<String>> insertWorkspaceBefore(
    String workspaceId, {
    String? beforeWorkspaceId,
  });

  /// Move a session within its workspace (workspace.insertSessionBefore;
  /// anchor omitted appends to the end). Returns the updated workspace.
  Future<WorkspaceView> insertSessionBefore(
    String workspaceId,
    String sessionId, {
    String? beforeSessionId,
  });

  /// Export the session log as a ZIP archive (GET /api/session.export).
  Future<Uint8List> exportSession(String sessionId);

  /// Create a goal (goal.create). Returns the mutation ref; the current goal
  /// state arrives on the `goal` session projection.
  Future<GoalRef> goalCreate(String sessionId, String objective,
      {int? maxGoalRounds});

  /// Edit the goal (goal.edit; at least one of objective/maxGoalRounds).
  Future<GoalRef> goalEdit(String sessionId, GoalRef ref,
      {String? objective, int? maxGoalRounds});

  /// Pause / resume / complete the goal (goal.pause|resume|complete).
  Future<GoalRef> goalPause(String sessionId, GoalRef ref);
  Future<GoalRef> goalResume(String sessionId, GoalRef ref);
  Future<GoalRef> goalComplete(String sessionId, GoalRef ref);

  /// Clear the goal (goal.clear).
  Future<void> goalClear(String sessionId, GoalRef ref);

  /// The parent session's subagent catalog (subagent.list).
  Future<SubagentList> subagents(String parentSessionId);

  /// Interrupt a continuable subagent (subagent.interrupt).
  Future<void> interruptSubagent(
    String parentSessionId,
    String childSessionId,
    String mode,
  );
}

/// Wire implementation over the DSH `/api` RPC.
class SessionRepository implements SessionGateway {
  SessionRepository(this.transport);

  final RpcTransport transport;

  dynamic _value(ServerResponse response) {
    if (!response.result.ok) {
      final error = response.result.error;
      throw SessionApiException(
        error?.message ?? 'RPC failed',
        code: error?.code,
        rpcError: error,
      );
    }
    return response.result.value;
  }

  @override
  Future<List<SessionSummary>> listSessions() async {
    final value = _value(await transport.call('session.list', const {}));
    if (value is! Map<String, dynamic>) return const [];
    final items = value['items'];
    return items is List
        ? items
            .whereType<Map<String, dynamic>>()
            .map(SessionSummary.fromJson)
            .toList()
        : const [];
  }

  @override
  Future<WorkspaceListResult> listWorkspaces() async {
    final value = _value(await transport.call('workspace.list', const {}));
    return WorkspaceListResult.fromJson(
        value is Map<String, dynamic> ? value : const {});
  }

  @override
  Future<HistoryPage> history(
    String sessionId, {
    int? beforeSeq,
    int maxMessages = 80,
  }) async {
    final value = _value(await transport.call('session.history', {
      'sessionId': sessionId,
      if (beforeSeq != null) 'beforeSeq': beforeSeq,
      'maxMessages': maxMessages,
    }));
    return HistoryPage.fromJson(
        value is Map<String, dynamic> ? value : const {});
  }

  @override
  Future<String> createSession({String? workspaceId, String? cwd}) async {
    if (workspaceId != null && cwd != null) {
      throw ArgumentError('workspaceId and cwd are mutually exclusive');
    }
    final value = _value(await transport.call('session.create', {
      if (workspaceId != null) 'workspaceId': workspaceId,
      if (cwd != null) 'cwd': cwd,
    }));
    if (value is! Map<String, dynamic>) {
      throw const SessionApiException('session.create returned no sessionId');
    }
    final sessionId = value['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const SessionApiException('session.create returned no sessionId');
    }
    return sessionId;
  }

  @override
  Future<String> forkSession(String sessionId, {int? atSeq}) async {
    final value = _value(await transport.call('session.fork', {
      'sessionId': sessionId,
      if (atSeq != null) 'atSeq': atSeq,
    }));
    if (value is! Map<String, dynamic>) {
      throw const SessionApiException('session.fork returned no sessionId');
    }
    final child = value['sessionId'];
    if (child is! String || child.isEmpty) {
      throw const SessionApiException('session.fork returned no sessionId');
    }
    return child;
  }

  @override
  Future<void> prompt(
    String sessionId,
    List<Map<String, dynamic>> content, {
    String mode = 'queue',
  }) async {
    if (content.isEmpty) {
      throw ArgumentError('prompt content must not be empty');
    }
    _value(await transport.call('session.prompt', {
      'sessionId': sessionId,
      'mode': mode,
      'content': content,
    }));
  }

  @override
  Future<void> cancel(String sessionId) async {
    _value(await transport.call('session.cancel', {'sessionId': sessionId}));
  }

  @override
  Future<void> updateQueue(
    String sessionId,
    String itemId,
    Map<String, dynamic> action,
  ) async {
    _value(await transport.call('session.updateQueue', {
      'sessionId': sessionId,
      'itemId': itemId,
      'action': action,
    }));
  }

  @override
  Future<DirectoryListing> listDirectory({String? path}) async {
    final value = _value(await transport.call('host.listDirectory', {
      if (path != null) 'path': path,
    }));
    return DirectoryListing.fromJson(
        value is Map<String, dynamic> ? value : const {});
  }

  @override
  Future<String> createDirectory(String path, String name) async {
    final value = _value(await transport.call('host.createDirectory', {
      'path': path,
      'name': name,
    }));
    if (value is! Map<String, dynamic>) {
      throw const SessionApiException('host.createDirectory returned no path');
    }
    final created = value['path'];
    if (created is! String || created.isEmpty) {
      throw const SessionApiException('host.createDirectory returned no path');
    }
    return created;
  }

  @override
  Future<String?> pickDirectory() async {
    final value = _value(await transport.call('host.pickDirectory', const {}));
    if (value is! Map<String, dynamic>) return null;
    return value['path'] as String?;
  }

  @override
  Future<WorkspaceCreateResult> createWorkspace(String path) async {
    final value = _value(await transport.call('workspace.create', {
      'path': path,
    }));
    return WorkspaceCreateResult.fromJson(
        value is Map<String, dynamic> ? value : const {});
  }

  @override
  Future<ModelCatalog> sessionModels(String sessionId) async {
    final value = _value(await transport.call('session.models', {
      'sessionId': sessionId,
    }));
    return ModelCatalog.fromJson(
        value is Map<String, dynamic> ? value : const {});
  }

  @override
  Future<ModelSelection> selectModel(
    String sessionId,
    String provider,
    String model, {
    String? reasoningEffort,
  }) async {
    final value = _value(await transport.call('session.selectModel', {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    }));
    final selected = value is Map<String, dynamic>
        ? value['selected']
        : null;
    if (selected is! Map<String, dynamic>) {
      throw const SessionApiException('session.selectModel returned no selection');
    }
    return ModelSelection.fromJson(selected);
  }

  @override
  Future<List<SkillEntry>> listSkills(String sessionId) async {
    final value = _value(await transport.call('skill.list', {
      'sessionId': sessionId,
    }));
    if (value is! Map<String, dynamic>) return const [];
    final skills = value['skills'];
    return skills is List
        ? skills
            .whereType<Map<String, dynamic>>()
            .map(SkillEntry.fromJson)
            .toList()
        : const [];
  }

  @override
  Future<String> renameSession(String sessionId, String title) async {
    final value = _value(await transport.call('session.rename', {
      'sessionId': sessionId,
      'title': title,
    }));
    if (value is! Map<String, dynamic>) {
      throw const SessionApiException('session.rename returned no title');
    }
    final renamed = value['title'];
    if (renamed is! String || renamed.isEmpty) {
      throw const SessionApiException('session.rename returned no title');
    }
    return renamed;
  }

  @override
  Future<void> answerQuestion(
    String sessionId,
    String rpcId,
    List<Map<String, dynamic>> answers,
  ) async {
    final receipt = await transport.respond(ClientResponse(
      rpcId: rpcId,
      result: RpcResult.ok({
        'sessionId': sessionId,
        'answer': {'answers': answers},
      }),
    ));
    if (!receipt.accepted) {
      throw SessionApiException(
        'question answer rejected: ${receipt.reason ?? 'not accepted'}',
        code: receipt.reason,
      );
    }
  }

  @override
  Future<void> cancelQuestion(String sessionId, String rpcId) async {
    await transport.respond(ClientResponse(
      rpcId: rpcId,
      result: RpcResult.fail(RpcError(
        code: 'cancelled',
        message: 'cancelled by user',
        details: const {},
      )),
    ));
    // accepted=false (already resolved elsewhere) is a benign outcome.
  }

  @override
  Future<void> approveOrReject(
    String sessionId,
    String rpcId,
    String approvalId, {
    required bool allow,
  }) async {
    final receipt = await transport.respond(ClientResponse(
      rpcId: rpcId,
      result: RpcResult.ok({
        'sessionId': sessionId,
        'approvalId': approvalId,
        'outcome': allow ? 'allowed-once' : 'rejected',
      }),
    ));
    if (!receipt.accepted) {
      throw SessionApiException(
        'approval response rejected: ${receipt.reason ?? 'not accepted'}',
        code: receipt.reason,
      );
    }
  }

  @override
  Future<Uint8List> attachment(String sessionId, String attachmentId) async {
    final value = _value(await transport.call('session.attachment', {
      'sessionId': sessionId,
      'attachmentId': attachmentId,
    }));
    if (value is! Map<String, dynamic>) {
      throw const SessionApiException('session.attachment returned no data');
    }
    final data = value['data'];
    if (data is! String) {
      throw const SessionApiException('session.attachment returned no data');
    }
    try {
      return base64Decode(data);
    } on FormatException {
      throw const SessionApiException('attachment data is not valid base64');
    }
  }

  @override
  Future<void> renameWorkspace(String workspaceId, String title) async {
    _value(await transport.call('workspace.rename', {
      'workspaceId': workspaceId,
      'title': title,
    }));
  }

  @override
  Future<void> deleteWorkspace(String workspaceId) async {
    _value(await transport.call('workspace.delete', {
      'workspaceId': workspaceId,
    }));
  }

  @override
  Future<void> archiveSession(String sessionId) async {
    _value(await transport.call('workspace.archiveSession', {
      'sessionId': sessionId,
    }));
  }

  @override
  Future<SearchPage> sessionSearch(String query) async {
    final value = _value(await transport.call('session.search', {
      'query': query,
    }));
    return SearchPage.fromJson(
        value is Map<String, dynamic> ? value : const {});
  }

  @override
  Future<List<CommandEntry>> commandsList(String sessionId) async {
    // Typert Remote carrier: slash-path method + {args: {...}} payload.
    final value = _value(await transport.call('commands/list', {
      'args': {'agentId': sessionId},
    }));
    return value is List
        ? value
            .whereType<Map<String, dynamic>>()
            .map(CommandEntry.fromJson)
            .toList()
        : const [];
  }

  @override
  Future<CommandExecution?> commandsExecute(
    String sessionId,
    String line,
  ) async {
    final value = _value(await transport.call('commands/execute', {
      'args': {'agentId': sessionId, 'line': line},
    }));
    // An ok result with no value = admission miss (unknown/malformed line).
    if (value is! Map<String, dynamic>) return null;
    return CommandExecution.fromJson(value);
  }

  @override
  Future<List<String>> insertWorkspaceBefore(
    String workspaceId, {
    String? beforeWorkspaceId,
  }) async {
    final value = _value(await transport.call('workspace.insertBefore', {
      'workspaceId': workspaceId,
      if (beforeWorkspaceId != null) 'beforeWorkspaceId': beforeWorkspaceId,
    }));
    if (value is! Map<String, dynamic>) return const [];
    final order = value['workspaceIds'];
    return order is List ? order.whereType<String>().toList() : const [];
  }

  @override
  Future<WorkspaceView> insertSessionBefore(
    String workspaceId,
    String sessionId, {
    String? beforeSessionId,
  }) async {
    final value = _value(await transport.call('workspace.insertSessionBefore', {
      'workspaceId': workspaceId,
      'sessionId': sessionId,
      if (beforeSessionId != null) 'beforeSessionId': beforeSessionId,
    }));
    if (value is! Map<String, dynamic>) {
      throw const SessionApiException(
          'workspace.insertSessionBefore returned no workspace');
    }
    // The response wraps the updated workspace: `{workspace: {...}}`.
    final workspace = value['workspace'];
    if (workspace is! Map<String, dynamic>) {
      throw const SessionApiException(
          'workspace.insertSessionBefore returned no workspace');
    }
    return WorkspaceView.fromJson(workspace);
  }

  @override
  Future<Uint8List> exportSession(String sessionId) async {
    return transport.getBytes(
        'session.export?sessionId=${Uri.encodeQueryComponent(sessionId)}');
  }

  GoalRef _goalRef(Object? value, String method) {
    if (value is! Map<String, dynamic>) {
      throw SessionApiException('$method returned no ref');
    }
    final ref = value['ref'];
    if (ref is! Map<String, dynamic>) {
      throw SessionApiException('$method returned no ref');
    }
    return GoalRef.fromJson(ref);
  }

  @override
  Future<GoalRef> goalCreate(String sessionId, String objective,
      {int? maxGoalRounds}) async {
    final value = _value(await transport.call('goal.create', {
      'sessionId': sessionId,
      'objective': objective,
      if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds,
    }));
    return _goalRef(value, 'goal.create');
  }

  @override
  Future<GoalRef> goalEdit(String sessionId, GoalRef ref,
      {String? objective, int? maxGoalRounds}) async {
    final value = _value(await transport.call('goal.edit', {
      'sessionId': sessionId,
      'ref': ref.toJson(),
      if (objective != null) 'objective': objective,
      if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds,
    }));
    return _goalRef(value, 'goal.edit');
  }

  @override
  Future<GoalRef> goalPause(String sessionId, GoalRef ref) async {
    final value = _value(await transport.call('goal.pause', {
      'sessionId': sessionId,
      'ref': ref.toJson(),
    }));
    return _goalRef(value, 'goal.pause');
  }

  @override
  Future<GoalRef> goalResume(String sessionId, GoalRef ref) async {
    final value = _value(await transport.call('goal.resume', {
      'sessionId': sessionId,
      'ref': ref.toJson(),
    }));
    return _goalRef(value, 'goal.resume');
  }

  @override
  Future<GoalRef> goalComplete(String sessionId, GoalRef ref) async {
    final value = _value(await transport.call('goal.complete', {
      'sessionId': sessionId,
      'ref': ref.toJson(),
    }));
    return _goalRef(value, 'goal.complete');
  }

  @override
  Future<void> goalClear(String sessionId, GoalRef ref) async {
    _value(await transport.call('goal.clear', {
      'sessionId': sessionId,
      'ref': ref.toJson(),
    }));
  }

  @override
  Future<SubagentList> subagents(String parentSessionId) async {
    final value = _value(await transport.call('subagent.list', {
      'parentSessionId': parentSessionId,
    }));
    return SubagentList.fromJson(
        value is Map<String, dynamic> ? value : const {});
  }

  @override
  Future<void> interruptSubagent(
    String parentSessionId,
    String childSessionId,
    String mode,
  ) async {
    _value(await transport.call('subagent.interrupt', {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': mode,
    }));
  }
}

/// Routes mux `session/event` frames to the attached stores for their
/// session, so open sessions stream live events without polling.
class SessionEventRouter {
  SessionEventRouter(Stream<ServerRequest> muxFrames) {
    _sub = muxFrames.listen(_onFrame, onError: (_) {});
  }

  final Map<String, SurfaceStore> _stores = {};
  late final StreamSubscription<ServerRequest> _sub;

  void attach(String sessionId, SurfaceStore store) {
    _stores[sessionId] = store;
  }

  void detach(String sessionId) {
    _stores.remove(sessionId);
  }

  Future<void> dispose() => _sub.cancel();

  void _onFrame(ServerRequest frame) {
    if (frame.frameType != 'session/event') return;
    final payload = frame.payloadMap;
    if (payload == null) return;
    final sessionId = payload['sessionId'];
    final eventJson = payload['event'];
    if (sessionId is! String) return;
    final store = _stores[sessionId];
    if (store == null) return;
    if (eventJson is! Map<String, dynamic>) return;
    store.apply(SessionEvent.fromJson(eventJson));
  }
}
