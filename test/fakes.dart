/// Shared fakes for the test suite.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:dsh_flutter/core/session/session_event.dart';
import 'package:dsh_flutter/core/session/session_models.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/transport/rpc_transport.dart';

/// In-memory transport with canned per-method responses and fresh broadcast
/// controllers per openMux/openHost call (simulating socket lifecycles).
class FakeTransport implements RpcTransport {
  final Map<String, List<ServerResponse>> _responses = {};
  final List<String> calls = [];
  bool failDescribe = false;
  int describeCalls = 0;

  /// Full override: when set, `call` delegates to it verbatim.
  Future<ServerResponse> Function(
      String method, Map<String, dynamic> payload)? callOverride;

  final List<StreamController<ServerRequest>> _muxControllers = [];
  final List<StreamController<ServerRequest>> _hostControllers = [];

  StreamController<ServerRequest> get mux {
    if (_muxControllers.isEmpty) {
      _muxControllers.add(StreamController<ServerRequest>.broadcast());
    }
    return _muxControllers.last;
  }

  StreamController<ServerRequest> get host {
    if (_hostControllers.isEmpty) {
      _hostControllers.add(StreamController<ServerRequest>.broadcast());
    }
    return _hostControllers.last;
  }

  void enqueue(String method, ServerResponse response) {
    _responses.putIfAbsent(method, () => []).add(response);
  }

  static ServerResponse ok(dynamic value, {String rpcId = 'fake'}) =>
      ServerResponse(rpcId: rpcId, result: RpcResult.ok(value));

  static ServerResponse fail(String code, String message,
          {String rpcId = 'fake'}) =>
      ServerResponse(
          rpcId: rpcId,
          result: RpcResult.fail(
              RpcError(code: code, message: message, details: const {})));

  @override
  Future<ServerResponse> call(
    String method,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    calls.add(method);
    final override = callOverride;
    if (override != null) return override(method, payload);
    if (method == 'host.describe') {
      describeCalls++;
      if (failDescribe) {
        return fail('internal', 'boom');
      }
      final queued = _responses[method];
      if (queued != null && queued.isNotEmpty) return queued.removeAt(0);
      return ok(const {
        'version': '0.0.1',
        'cwd': r'C:\test',
        'attachedSessions': 3,
        'canOpenPath': false,
      });
    }
    final queued = _responses[method];
    if (queued != null && queued.isNotEmpty) return queued.removeAt(0);
    throw StateError('no canned response for $method');
  }

  @override
  Future<RpcReceipt> respond(ClientResponse message, {Duration? timeout}) async {
    responded.add(message);
    if (failRespond) return const RpcReceipt(accepted: false, reason: 'not-pending');
    return const RpcReceipt(accepted: true);
  }

  final List<String> downloadCalls = [];
  final Map<String, Uint8List> downloads = {};
  Object? downloadError;

  @override
  Future<Uint8List> getBytes(String pathAndQuery, {Duration? timeout}) async {
    downloadCalls.add(pathAndQuery);
    if (downloadError != null) throw downloadError!;
    final bytes = downloads[pathAndQuery];
    if (bytes == null) {
      throw TransportException('no canned download for $pathAndQuery');
    }
    return bytes;
  }

  final List<ClientResponse> responded = [];
  bool failRespond = false;

  @override
  Stream<ServerRequest> openMux({void Function()? onOpen}) {
    final controller = StreamController<ServerRequest>.broadcast();
    _muxControllers.add(controller);
    onOpen?.call();
    return controller.stream;
  }

  @override
  Stream<ServerRequest> openHost({void Function()? onOpen}) {
    final controller = StreamController<ServerRequest>.broadcast();
    _hostControllers.add(controller);
    onOpen?.call();
    return controller.stream;
  }
}

/// Canned gateway for widget tests.
class FakeGateway implements SessionGateway {
  List<SessionSummary> sessions = const [];
  WorkspaceListResult workspaces =
      const WorkspaceListResult(items: [], archivedSessionIds: []);
  final Map<String, HistoryPage> historyBySession = {};
  Object? listError;
  String createdId = 'created-1';
  String? lastCreateWorkspaceId;

  // M2 recording
  final List<
      ({
        String sessionId,
        String text,
        String mode,
        List<Map<String, dynamic>> content,
      })> prompts = [];
  final List<String> cancels = [];
  final List<({String sessionId, String itemId, Map<String, dynamic> action})>
      queueActions = [];
  Object? promptError;

  /// When set, `history` waits on this gate — lets tests race live events
  /// against an in-flight snapshot load.
  Completer<void>? historyGate;

  /// When non-empty, `history` pops pages from this queue (else falls back to
  /// [historyBySession]) — lets tests verify gap-repair refetches.
  final List<HistoryPage> historyPages = [];
  int historyCallCount = 0;

  @override
  Future<List<SessionSummary>> listSessions() async {
    if (listError != null) throw listError!;
    return sessions;
  }

  @override
  Future<WorkspaceListResult> listWorkspaces() async => workspaces;

  @override
  Future<HistoryPage> history(
    String sessionId, {
    int? beforeSeq,
    int maxMessages = 80,
  }) async {
    historyCallCount++;
    final gate = historyGate;
    if (gate != null) await gate.future;
    if (historyPages.isNotEmpty) return historyPages.removeAt(0);
    return historyBySession[sessionId] ??
        const HistoryPage(events: [], hasMore: false);
  }

  @override
  Future<String> createSession({String? workspaceId, String? cwd}) async {
    lastCreateWorkspaceId = workspaceId;
    return createdId;
  }

  final List<({String sessionId, int? atSeq})> forks = [];
  String forkResult = 'forked-1';

  @override
  Future<String> forkSession(String sessionId, {int? atSeq}) async {
    forks.add((sessionId: sessionId, atSeq: atSeq));
    return forkResult;
  }

  @override
  Future<void> prompt(
    String sessionId,
    List<Map<String, dynamic>> content, {
    String mode = 'queue',
  }) async {
    if (promptError != null) throw promptError!;
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String? ?? '')
        .join();
    prompts.add((
      sessionId: sessionId,
      text: text,
      mode: mode,
      content: content,
    ));
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancels.add(sessionId);
  }

  @override
  Future<void> updateQueue(
    String sessionId,
    String itemId,
    Map<String, dynamic> action,
  ) async {
    queueActions
        .add((sessionId: sessionId, itemId: itemId, action: action));
  }

  // Workspace-creation flow recording (M2.5).
  final Map<String, DirectoryListing> directories = {};
  Object? directoryError;
  String? lastCreateDirectoryParent;
  String? lastCreateDirectoryName;
  final List<String> adoptedWorkspaces = [];

  @override
  Future<DirectoryListing> listDirectory({String? path}) async {
    if (directoryError != null) throw directoryError!;
    return directories[path ?? ''] ??
        const DirectoryListing(
          path: r'C:\home',
          home: r'C:\home',
          crumbs: [],
          entries: [],
          truncated: false,
        );
  }

  @override
  Future<String> createDirectory(String path, String name) async {
    lastCreateDirectoryParent = path;
    lastCreateDirectoryName = name;
    final created = '$path\\$name';
    createdDirectories.add(created);
    return created;
  }

  final List<String> createdDirectories = [];

  @override
  Future<String?> pickDirectory() async {
    pickDirectoryCalls++;
    return pickDirectoryResult;
  }

  int pickDirectoryCalls = 0;
  String? pickDirectoryResult;

  @override
  Future<WorkspaceCreateResult> createWorkspace(String path) async {
    adoptedWorkspaces.add(path);
    final name = path.replaceAll('\\', '/').split('/').last;
    final view = WorkspaceView(
      workspaceId: 'w-${adoptedWorkspaces.length}',
      path: path,
      title: name,
      sessionIds: const [],
      createdAt: '',
      updatedAt: '',
    );
    // Mirror the host: a created workspace appears in workspace.list.
    workspaces = WorkspaceListResult(
      items: [...workspaces.items, view],
      archivedSessionIds: workspaces.archivedSessionIds,
    );
    return WorkspaceCreateResult(workspace: view, created: true);
  }

  // M3: models / skills / rename recording.
  ModelCatalog modelCatalog = const ModelCatalog(
    current: ModelSelection(provider: 'p1', model: 'm1'),
    routable: true,
    groups: [
      ModelProviderGroup(
        id: 'p1',
        name: 'Provider 1',
        models: [
          ModelEntry(id: 'm1', name: 'Model One'),
          ModelEntry(id: 'm2', name: 'Model Two'),
          ModelEntry(
            id: 'm3',
            name: 'Vision Model',
            reasoning: ModelReasoning(
              efforts: [
                ModelReasoningEffort(id: 'low', name: '低'),
                ModelReasoningEffort(id: 'high', name: '高'),
              ],
              defaultEffort: 'low',
            ),
          ),
        ],
      ),
    ],
    failures: [],
  );
  final List<ModelSelection> modelSelections = [];
  Object? modelError;

  @override
  Future<ModelCatalog> sessionModels(String sessionId) async {
    if (modelError != null) throw modelError!;
    return modelCatalog;
  }

  @override
  Future<ModelSelection> selectModel(
    String sessionId,
    String provider,
    String model, {
    String? reasoningEffort,
  }) async {
    if (modelError != null) throw modelError!;
    final selection =
        ModelSelection(provider: provider, model: model, reasoningEffort: reasoningEffort);
    modelSelections.add(selection);
    return selection;
  }

  List<SkillEntry> skills = const [];
  Object? skillError;

  @override
  Future<List<SkillEntry>> listSkills(String sessionId) async {
    if (skillError != null) throw skillError!;
    return skills;
  }

  final List<String> renames = [];
  Object? renameError;

  @override
  Future<String> renameSession(String sessionId, String title) async {
    if (renameError != null) throw renameError!;
    renames.add(title);
    return title;
  }

  final List<({String sessionId, String rpcId, List<Map<String, dynamic>> answers})>
      questionAnswers = [];
  final List<String> cancelledQuestions = [];
  Object? questionError;

  @override
  Future<void> answerQuestion(
    String sessionId,
    String rpcId,
    List<Map<String, dynamic>> answers,
  ) async {
    if (questionError != null) throw questionError!;
    questionAnswers.add(
        (sessionId: sessionId, rpcId: rpcId, answers: answers));
  }

  @override
  Future<void> cancelQuestion(String sessionId, String rpcId) async {
    if (questionError != null) throw questionError!;
    cancelledQuestions.add(rpcId);
  }

  final List<
      ({String sessionId, String rpcId, String approvalId, bool allow})>
      approvalAnswers = [];
  Object? approvalError;

  @override
  Future<void> approveOrReject(
    String sessionId,
    String rpcId,
    String approvalId, {
    required bool allow,
  }) async {
    if (approvalError != null) throw approvalError!;
    approvalAnswers.add((
      sessionId: sessionId,
      rpcId: rpcId,
      approvalId: approvalId,
      allow: allow,
    ));
  }

  final Map<String, Uint8List> attachments = {};
  Object? attachmentError;

  @override
  Future<Uint8List> attachment(String sessionId, String attachmentId) async {
    if (attachmentError != null) throw attachmentError!;
    final bytes = attachments[attachmentId];
    if (bytes == null) {
      throw const SessionApiException('attachment not found');
    }
    return bytes;
  }

  final List<String> workspaceRenames = [];
  final List<String> workspaceDeletes = [];
  final List<String> sessionArchives = [];
  Object? workspaceError;

  @override
  Future<void> renameWorkspace(String workspaceId, String title) async {
    if (workspaceError != null) throw workspaceError!;
    workspaceRenames.add('$workspaceId:$title');
  }

  @override
  Future<void> deleteWorkspace(String workspaceId) async {
    if (workspaceError != null) throw workspaceError!;
    workspaceDeletes.add(workspaceId);
    workspaces = WorkspaceListResult(
      items: workspaces.items
          .where((w) => w.workspaceId != workspaceId)
          .toList(),
      archivedSessionIds: workspaces.archivedSessionIds,
    );
  }

  @override
  Future<void> archiveSession(String sessionId) async {
    if (workspaceError != null) throw workspaceError!;
    sessionArchives.add(sessionId);
  }

  // M4: search / commands / reorder recording.
  SearchPage searchResult = const SearchPage(items: [], hasMore: false);
  final List<String> searchQueries = [];
  Object? searchError;

  @override
  Future<SearchPage> sessionSearch(String query) async {
    if (searchError != null) throw searchError!;
    searchQueries.add(query);
    return searchResult;
  }

  List<CommandEntry> commands = const [];
  final List<String> commandListCalls = [];
  Object? commandsError;

  @override
  Future<List<CommandEntry>> commandsList(String sessionId) async {
    if (commandsError != null) throw commandsError!;
    commandListCalls.add(sessionId);
    return commands;
  }

  final List<({String sessionId, String line})> commandExecutions = [];
  CommandExecution? commandExecutionResult;
  Object? commandsExecuteError;

  @override
  Future<CommandExecution?> commandsExecute(
    String sessionId,
    String line,
  ) async {
    if (commandsExecuteError != null) throw commandsExecuteError!;
    commandExecutions.add((sessionId: sessionId, line: line));
    return commandExecutionResult;
  }

  final List<({String workspaceId, String? beforeWorkspaceId})>
      workspaceMoves = [];
  List<String> workspaceOrderResult = const [];

  @override
  Future<List<String>> insertWorkspaceBefore(
    String workspaceId, {
    String? beforeWorkspaceId,
  }) async {
    if (workspaceError != null) throw workspaceError!;
    workspaceMoves
        .add((workspaceId: workspaceId, beforeWorkspaceId: beforeWorkspaceId));
    if (workspaceOrderResult.isNotEmpty) return workspaceOrderResult;
    return [workspaceId, ...workspaces.items
        .where((w) => w.workspaceId != workspaceId)
        .map((w) => w.workspaceId)];
  }

  final List<
      ({String workspaceId, String sessionId, String? beforeSessionId})>
      sessionMoves = [];

  @override
  Future<WorkspaceView> insertSessionBefore(
    String workspaceId,
    String sessionId, {
    String? beforeSessionId,
  }) async {
    if (workspaceError != null) throw workspaceError!;
    sessionMoves.add((
      workspaceId: workspaceId,
      sessionId: sessionId,
      beforeSessionId: beforeSessionId,
    ));
    final current = workspaces.items
        .where((w) => w.workspaceId == workspaceId)
        .firstOrNull;
    return current ??
        WorkspaceView(
          workspaceId: workspaceId,
          path: '',
          title: '',
          sessionIds: const [],
          createdAt: '',
          updatedAt: '',
        );
  }

  // T2: export / goals / subagents recording.
  Uint8List exportBytes = Uint8List(0);
  final List<String> exports = [];
  Object? exportError;

  @override
  Future<Uint8List> exportSession(String sessionId) async {
    if (exportError != null) throw exportError!;
    exports.add(sessionId);
    return exportBytes;
  }

  final List<String> goalActions = [];
  GoalRef goalRef = const GoalRef(id: 'g1', revision: 1);
  Object? goalError;

  @override
  Future<GoalRef> goalCreate(String sessionId, String objective,
      {int? maxGoalRounds}) async {
    if (goalError != null) throw goalError!;
    goalActions.add('create:$objective');
    return goalRef;
  }

  @override
  Future<GoalRef> goalEdit(String sessionId, GoalRef ref,
      {String? objective, int? maxGoalRounds}) async {
    if (goalError != null) throw goalError!;
    goalActions.add('edit:${objective ?? ''}:${maxGoalRounds ?? ''}');
    return ref;
  }

  @override
  Future<GoalRef> goalPause(String sessionId, GoalRef ref) async {
    if (goalError != null) throw goalError!;
    goalActions.add('pause');
    return ref;
  }

  @override
  Future<GoalRef> goalResume(String sessionId, GoalRef ref) async {
    if (goalError != null) throw goalError!;
    goalActions.add('resume');
    return ref;
  }

  @override
  Future<GoalRef> goalComplete(String sessionId, GoalRef ref) async {
    if (goalError != null) throw goalError!;
    goalActions.add('complete');
    return ref;
  }

  @override
  Future<void> goalClear(String sessionId, GoalRef ref) async {
    if (goalError != null) throw goalError!;
    goalActions.add('clear');
  }

  List<SubagentEntry> subagentEntries = const [];
  bool subagentParentAvailable = true;
  Object? subagentError;
  final List<({String parent, String child, String mode})> subagentInterrupts =
      [];

  @override
  Future<SubagentList> subagents(String parentSessionId) async {
    if (subagentError != null) throw subagentError!;
    return SubagentList(
      entries: subagentEntries,
      parentAvailable: subagentParentAvailable,
    );
  }

  @override
  Future<void> interruptSubagent(
    String parentSessionId,
    String childSessionId,
    String mode,
  ) async {
    if (subagentError != null) throw subagentError!;
    subagentInterrupts.add((
      parent: parentSessionId,
      child: childSessionId,
      mode: mode,
    ));
  }
}

/// Convenience event builders for fold tests.
SessionEvent ev(
  String type,
  int seq,
  Map<String, dynamic> data, {
  Object? surfaceOp,
  List<int>? sourceEventSeqs,
}) =>
    SessionEvent(
      type: type,
      seq: seq,
      time: 0,
      data: data,
      surfaceOp: SurfaceOp.parse(surfaceOp),
      sourceEventSeqs: sourceEventSeqs ?? const [],
    );

SessionEvent userMessage(int seq, String text, {Object? surfaceOp = 'append'}) =>
    ev('user/message', seq, {
      'id': 'u$seq',
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text}
      ],
      'source': {'kind': 'user'},
    }, surfaceOp: surfaceOp);

SessionEvent assistantMessage(int seq, List<Map<String, dynamic>> blocks,
        {Object? surfaceOp = 'append'}) =>
    ev('assistant/message', seq, {
      'message': {'id': 'a$seq', 'role': 'assistant', 'content': blocks}
    }, surfaceOp: surfaceOp);

SessionEvent textDelta(int seq, String text, {int index = 0}) =>
    ev('assistant/chunk', seq, {
      'chunk': {'type': 'text-delta', 'index': index, 'text': text}
    });
