/// Session event model: the append-only event log is the session's source of
/// truth. Every event carries `{ type, seq, time, data, ... }`; message-
/// producing events (`user/message`, `assistant/message`, `tool/result`) carry
/// a `surfaceOp` marker (`append` or positional `replace`).
library;

/// How a surface event enters the visible conversation.
enum SurfaceOpKind { append, replace }

/// The `surfaceOp` marker on message-producing events.
class SurfaceOp {
  const SurfaceOp.append()
      : kind = SurfaceOpKind.append,
        start = null,
        end = null;

  const SurfaceOp.replace({required this.start, required this.end})
      : kind = SurfaceOpKind.replace;

  final SurfaceOpKind kind;

  /// Replace only: the seq range shadowed by this event.
  final int? start;
  final int? end;

  /// Parse the wire form (`"append"` or `{op:"replace", start, end}`).
  /// Returns null when absent or unparseable.
  static SurfaceOp? parse(Object? raw) {
    if (raw == null) return null;
    if (raw == 'append') return const SurfaceOp.append();
    if (raw is Map<String, dynamic>) {
      final op = raw['op'];
      final start = raw['start'];
      final end = raw['end'];
      if (op == 'replace' && start is int && end is int) {
        return SurfaceOp.replace(start: start, end: end);
      }
    }
    return null;
  }
}

/// One entry of the session event log.
class SessionEvent {
  const SessionEvent({
    required this.type,
    required this.seq,
    required this.time,
    required this.data,
    this.sourceEventSeqs = const [],
    this.surfaceOp,
    this.ignorable = false,
  });

  final String type;
  final int seq;

  /// Epoch milliseconds.
  final num time;

  /// Wide per-type payload (message, chunk, boundary…). Second-parse at use.
  final Map<String, dynamic> data;
  final List<int> sourceEventSeqs;
  final SurfaceOp? surfaceOp;
  final bool ignorable;

  /// Message-producing event types; these join the folded surface.
  static const Set<String> surfaceTypes = {
    'user/message',
    'assistant/message',
    'tool/result',
  };

  bool get isSurfaceEvent => surfaceTypes.contains(type);

  /// Streaming token deltas of an in-flight assistant message.
  bool get isChunk => type == 'assistant/chunk';

  bool get isAppend => surfaceOp?.kind == SurfaceOpKind.append;
  bool get isReplace => surfaceOp?.kind == SurfaceOpKind.replace;

  /// Parse a wire event. The envelope is strict; `data` stays wide.
  factory SessionEvent.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    final sourceEventSeqs = json['sourceEventSeqs'];
    return SessionEvent(
      type: json['type'] as String? ?? '',
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      time: (json['time'] as num?) ?? 0,
      data: data is Map<String, dynamic> ? data : <String, dynamic>{},
      sourceEventSeqs: sourceEventSeqs is List
          ? sourceEventSeqs.whereType<num>().map((e) => e.toInt()).toList()
          : const [],
      surfaceOp: SurfaceOp.parse(json['surfaceOp']),
      ignorable: json['ignorable'] == true,
    );
  }

  @override
  String toString() => 'SessionEvent($type, seq=$seq)';
}
