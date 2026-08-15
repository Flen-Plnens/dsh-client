/// Headless M4 smoke against a live DSH service:
/// - session.search content search (read-only)
/// - commands.list catalog (read-only)
/// - workspace.insertBefore / insertSessionBefore order round-trip on a
///   throwaway TEMP workspace with a throwaway session
/// - session.selectModel round-trip: switch to another catalog model, then
///   restore the original selection (selectModel persists the deployment
///   default, so the smoke always restores it)
///
/// Usage (pure Dart):
///   dart run tool/m4_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);
  final temp = Platform.environment['TEMP'] ?? '/tmp';
  final name = 'dsh-m4-${DateTime.now().millisecondsSinceEpoch}';
  final dir = Directory('$temp\\$name')..createSync();

  try {
    // 1. session.search (content search over session history). The deployment
    // may disable the query index ("openAt never") — that is the official
    // "content search unavailable" state the client falls back to, so the
    // smoke reports and continues.
    try {
      final page = await gateway.sessionSearch('flutter');
      stdout.writeln('[m4] session.search("flutter") items=${page.items.length} '
          'hasMore=${page.hasMore}');
      for (final item in page.items.take(3)) {
        final snippet = item.snippet.length > 60
            ? '${item.snippet.substring(0, 60)}…'
            : item.snippet;
        stdout.writeln('[m4]   ${item.sessionId.substring(0, 8)}… $snippet');
      }
    } on SessionApiException catch (e) {
      stdout.writeln('[m4] session.search unavailable: ${e.code}: '
          '${e.message.split(':').first}');
    }

    // 2. commands.list catalog (scoped to the most recent session).
    final sessions = await gateway.listSessions();
    final target = sessions
        .where((s) => !s.blank && s.origin != 'subagent')
        .firstOrNull;
    if (target == null) {
      throw StateError('no non-blank session to scope commands.list');
    }
    final commands = await gateway.commandsList(target.sessionId);
    stdout.writeln('[m4] commands.list(agent=${target.sessionId.substring(0, 8)}…) '
        'count=${commands.length}');
    for (final command in commands) {
      final hint = command.inputHint == null ? '' : ' input="${command.inputHint}"';
      stdout.writeln('[m4]   /${command.name} — ${command.description}$hint');
    }

    // 3. Workspace/session order round-trip on a throwaway workspace.
    final created = await gateway.createWorkspace(dir.path);
    final workspaceId = created.workspace.workspaceId;
    final sessionId = await gateway.createSession(workspaceId: workspaceId);
    stdout.writeln('[m4] scratch workspace=$workspaceId session=$sessionId');

    // insertSessionBefore with anchor omitted appends to the end (already the
    // only member — verify the workspace round-trips).
    final updated =
        await gateway.insertSessionBefore(workspaceId, sessionId);
    stdout.writeln('[m4] insertSessionBefore(append) '
        'members=${updated.sessionIds.length} ok=${updated.sessionIds.contains(sessionId)}');

    // workspace.insertBefore: move the scratch workspace to the top.
    var workspaces = await gateway.listWorkspaces();
    final first = workspaces.items.first.workspaceId;
    final order = await gateway.insertWorkspaceBefore(workspaceId,
        beforeWorkspaceId: first);
    final atTop = order.isNotEmpty && order.first == workspaceId;
    stdout.writeln('[m4] insertWorkspaceBefore(top) atTop=$atTop order=${order.length}');

    // 4. selectModel round-trip (restore the original deployment default).
    final catalog = await gateway.sessionModels(sessionId);
    final original = catalog.current;
    stdout.writeln('[m4] models current=${original.provider}/${original.model} '
        'effort=${original.reasoningEffort ?? '-'}');
    final alt = catalog.groups
        .expand((g) => g.models.map((m) => (group: g, entry: m)))
        .where((x) =>
            x.group.id != original.provider || x.entry.id != original.model)
        .firstOrNull;
    if (alt == null) {
      stdout.writeln('[m4] no alternate model to exercise selectModel — skipped');
    } else {
      final switched = await gateway.selectModel(
          sessionId, alt.group.id, alt.entry.id);
      stdout.writeln('[m4] selectModel → ${switched.provider}/${switched.model} '
          'effort=${switched.reasoningEffort ?? '-'}');
      // Restore the original selection (persists the deployment default).
      final restored = await gateway.selectModel(
        sessionId,
        original.provider,
        original.model,
        reasoningEffort: original.reasoningEffort,
      );
      stdout.writeln('[m4] selectModel restored → ${restored.provider}/'
          '${restored.model} effort=${restored.reasoningEffort ?? '-'} '
          'match=${restored.provider == original.provider && restored.model == original.model}');
    }
  } catch (e) {
    stderr.writeln('[m4] FAILED: $e');
    exit(1);
  } finally {
    // Best-effort cleanup of the scratch workspace.
    try {
      final workspaces = await gateway.listWorkspaces();
      final scratch = workspaces.items
          .where((w) => w.path == dir.path)
          .toList();
      for (final workspace in scratch) {
        await gateway.deleteWorkspace(workspace.workspaceId);
      }
    } catch (_) {
      // Cleanup failure is not a smoke failure.
    }
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    await transport.close();
  }
  stdout.writeln('[m4] done');
  exit(0);
}
