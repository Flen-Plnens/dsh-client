/// Wire row types for the session/workspace domains (parsed, non-validating).
library;

import '../rpc/rpc_envelope.dart';
import 'session_event.dart';

/// One `session.list` row.
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.updatedAt,
    required this.running,
    required this.blank,
    this.parentSessionId,
    this.origin,
    this.cwd,
    this.agentPreset,
    this.projectionValues,
  });

  final String sessionId;
  final int updatedAt;
  final bool running;
  final bool blank;
  final String? parentSessionId;
  final String? origin;
  final String? cwd;
  final String? agentPreset;

  /// The row's projections block values (the host computes these; the
  /// `title` key carries the session's display title).
  final Map<String, dynamic>? projectionValues;

  /// The session's display title from its `title` projection, if any.
  String? get title => projectionValues?['title'] as String?;

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    final projections = json['projections'];
    return SessionSummary(
      sessionId: json['sessionId'] as String? ?? '',
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      running: json['running'] == true,
      blank: json['blank'] == true,
      parentSessionId: json['parentSessionId'] as String?,
      origin: json['origin'] as String?,
      cwd: json['cwd'] as String?,
      agentPreset: json['agentPreset'] as String?,
      projectionValues: projections is Map<String, dynamic>
          ? projections['values'] is Map<String, dynamic>
              ? (projections['values'] as Map<String, dynamic>)
              : null
          : null,
    );
  }
}

/// One `workspace.list` item.
class WorkspaceView {
  const WorkspaceView({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
    required this.createdAt,
    required this.updatedAt,
  });

  final String workspaceId;
  final String path;
  final String title;
  final List<String> sessionIds;
  final String createdAt;
  final String updatedAt;

  factory WorkspaceView.fromJson(Map<String, dynamic> json) {
    final sessionIds = json['sessionIds'];
    return WorkspaceView(
      workspaceId: json['workspaceId'] as String? ?? '',
      path: json['path'] as String? ?? '',
      title: json['title'] as String? ?? '',
      sessionIds: sessionIds is List
          ? sessionIds.whereType<String>().toList()
          : const [],
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
    );
  }
}

/// `workspace.list` response value.
class WorkspaceListResult {
  const WorkspaceListResult({required this.items, required this.archivedSessionIds});

  final List<WorkspaceView> items;
  final List<String> archivedSessionIds;

  factory WorkspaceListResult.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    final archived = json['archivedSessionIds'];
    return WorkspaceListResult(
      items: items is List
          ? items
              .whereType<Map<String, dynamic>>()
              .map(WorkspaceView.fromJson)
              .toList()
          : const [],
      archivedSessionIds: archived is List
          ? archived.whereType<String>().toList()
          : const [],
    );
  }
}

/// One `session.history` page.
class HistoryPage {
  const HistoryPage({
    required this.events,
    required this.hasMore,
    this.projectionValues,
    this.projectionAsOfSeq,
  });

  final List<SessionEvent> events;
  final bool hasMore;

  /// The tail page's projections block values (host-computed; the `title` key
  /// carries the session's display title at the page cut).
  final Map<String, dynamic>? projectionValues;

  /// The projections block watermark (`asOfSeq`); projection seeding and
  /// push frames compare seqs so a stale baseline never overwrites a newer
  /// frame.
  final int? projectionAsOfSeq;

  /// The session's display title from the tail-page `title` projection.
  String? get title => projectionValues?['title'] as String?;

  factory HistoryPage.fromJson(Map<String, dynamic> json) {
    final raw = json['events'];
    final events = <SessionEvent>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map<String, dynamic>) continue;
        final event = entry['event'];
        if (event is Map<String, dynamic>) {
          events.add(SessionEvent.fromJson(event));
        }
      }
    }
    final projections = json['projections'];
    return HistoryPage(
      events: events,
      hasMore: json['hasMore'] == true,
      projectionValues: projections is Map<String, dynamic>
          ? projections['values'] is Map<String, dynamic>
              ? (projections['values'] as Map<String, dynamic>)
              : null
          : null,
      projectionAsOfSeq: projections is Map<String, dynamic>
          ? (projections['asOfSeq'] as num?)?.toInt()
          : null,
    );
  }
}

/// One `session/queue` frame item: pending next-turn input that has not been
/// claimed by the agent yet.
class QueueItem {
  const QueueItem({
    required this.id,
    required this.placement,
    required this.text,
  });

  final String id;

  /// `queued` | `steering` | `context` (wire discriminant).
  final String placement;

  /// Concatenated text blocks of the pending message.
  final String text;

  bool get isQueued => placement == 'queued';

  factory QueueItem.fromJson(Map<String, dynamic> json) {
    final message = json['message'];
    final content =
        message is Map<String, dynamic> ? message['content'] : null;
    final buffer = StringBuffer();
    if (content is List) {
      for (final block in content) {
        if (block is Map<String, dynamic> && block['type'] == 'text') {
          final text = block['text'];
          if (text is String) buffer.write(text);
        }
      }
    }
    return QueueItem(
      id: json['id'] as String? ?? '',
      placement: json['placement'] as String? ?? 'queued',
      text: buffer.toString(),
    );
  }
}

/// The `session/queue` frame payload.
class QueueSnapshot {
  const QueueSnapshot({required this.sessionId, required this.items});

  final String sessionId;
  final List<QueueItem> items;

  factory QueueSnapshot.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    return QueueSnapshot(
      sessionId: json['sessionId'] as String? ?? '',
      items: items is List
          ? items
              .whereType<Map<String, dynamic>>()
              .map(QueueItem.fromJson)
              .toList()
          : const [],
    );
  }
}

/// One `host.listDirectory` row: an enterable directory (files are filtered
/// host-side), `hidden` marks dot-directories.
class DirectoryEntry {
  const DirectoryEntry({
    required this.name,
    required this.path,
    required this.hidden,
  });

  final String name;
  final String path;
  final bool hidden;

  factory DirectoryEntry.fromJson(Map<String, dynamic> json) {
    return DirectoryEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      hidden: json['hidden'] == true,
    );
  }
}

/// The `host.listDirectory` response: one directory level plus its breadcrumb
/// ancestry and the `home` anchor. `truncated` flags a cut level (host caps
/// listings at maxEntries, default 1000).
class DirectoryListing {
  const DirectoryListing({
    required this.path,
    required this.home,
    required this.crumbs,
    required this.entries,
    required this.truncated,
  });

  final String path;
  final String home;
  final List<DirectoryEntry> crumbs;
  final List<DirectoryEntry> entries;
  final bool truncated;

  factory DirectoryListing.fromJson(Map<String, dynamic> json) {
    List<DirectoryEntry> rows(Object? raw) => raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(DirectoryEntry.fromJson)
            .toList()
        : const [];
    return DirectoryListing(
      path: json['path'] as String? ?? '',
      home: json['home'] as String? ?? '',
      crumbs: rows(json['crumbs']),
      entries: rows(json['entries']),
      truncated: json['truncated'] == true,
    );
  }
}

/// The `workspace.create` response.
class WorkspaceCreateResult {
  const WorkspaceCreateResult({required this.workspace, required this.created});

  final WorkspaceView workspace;

  /// False when the path was already registered (resolveByPath hit).
  final bool created;

  factory WorkspaceCreateResult.fromJson(Map<String, dynamic> json) {
    final workspace = json['workspace'];
    return WorkspaceCreateResult(
      workspace: workspace is Map<String, dynamic>
          ? WorkspaceView.fromJson(workspace)
          : const WorkspaceView(
              workspaceId: '',
              path: '',
              title: '',
              sessionIds: [],
              createdAt: '',
              updatedAt: '',
            ),
      created: json['created'] == true,
    );
  }
}

/// A provider/model selection (session.models `current` / selectModel).
class ModelSelection {
  const ModelSelection({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  final String provider;
  final String model;
  final String? reasoningEffort;

  factory ModelSelection.fromJson(Map<String, dynamic> json) {
    return ModelSelection(
      provider: json['provider'] as String? ?? '',
      model: json['model'] as String? ?? '',
      reasoningEffort: json['reasoningEffort'] as String?,
    );
  }

  @override
  String toString() => '$provider/$model';
}

/// One reasoning-effort option a model advertises.
class ModelReasoningEffort {
  const ModelReasoningEffort({
    required this.id,
    required this.name,
    this.description,
  });

  final String id;
  final String name;
  final String? description;

  factory ModelReasoningEffort.fromJson(Map<String, dynamic> json) {
    return ModelReasoningEffort(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
    );
  }
}

/// A model's advertised reasoning metadata (efforts + default).
class ModelReasoning {
  const ModelReasoning({required this.efforts, this.defaultEffort});

  final List<ModelReasoningEffort> efforts;
  final String? defaultEffort;

  factory ModelReasoning.fromJson(Map<String, dynamic> json) {
    final efforts = json['efforts'];
    return ModelReasoning(
      efforts: efforts is List
          ? efforts
              .whereType<Map<String, dynamic>>()
              .map(ModelReasoningEffort.fromJson)
              .toList()
          : const [],
      defaultEffort: json['defaultEffort'] as String?,
    );
  }
}

/// One advisory model inside a provider group.
class ModelEntry {
  const ModelEntry({
    required this.id,
    required this.name,
    this.description,
    this.reasoning,
  });

  final String id;
  final String name;
  final String? description;

  /// Advertised reasoning efforts, when the model supports them.
  final ModelReasoning? reasoning;

  factory ModelEntry.fromJson(Map<String, dynamic> json) {
    final reasoning = json['reasoning'];
    return ModelEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      reasoning: reasoning is Map<String, dynamic>
          ? ModelReasoning.fromJson(reasoning)
          : null,
    );
  }
}

/// One provider group of the model catalog.
class ModelProviderGroup {
  const ModelProviderGroup({
    required this.id,
    required this.name,
    required this.models,
  });

  final String id;
  final String name;
  final List<ModelEntry> models;

  factory ModelProviderGroup.fromJson(Map<String, dynamic> json) {
    final models = json['models'];
    return ModelProviderGroup(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      models: models is List
          ? models
              .whereType<Map<String, dynamic>>()
              .map(ModelEntry.fromJson)
              .toList()
          : const [],
    );
  }
}

/// A provider whose catalog could not be loaded.
class ModelCatalogFailure {
  const ModelCatalogFailure({
    required this.id,
    required this.name,
    required this.message,
  });

  final String id;
  final String name;
  final String message;

  factory ModelCatalogFailure.fromJson(Map<String, dynamic> json) {
    return ModelCatalogFailure(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }
}

/// The `session.models` response: current selection, routability, and the
/// advisory provider-grouped catalog.
class ModelCatalog {
  const ModelCatalog({
    required this.current,
    required this.routable,
    required this.groups,
    required this.failures,
  });

  final ModelSelection current;
  final bool routable;
  final List<ModelProviderGroup> groups;
  final List<ModelCatalogFailure> failures;

  factory ModelCatalog.fromJson(Map<String, dynamic> json) {
    final current = json['current'];
    final groups = json['groups'];
    final failures = json['failures'];
    return ModelCatalog(
      current: current is Map<String, dynamic>
          ? ModelSelection.fromJson(current)
          : const ModelSelection(provider: '', model: ''),
      routable: json['routable'] == true,
      groups: groups is List
          ? groups
              .whereType<Map<String, dynamic>>()
              .map(ModelProviderGroup.fromJson)
              .toList()
          : const [],
      failures: failures is List
          ? failures
              .whereType<Map<String, dynamic>>()
              .map(ModelCatalogFailure.fromJson)
              .toList()
          : const [],
    );
  }
}

/// One `skill.list` row: a user-invocable skill (slash-gesture `/name`).
class SkillEntry {
  const SkillEntry({
    required this.name,
    required this.description,
    this.whenToUse,
    required this.modelInvocable,
  });

  final String name;
  final String description;
  final String? whenToUse;

  /// False = user-only (`disable-model-invocation`): only the slash gesture
  /// can invoke it.
  final bool modelInvocable;

  factory SkillEntry.fromJson(Map<String, dynamic> json) {
    return SkillEntry(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      whenToUse: json['whenToUse'] as String?,
      modelInvocable: json['modelInvocable'] == true,
    );
  }
}

/// One option of a user question (ask_user_question).
class QuestionOption {
  const QuestionOption({required this.label, this.description});

  final String label;
  final String? description;

  factory QuestionOption.fromJson(Map<String, dynamic> json) {
    return QuestionOption(
      label: json['label'] as String? ?? '',
      description: json['description'] as String?,
    );
  }
}

/// One question asked by the model (mux `question/requested` frame item).
class Question {
  const Question({
    required this.id,
    required this.question,
    this.header,
    this.detail,
    this.options = const [],
    this.multiSelect = false,
    this.intent,
  });

  final String id;
  final String question;
  final String? header;
  final String? detail;
  final List<QuestionOption> options;
  final bool multiSelect;
  final QuestionIntent? intent;

  factory Question.fromJson(Map<String, dynamic> json) {
    final options = json['options'];
    final intent = json['intent'];
    return Question(
      id: json['id'] as String? ?? '',
      question: json['question'] as String? ?? '',
      header: json['header'] as String?,
      detail: json['detail'] as String?,
      options: options is List
          ? options
              .whereType<Map<String, dynamic>>()
              .map(QuestionOption.fromJson)
              .toList()
          : const [],
      multiSelect: json['multiSelect'] == true,
      intent: intent is Map<String, dynamic>
          ? QuestionIntent.fromJson(intent)
          : null,
    );
  }
}

/// A `question/requested` frame: the model asks the user one batch.
class QuestionBatch {
  const QuestionBatch({required this.rpcId, required this.questions});

  /// The ServerRequest's rpcId — echoed back in the /api/respond payload.
  final String rpcId;
  final List<Question> questions;

  factory QuestionBatch.fromFrame(ServerRequest frame) {
    final payload = frame.payloadMap;
    final questions = payload?['questions'];
    return QuestionBatch(
      rpcId: frame.rpcId,
      questions: questions is List
          ? questions
              .whereType<Map<String, dynamic>>()
              .map(Question.fromJson)
              .toList()
          : const [],
    );
  }
}

/// The question's presentation intent (`intent`): a UI honouring it answers
/// with the [approve] option label and shows [Question.detail] as the plan it
/// reviews (e.g. `plan-review`).
class QuestionIntent {
  const QuestionIntent({required this.kind, required this.approve});

  final String kind;
  final String approve;

  factory QuestionIntent.fromJson(Map<String, dynamic> json) => QuestionIntent(
        kind: json['kind'] as String? ?? '',
        approve: json['approve'] as String? ?? '',
      );
}

/// One `session.search` content-match row.
class SearchItem {
  const SearchItem({required this.sessionId, required this.snippet});

  final String sessionId;
  final String snippet;

  factory SearchItem.fromJson(Map<String, dynamic> json) => SearchItem(
        sessionId: json['sessionId'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
      );
}

/// `session.search` response value (host caps the page at 20 items).
class SearchPage {
  const SearchPage({required this.items, required this.hasMore});

  final List<SearchItem> items;
  final bool hasMore;

  factory SearchPage.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    return SearchPage(
      items: items is List
          ? items
              .whereType<Map<String, dynamic>>()
              .map(SearchItem.fromJson)
              .toList()
          : const [],
      hasMore: json['hasMore'] == true,
    );
  }
}

/// One `commands.list` descriptor (name-sorted; scoped shadowing applied).
class CommandEntry {
  const CommandEntry({
    required this.name,
    required this.description,
    this.inputHint,
  });

  final String name;
  final String description;

  /// The `/name ` input placeholder hint, when the command declares input.
  final String? inputHint;

  factory CommandEntry.fromJson(Map<String, dynamic> json) {
    final input = json['input'];
    return CommandEntry(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      inputHint: input is Map<String, dynamic> ? input['hint'] as String? : null,
    );
  }
}

/// `commands.execute` result. The RPC returns `null` (ok) for an admission
/// miss — unknown or malformed command line.
class CommandExecution {
  const CommandExecution({
    required this.commandId,
    required this.kind,
    this.text,
    this.sourceEventSeq,
  });

  final String commandId;

  /// `success` | `error` (handler outcome).
  final String kind;
  final String? text;
  final int? sourceEventSeq;

  factory CommandExecution.fromJson(Map<String, dynamic> json) {
    final result = json['result'];
    return CommandExecution(
      commandId: json['commandId'] as String? ?? '',
      kind: result is Map<String, dynamic>
          ? result['kind'] as String? ?? ''
          : '',
      text: result is Map<String, dynamic> ? result['text'] as String? : null,
      sourceEventSeq: result is Map<String, dynamic>
          ? (result['sourceEventSeq'] as num?)?.toInt()
          : null,
    );
  }
}

/// Optimistic-concurrency handle for goal mutations (`{id, revision}`).
class GoalRef {
  const GoalRef({required this.id, required this.revision});

  final String id;
  final int revision;

  factory GoalRef.fromJson(Map<String, dynamic> json) => GoalRef(
        id: json['id'] as String? ?? '',
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'id': id, 'revision': revision};
}

/// The current goal snapshot (rides the `goal` session projection).
class GoalSnapshot {
  const GoalSnapshot({
    required this.id,
    required this.revision,
    required this.objective,
    required this.phase,
    required this.maxGoalRounds,
    required this.roundsStarted,
    required this.createdAt,
    required this.updatedAt,
    this.blockedReasonCode,
    this.blockedReasonMessage,
  });

  final String id;
  final int revision;
  final String objective;

  /// active | paused | blocked | complete
  final String phase;
  final int maxGoalRounds;
  final int roundsStarted;
  final int createdAt;
  final int updatedAt;
  final String? blockedReasonCode;
  final String? blockedReasonMessage;

  /// Parse the rc.6 `goal` projection whole value:
  /// `{goal: {id, revision, objective, phase, blockedReason?, maxGoalRounds},
  ///   roundsStarted, createdAt, updatedAt}` — the counters live OUTSIDE the
  /// inner goal object, and the persisted projection carries no `activation`.
  factory GoalSnapshot.fromProjection(Map<String, dynamic> projection) {
    final goal = projection['goal'];
    final inner = goal is Map<String, dynamic> ? goal : const <String, dynamic>{};
    final blocked = inner['blockedReason'];
    return GoalSnapshot(
      id: inner['id'] as String? ?? '',
      revision: (inner['revision'] as num?)?.toInt() ?? 0,
      objective: inner['objective'] as String? ?? '',
      phase: inner['phase'] as String? ?? '',
      maxGoalRounds: (inner['maxGoalRounds'] as num?)?.toInt() ?? 0,
      roundsStarted: (projection['roundsStarted'] as num?)?.toInt() ?? 0,
      createdAt: (projection['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (projection['updatedAt'] as num?)?.toInt() ?? 0,
      blockedReasonCode:
          blocked is Map<String, dynamic> ? blocked['code'] as String? : null,
      blockedReasonMessage: blocked is Map<String, dynamic>
          ? blocked['message'] as String?
          : null,
    );
  }
}

/// One `subagent.list` row (healthy child or diagnostic entry).
class SubagentEntry {
  const SubagentEntry({
    required this.kind,
    required this.id,
    this.mode,
    this.activity,
    this.hasChildren = false,
    this.label,
    this.reason,
  });

  /// child | diagnostic
  final String kind;
  final String id;

  /// one-shot | continuable
  final String? mode;

  /// running | inactive
  final String? activity;
  final bool hasChildren;
  final String? label;
  final String? reason;

  factory SubagentEntry.fromJson(Map<String, dynamic> json) => SubagentEntry(
        kind: json['kind'] as String? ?? '',
        id: json['id'] as String? ?? '',
        mode: json['mode'] as String?,
        activity: json['activity'] as String?,
        hasChildren: json['hasChildren'] == true,
        label: json['label'] as String?,
        reason: json['reason'] as String?,
      );
}

/// `subagent.list` response value.
class SubagentList {
  const SubagentList({required this.entries, required this.parentAvailable});

  final List<SubagentEntry> entries;
  final bool parentAvailable;

  factory SubagentList.fromJson(Map<String, dynamic> json) {
    final entries = json['entries'];
    return SubagentList(
      entries: entries is List
          ? entries
              .whereType<Map<String, dynamic>>()
              .map(SubagentEntry.fromJson)
              .toList()
          : const [],
      parentAvailable: json['parentAvailable'] == true,
    );
  }
}
