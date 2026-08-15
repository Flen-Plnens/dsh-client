/// Human-transcript projection over the append-only event log.
///
/// Ports the official client's chat-transcript semantics
/// (`dsh-client-ui-conversation` ConversationNodeAssembler) plus its message
/// classification (`dsh-client-runtime` `contextProvenance`):
///
/// - `user/message`, `assistant/message`, `tool/result` are surface events;
///   `assistant/message` content lives under `data.message`, while a
///   `user/message` IS the message and a `tool/result` message lives under
///   `data.message`.
/// - The transcript is built from **append-origin** events
///   (`surfaceOp == "append"`). A positional replacement
///   (`surfaceOp: {op:"replace", start, end}`) restates a shadowed range for
///   the model alone — it never enters the transcript and never removes the
///   messages the user already saw. This is exactly how compaction checkpoints
///   (a replacement `user/message` whose source is `{kind:"plugin",
///   plugin:"compact"}`) and `tool/result` rewrites stay model-only while the
///   original history and tool output remain visible.
/// - A `user/message` whose `data.source.kind` is NOT `"user"` is an injected
///   context row (system prompt snapshot, skill catalog, subagent
///   report/settled notices, background-job notices, …), never a user bubble.
/// - `assistant/chunk` events stream the in-flight assistant message: deltas
///   accumulate per block `index` (text/reasoning/tool-call). The preview is
///   superseded by the final `assistant/message`; a `turn/end` (or any other
///   append-origin surface event arriving mid-stream) finalizes the partial
///   into a message so interrupted turns keep their partial output.
///
/// Non-strict mode tolerates partial pages (history pagination): a seq gap is
/// counted instead of throwing.
library;

import 'session_event.dart';

/// What a rendered bubble looks like.
enum MessageKind { user, assistant, toolResult, context, command }

/// A tool call inside an assistant message.
class ToolCallView {
  const ToolCallView({required this.id, required this.name, this.arguments = ''});

  final String id;
  final String name;
  final String arguments;
}

/// A durable image reference inside a message's content (fetch bytes via
/// session.attachment).
class ImageRefView {
  const ImageRefView({
    required this.attachmentId,
    this.mediaType,
    this.width,
    this.height,
  });

  final String attachmentId;
  final String? mediaType;
  final int? width;
  final int? height;

  factory ImageRefView.fromJson(Map<String, dynamic> json) {
    return ImageRefView(
      attachmentId: json['attachmentId'] as String? ?? '',
      mediaType: json['mediaType'] as String?,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
    );
  }
}

/// One folded, renderable message.
class MessageView {
  const MessageView({
    required this.seq,
    this.id,
    required this.kind,
    this.text = '',
    this.reasoning,
    this.toolCalls = const [],
    this.toolResultToolCallId,
    this.toolIsError = false,
    this.sourceKind,
    this.producerLabel,
    this.contextForm,
    this.senderSessionId,
    this.images = const [],
    this.complete = true,
    this.commandId,
    this.commandName,
    this.commandArgs,
    this.commandOutcome,
    this.commandOutcomeText,
  });

  final int seq;

  /// Message id when the wire carried one.
  final String? id;
  final MessageKind kind;

  /// Concatenated text blocks (or tool-result content snippet).
  final String text;

  /// Assistant reasoning blocks, if any.
  final String? reasoning;
  final List<ToolCallView> toolCalls;

  /// tool/result nodes: the call id this result answers, and its outcome.
  final String? toolResultToolCallId;
  final bool toolIsError;

  /// The durable message `source.kind` (user / plugin / subagent-report / …).
  final String? sourceKind;

  /// Context rows: the producer label presented to the user (plugin name,
  /// reference label, skill name, or the source kind itself).
  final String? producerLabel;

  /// Context rows: the wire `source.form` presentation hint
  /// (instructions / catalog / snapshot / notice / relay / recall / null).
  final String? contextForm;

  /// Subagent relay/settled context rows: the child session that reported.
  final String? senderSessionId;

  /// Image blocks in this message (attachment refs; bytes via session.attachment).
  final List<ImageRefView> images;

  /// False when this message is a partial (interrupted turn) finalized from
  /// the chunk stream without a terminal `assistant/message`.
  final bool complete;

  /// Command rows (`MessageKind.command`): the durable lifecycle of a slash
  /// command — `command/run` opens the row, `command/done` pairs by
  /// [commandId] and sets [commandOutcome].
  final String? commandId;
  final String? commandName;
  final String? commandArgs;

  /// `null` (pending) | `success` | `error`.
  final String? commandOutcome;
  final String? commandOutcomeText;

  @override
  String toString() => 'MessageView($kind, seq=$seq, text=${text.length}ch)';
}

/// Live preview of an in-flight assistant message (chunk accumulation).
class StreamingAssistant {
  final Map<int, _PartialBlock> _blocks = {};
  final List<int> _order = [];

  bool get isEmpty => _blocks.isEmpty;

  /// Push one wire chunk (`data.chunk` object).
  void push(Map<String, dynamic> chunk) {
    final index = chunk['index'];
    if (index is! int) return;
    switch (chunk['type']) {
      case 'text-delta':
        final text = chunk['text'];
        if (text is String) _ensure(index, 'text').text += text;
      case 'reasoning-delta':
        final text = chunk['text'];
        if (text is String) _ensure(index, 'reasoning').text += text;
      case 'tool-call-delta':
        final partial = _ensure(index, 'tool-call');
        if (partial.closed) return;
        partial.toolCallId = partial.toolCallId.isEmpty
            ? (chunk['id'] as String? ?? '')
            : partial.toolCallId;
        final name = chunk['name'];
        if (name is String && partial.toolCallName.isEmpty) {
          partial.toolCallName = name;
        }
        final args = chunk['argumentsDelta'];
        if (args is String) partial.toolCallArguments += args;
      case 'block-end':
        final block = chunk['block'];
        if (block is Map<String, dynamic>) {
          final partial = _ensure(index, block['type'] as String? ?? 'text');
          partial.closed = true;
        }
    }
  }

  _PartialBlock _ensure(int index, String blockType) {
    var partial = _blocks[index];
    if (partial == null) {
      partial = _PartialBlock(blockType);
      _blocks[index] = partial;
      _order.add(index);
    }
    return partial;
  }

  String get text => _render('text');
  String get reasoning => _render('reasoning');

  List<ToolCallView> get toolCalls => _order
      .map((i) => _blocks[i])
      .whereType<_PartialBlock>()
      .where((p) => p.blockType == 'tool-call')
      .map((p) => ToolCallView(
          id: p.toolCallId, name: p.toolCallName, arguments: p.toolCallArguments))
      .toList();

  String _render(String blockType) {
    final buf = StringBuffer();
    for (final i in _order) {
      final partial = _blocks[i];
      if (partial == null) continue;
      if (partial.blockType == blockType) buf.write(partial.text);
    }
    return buf.toString();
  }
}

class _PartialBlock {
  _PartialBlock(this.blockType);

  final String blockType;
  String text = '';
  String toolCallId = '';
  String toolCallName = '';
  String toolCallArguments = '';
  bool closed = false;
}

/// Listener signature (same shape as ConnectionController).
typedef SurfaceListener = void Function();

/// Incremental human-transcript projection over one session's events.
class SurfaceStore {
  final List<SessionEvent> _log = [];
  final List<MessageView> _transcript = [];
  final List<MessageView> _partials = [];
  final List<SurfaceListener> _listeners = [];

  StreamingAssistant? _streaming;
  bool _strict = false;
  int _tolerated = 0;
  int _lastChunkSeq = 0;

  /// Partials finalized from interrupted turns (rendered after nodes, then
  /// re-sorted by seq so they interleave correctly).
  List<MessageView> get partials => List.unmodifiable(_partials);

  /// All renderable messages in seq order: append-origin transcript messages
  /// plus any finalized partials from interrupted turns.
  List<MessageView> get messages {
    final views = <MessageView>[
      ..._transcript,
      ..._partials,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    return views;
  }

  /// Live in-flight assistant preview (null when idle).
  StreamingAssistant? get streaming => _streaming;

  /// The full event log held by this store (for pagination combining).
  List<SessionEvent> get log => List.unmodifiable(_log);

  /// Number of non-contiguous seq gaps tolerated during a non-strict replay.
  int get toleratedSkips => _tolerated;

  bool get isEmpty =>
      _transcript.isEmpty && _partials.isEmpty && (_streaming == null || _streaming!.isEmpty);

  void addListener(SurfaceListener listener) => _listeners.add(listener);

  void removeListener(SurfaceListener listener) => _listeners.remove(listener);

  /// Replay a contiguous (or tolerated non-strict) event range — history
  /// loads and pagination. Replaces the current state.
  ///
  /// Chunks replayed at the tail of a still-running turn are kept as the live
  /// preview (a running session stays "streaming"); a `turn/end` in the log
  /// finalizes an interrupted preview into a partial message.
  void load(List<SessionEvent> events, {bool strict = false}) {
    _log
      ..clear()
      ..addAll(events);
    _transcript.clear();
    _partials.clear();
    _streaming = null;
    _strict = strict;
    _tolerated = 0;
    var expected = events.isEmpty ? null : events.first.seq;
    for (final event in events) {
      if (expected != null && event.seq != expected) {
        if (_strict) {
          throw FormatException(
              'non-contiguous seq: expected $expected, got ${event.seq}');
        }
        _tolerated += 1;
      }
      _apply(event);
      expected = event.seq + 1;
    }
    _notify();
  }

  /// Apply one live event (mux frame) incrementally. Stale/duplicate seqs
  /// are ignored.
  void apply(SessionEvent event) {
    if (_log.isNotEmpty) {
      final last = _log.last.seq;
      if (event.seq <= last) return;
    }
    _log.add(event);
    _apply(event);
    _notify();
  }

  void _apply(SessionEvent event) {
    if (event.isChunk) {
      _streaming ??= StreamingAssistant();
      final chunk = event.data['chunk'];
      if (chunk is Map<String, dynamic>) {
        _lastChunkSeq = event.seq;
        _streaming!.push(chunk);
      }
      return;
    }

    // Command lifecycle: `command/run` opens a persistent row,
    // `command/done` pairs by commandId and sets the outcome. Both are direct
    // log-only appends — no turn wraps them, so they never finalize a
    // streaming preview, and replacement (compaction) never re-renders them.
    if (event.type == 'command/run' || event.type == 'command/done') {
      if (event.isReplace) return;
      if (event.type == 'command/run') {
        final view = _deriveCommandRun(event);
        if (view != null) _transcript.add(view);
      } else {
        _applyCommandDone(event);
      }
      return;
    }

    if (!event.isSurfaceEvent) {
      // A turn boundary is the definitive "no more chunks" signal: an
      // interrupted preview becomes a partial message.
      if (event.type == 'turn/end') _finalizeStreaming();
      return;
    }

    // Positional replacements restate a shadowed range for the model alone:
    // they never enter the human transcript and never remove the append-origin
    // messages the user already saw. This covers compaction checkpoints
    // (replacement `user/message` from the compact plugin) and `tool/result`
    // rewrites — both stay model-only, the original history remains visible.
    if (event.isReplace) return;

    if (event.type == 'assistant/message') {
      // The final message supersedes the chunk preview.
      _streaming = null;
    } else {
      // A user message or tool result arriving mid-stream means the previous
      // assistant turn ended without a final message — keep the partial text.
      _finalizeStreaming();
    }

    final view = _derive(event);
    if (view != null) _transcript.add(view);
  }

  /// Convert the current chunk preview into a finalized partial message (or
  /// drop it when it carries no output).
  void _finalizeStreaming() {
    final s = _streaming;
    if (s == null) return;
    _streaming = null;
    if (s.isEmpty) return;
    _partials.add(MessageView(
      seq: _lastChunkSeq,
      kind: MessageKind.assistant,
      text: s.text,
      reasoning: s.reasoning.isEmpty ? null : s.reasoning,
      toolCalls: s.toolCalls,
      complete: false,
    ));
  }

  MessageView? _derive(SessionEvent event) {
    switch (event.type) {
      case 'user/message':
        return _deriveUserMessage(event);
      case 'assistant/message':
        final message = event.data['message'];
        if (message is! Map<String, dynamic>) return null;
        final content = message['content'];
        if (content is List && content.isEmpty) return null;
        return _deriveMessage(event.seq, message, MessageKind.assistant);
      case 'tool/result':
        final message = event.data['message'];
        if (message is! Map<String, dynamic>) return null;
        return _deriveToolResult(event.seq, message);
      default:
        return null;
    }
  }

  /// `command/run`: open the persistent command row (official `commandFromRun`
  /// — seq/time/commandId/name/args, outcome pending).
  MessageView? _deriveCommandRun(SessionEvent event) {
    final data = event.data;
    final name = data['name'];
    if (name is! String || name.isEmpty) return null;
    return MessageView(
      seq: event.seq,
      kind: MessageKind.command,
      commandId: data['commandId'] as String?,
      commandName: name,
      commandArgs: data['args'] as String?,
      commandOutcome: null,
    );
  }

  /// `command/done`: pair with the pending row by commandId and set the
  /// outcome (official `commandFromDone`). A done without a prior run in this
  /// window (pagination boundary) renders as a standalone row.
  void _applyCommandDone(SessionEvent event) {
    final data = event.data;
    final commandId = data['commandId'];
    if (commandId is! String || commandId.isEmpty) return;
    final outcome = data['kind'] is String ? data['kind'] as String : null;
    final text = data['text'] as String?;
    final index = _transcript.indexWhere((v) => v.commandId == commandId);
    if (index >= 0) {
      final existing = _transcript[index];
      _transcript[index] = MessageView(
        seq: existing.seq,
        kind: MessageKind.command,
        commandId: existing.commandId,
        commandName: existing.commandName,
        commandArgs: existing.commandArgs,
        commandOutcome: outcome,
        commandOutcomeText: text,
      );
    } else {
      _transcript.add(MessageView(
        seq: event.seq,
        kind: MessageKind.command,
        commandId: commandId,
        commandName: null,
        commandOutcome: outcome,
        commandOutcomeText: text,
      ));
    }
  }

  /// Official `messageDefinition`: a `user/message` whose source is not the
  /// human user is an injected-context row (steering/injections/notices),
  /// never a user bubble.
  MessageView? _deriveUserMessage(SessionEvent event) {
    final message = event.data;
    final source = message['source'];
    final kind = source is Map<String, dynamic> ? source['kind'] : null;
    final sender =
        source is Map<String, dynamic> ? source['senderSessionId'] : null;
    if (kind != 'user') {
      final form = source is Map<String, dynamic> ? source['form'] : null;
      return _deriveMessage(
        event.seq,
        message,
        MessageKind.context,
        sourceKind: kind is String ? kind : null,
        producerLabel: _contextLabel(source, kind),
        contextForm: form is String ? form : null,
        senderSessionId: sender is String ? sender : null,
      );
    }
    return _deriveMessage(event.seq, message, MessageKind.user,
        sourceKind: 'user');
  }

  /// Merge-extensible producer label, mirroring official `contextProvenance`:
  /// labels come from the wire record; unknown kinds degrade to the kind
  /// itself rather than a hardcoded mapping.
  String? _contextLabel(Object? source, Object? kind) {
    if (source is! Map<String, dynamic>) return null;
    switch (kind) {
      case 'plugin':
        return source['plugin'] as String?;
      case 'session-reference':
        final references = source['references'];
        if (references is List) {
          for (final ref in references) {
            if (ref is Map<String, dynamic> && ref['label'] is String) {
              return ref['label'] as String;
            }
          }
        }
        return 'session-reference';
      case 'agent-instructions':
        final changes = source['changes'];
        if (changes is List) {
          for (final change in changes) {
            if (change is Map<String, dynamic> && change['path'] is String) {
              return change['path'] as String;
            }
          }
        }
        return 'agent-instructions';
      case 'skill-invocation':
        return source['name'] as String? ?? 'skill-invocation';
      default:
        return kind is String ? kind : null;
    }
  }

  MessageView _deriveMessage(
    int seq,
    Map<String, dynamic> message,
    MessageKind kind, {
    String? sourceKind,
    String? producerLabel,
    String? contextForm,
    String? senderSessionId,
  }) {
    final textBuf = StringBuffer();
    final reasoningBuf = StringBuffer();
    final toolCalls = <ToolCallView>[];
    final images = <ImageRefView>[];
    final content = message['content'];
    if (content is List) {
      for (final block in content) {
        if (block is! Map<String, dynamic>) continue;
        switch (block['type']) {
          case 'text':
            final text = block['text'];
            if (text is String) textBuf.write(text);
          case 'reasoning':
            final text = block['text'];
            if (text is String) reasoningBuf.write(text);
          case 'tool-call':
            toolCalls.add(ToolCallView(
              id: block['id'] as String? ?? '',
              name: block['name'] as String? ?? '',
              arguments: block['arguments'] as String? ?? '',
            ));
          case 'image':
            final attachment = block['attachment'];
            if (attachment is Map<String, dynamic>) {
              images.add(ImageRefView.fromJson(attachment));
            }
            textBuf.write('[图片]');
        }
      }
    }
    final reasoning = reasoningBuf.isEmpty ? null : reasoningBuf.toString();
    return MessageView(
      seq: seq,
      id: message['id'] as String?,
      kind: kind,
      text: textBuf.toString(),
      reasoning: reasoning,
      toolCalls: toolCalls,
      sourceKind: sourceKind,
      producerLabel: producerLabel,
      contextForm: contextForm,
      senderSessionId: senderSessionId,
      images: images,
    );
  }

  MessageView _deriveToolResult(int seq, Map<String, dynamic> message) {
    String? toolCallId;
    var isError = false;
    final textBuf = StringBuffer();
    final content = message['content'];
    if (content is List) {
      for (final block in content) {
        if (block is! Map<String, dynamic>) continue;
        if (block['type'] != 'tool-result') continue;
        toolCallId = block['toolCallId'] as String?;
        isError = block['isError'] == true;
        final inner = block['content'];
        if (inner is List) {
          for (final nested in inner) {
            if (nested is Map<String, dynamic> && nested['type'] == 'text') {
              final text = nested['text'];
              if (text is String) textBuf.write(text);
            }
          }
        } else if (inner is String) {
          textBuf.write(inner);
        }
      }
    }
    return MessageView(
      seq: seq,
      id: message['id'] as String?,
      kind: MessageKind.toolResult,
      text: textBuf.toString(),
      toolResultToolCallId: toolCallId,
      toolIsError: isError,
    );
  }

  void _notify() {
    for (final listener in List<SurfaceListener>.of(_listeners)) {
      listener();
    }
  }
}
