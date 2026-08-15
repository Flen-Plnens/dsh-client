/// Real-data inspector: pulls several history pages of a session and prints
/// event-type distribution, non-user user/message sources, turn endings, and
/// the tail of the log — used to ground the M1 fixes in actual Harness data.
///
/// Usage:
///   dart run tool/inspect_session.dart `<sessionId>` [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/session/session_event.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

String _short(String s) =>
    s.length > 60 ? '${s.substring(0, 60)}…' : s;

String _snippet(SessionEvent e) {
  final data = e.data;
  final message = data['message'];
  final content = message is Map<String, dynamic> ? message['content'] : data['content'];
  if (content is List) {
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String? ?? '')
        .join();
    return text.length > 70 ? '${text.substring(0, 70)}…' : text;
  }
  return '';
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/inspect_session.dart <sessionId> [address]');
    exit(2);
  }
  final sessionId = args[0];
  final address = args.length > 1 ? args[1] : 'http://127.0.0.1:3080';

  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);

  final all = <SessionEvent>[];
  int? beforeSeq;
  var hasMore = true;
  var pages = 0;
  while (hasMore && pages < 25) {
    final page =
        await gateway.history(sessionId, beforeSeq: beforeSeq, maxMessages: 300);
    all.insertAll(0, page.events);
    hasMore = page.hasMore && page.events.isNotEmpty;
    beforeSeq = page.events.isEmpty ? null : page.events.first.seq;
    pages++;
    if (page.events.isEmpty) break;
  }
  stdout.writeln('[inspect] $sessionId: $pages pages, ${all.length} events');

  final counts = <String, int>{};
  for (final e in all) {
    counts[e.type] = (counts[e.type] ?? 0) + 1;
  }
  stdout.writeln('--- event type counts ---');
  for (final entry in counts.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }

  stdout.writeln('--- user/message with source.kind != "user" ---');
  var contextMessages = 0;
  for (final e in all.where((e) => e.type == 'user/message')) {
    final source = e.data['source'];
    if (source is Map<String, dynamic> && source['kind'] != 'user') {
      contextMessages++;
      final snippet = _snippet(e);
      stdout.writeln(
          '  seq=${e.seq} surfaceOp=${e.surfaceOp?.kind} source=$source text="${snippet.isEmpty ? '(no text block)' : snippet}"');
    }
  }
  if (contextMessages == 0) stdout.writeln('  (none in window)');

  stdout.writeln('--- turn/end (last 6) ---');
  final turnEnds = all.where((e) => e.type == 'turn/end').toList();
  for (final e in turnEnds.skip(turnEnds.length > 6 ? turnEnds.length - 6 : 0)) {
    stdout.writeln('  seq=${e.seq} data=${e.data}');
  }

  stdout.writeln('--- last 14 events ---');
  for (final e in all.skip(all.length > 14 ? all.length - 14 : 0)) {
    final snippet = _snippet(e);
    final chunk = e.data['chunk'];
    stdout.writeln(
        '  seq=${e.seq} ${e.type} op=${e.surfaceOp?.kind ?? '-'} chunk=${chunk is Map<String, dynamic> ? chunk['type'] : '-'} ${snippet.isEmpty ? '' : 'text=$snippet'}');
  }

  // Fold the collected window exactly like the client would.
  final store = SurfaceStore();
  store.load(all);
  stdout.writeln('--- fold result ---');
  stdout.writeln(
      '  nodes=${store.messages.length} tolerated=${store.toleratedSkips} streaming=${store.streaming?.isEmpty == false} partials=${store.partials.length}');
  final contextRows = store.messages.where((m) => m.kind == MessageKind.context).toList();
  stdout.writeln('  context rows: ${contextRows.length}');
  for (final m in contextRows.take(10)) {
    stdout.writeln(
        '  [${m.sourceKind ?? '-'}] ${m.producerLabel ?? '-'}: ${_short(m.text.replaceAll('\n', ' '))}');
  }
  for (final m in store.messages.skip(store.messages.length > 6 ? store.messages.length - 6 : 0)) {
    stdout.writeln(
        '  ${m.kind} seq=${m.seq} complete=${m.complete} sourceKind=${m.sourceKind ?? '-'} text="${_short(m.text)}"');
  }

  await transport.close();
  stdout.writeln('[inspect] done');
  exit(0);
}
