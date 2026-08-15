/// Headless M1 smoke test: against a live DSH service, list sessions and
/// workspaces, then open the most recent non-blank session and fold its
/// history through the SurfaceStore.
///
/// Usage (pure Dart):
///   dart run tool/m1_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  stdout.writeln('[m1] connecting to $address');

  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);

  try {
    final sessions = await gateway.listSessions();
    stdout.writeln('[m1] sessions: ${sessions.length}');
    for (final s in sessions.take(6)) {
      stdout.writeln(
          '[m1]   ${s.sessionId} running=${s.running} blank=${s.blank} cwd=${s.cwd ?? '-'}');
    }

    final workspaces = await gateway.listWorkspaces();
    stdout.writeln('[m1] workspaces: ${workspaces.items.length}');
    for (final w in workspaces.items) {
      stdout.writeln(
          '[m1]   "${w.title}" path=${w.path} sessions=${w.sessionIds.length}');
    }

    final candidates = sessions.where((s) => !s.blank).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (candidates.isEmpty) {
      stdout.writeln('[m1] no non-blank session to open');
    } else {
      final session = candidates.first;
      stdout.writeln('[m1] opening ${session.sessionId} …');
      final page =
          await gateway.history(session.sessionId, maxMessages: 120);
      final store = SurfaceStore();
      store.load(page.events);
      stdout.writeln(
          '[m1] history: ${page.events.length} events → ${store.messages.length} messages, '
          'hasMore=${page.hasMore}, toleratedSkips=${store.toleratedSkips}, '
          'streaming=${store.streaming?.isEmpty == false}, partials=${store.partials.length}');
      final contexts =
          store.messages.where((m) => m.kind == MessageKind.context).length;
      stdout.writeln('[m1] context rows: $contexts');
      for (final m in store.messages.take(10)) {
        final text = m.text.replaceAll('\n', ' ');
        final snippet = text.length > 60 ? '${text.substring(0, 60)}…' : text;
        final parts = <String>['${m.kind}'];
        if (m.kind == MessageKind.context) {
          parts.add('[${m.producerLabel ?? m.sourceKind ?? '?'}]');
        }
        if (m.reasoning != null) parts.add('[reasoning ${m.reasoning!.length}ch]');
        if (m.toolCalls.isNotEmpty) {
          parts.add('[tool:${m.toolCalls.map((t) => t.name).join(',')}]');
        }
        if (m.toolResultToolCallId != null) {
          parts.add('[result ${m.toolIsError ? "ERR" : "ok"}]');
        }
        if (!m.complete) parts.add('[partial]');
        stdout.writeln('[m1]   ${parts.join(' ')}: $snippet');
      }
    }
  } catch (e) {
    stderr.writeln('[m1] FAILED: $e');
    exit(1);
  } finally {
    await transport.close();
  }
  stdout.writeln('[m1] done');
  exit(0);
}
