/// Headless M3 Final smoke against a live DSH service:
/// - workspace rename/delete round-trip on a throwaway TEMP workspace
/// - session archive on a fresh throwaway session
/// - model catalog incl. reasoning metadata
///
/// Usage (pure Dart):
///   dart run tool/mfinal_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);
  final temp = Platform.environment['TEMP'] ?? '/tmp';
  final name = 'dsh-mfinal-${DateTime.now().millisecondsSinceEpoch}';
  final dir = Directory('$temp\\$name')..createSync();

  try {
    // 1. Workspace rename/delete round-trip.
    final created = await gateway.createWorkspace(dir.path);
    stdout.writeln('[final] workspace.create id=${created.workspace.workspaceId} '
        'title=${created.workspace.title}');

    final newTitle = '$name-renamed';
    await gateway.renameWorkspace(created.workspace.workspaceId, newTitle);
    var workspaces = await gateway.listWorkspaces();
    final renamed = workspaces.items
        .firstWhere((w) => w.workspaceId == created.workspace.workspaceId);
    stdout.writeln('[final] workspace.rename → title=${renamed.title} '
        'match=${renamed.title == newTitle}');

    await gateway.deleteWorkspace(created.workspace.workspaceId);
    workspaces = await gateway.listWorkspaces();
    final gone = workspaces.items
        .every((w) => w.workspaceId != created.workspace.workspaceId);
    stdout.writeln('[final] workspace.delete → gone=$gone');

    // 2. Session archive on a fresh throwaway session.
    final sessionId = await gateway.createSession();
    await gateway.archiveSession(sessionId);
    workspaces = await gateway.listWorkspaces();
    final archived = workspaces.archivedSessionIds.contains(sessionId);
    stdout.writeln('[final] archiveSession(${sessionId.substring(0, 8)}…) '
        '→ archivedInList=$archived');

    // 3. Model catalog with reasoning metadata.
    final catalog = await gateway.sessionModels(sessionId);
    stdout.writeln('[final] models current=${catalog.current.provider}/'
        '${catalog.current.model} groups=${catalog.groups.length}');
    for (final group in catalog.groups) {
      for (final model in group.models) {
        final efforts = model.reasoning == null
            ? '-'
            : model.reasoning!.efforts.map((e) => e.id).join(',');
        stdout.writeln('[final]   ${group.id}/${model.id} reasoning=[$efforts]');
      }
    }
  } catch (e) {
    stderr.writeln('[final] FAILED: $e');
    exit(1);
  } finally {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    await transport.close();
  }
  stdout.writeln('[final] done');
  exit(0);
}
