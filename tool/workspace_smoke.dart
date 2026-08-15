/// Headless workspace-creation smoke test against a live DSH service.
///
/// Verifies the directory-picker capability the deployment serves (browse via
/// `host.listDirectory`, or the native fallback), then exercises the real
/// workspace-creation core: create a directory, adopt it as a Workspace,
/// confirm `workspace.list`, confirm idempotent re-adoption, and clean up the
/// registration via the raw `workspace.delete` RPC (not in the client UI yet)
/// plus removal of the temp directory.
///
/// Usage (pure Dart):
///   dart run tool/workspace_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);
  final temp = Platform.environment['TEMP'] ?? '/tmp';
  final name = 'dsh-flutter-verify-${DateTime.now().millisecondsSinceEpoch}';

  try {
    // 1. Probe the served directory-picker capability.
    try {
      final home = await gateway.listDirectory();
      stdout.writeln('[ws] browse capability OK: home=${home.path} '
          '(${home.entries.length} entries)');
      final createdPath = await gateway.createDirectory(home.path, name);
      stdout.writeln('[ws] created directory via browse: $createdPath');
    } on SessionApiException catch (e) {
      stdout.writeln(
          '[ws] browse unavailable: code=${e.code} message=${e.message}');
      if (e.code != 'directory-picker-unavailable') rethrow;
    }

    // 2. Core creation loop (independent of the picker backend): create the
    //    directory with dart:io, adopt it as a Workspace.
    final dir = Directory('$temp\\$name')..createSync();
    final createdPath = dir.path;
    stdout.writeln('[ws] created directory: $createdPath');

    final created = await gateway.createWorkspace(createdPath);
    stdout.writeln('[ws] workspace.create → created=${created.created} '
        'id=${created.workspace.workspaceId} title=${created.workspace.title}');

    final workspaces = await gateway.listWorkspaces();
    final found = workspaces.items
        .any((w) => w.workspaceId == created.workspace.workspaceId);
    stdout.writeln('[ws] workspace.list contains it: $found '
        '(total ${workspaces.items.length})');
    if (!found) throw StateError('created workspace missing from list');

    // 3. Re-adopting the same path is idempotent (resolveByPath hit).
    final again = await gateway.createWorkspace(createdPath);
    stdout.writeln('[ws] re-adopt → created=${again.created} '
        'sameId=${again.workspace.workspaceId == created.workspace.workspaceId}');

    // 4. Cleanup: drop the registration via the raw wire and remove the dir.
    final response = await transport.call('workspace.delete', {
      'workspaceId': created.workspace.workspaceId,
    });
    final deleted =
        response.result.ok && (response.result.value as Map?)?['deleted'] == true;
    stdout.writeln('[ws] workspace.delete → deleted=$deleted');
    dir.deleteSync();
    stdout.writeln('[ws] temp directory removed');

    final after = await gateway.listWorkspaces();
    final gone = after.items
        .every((w) => w.workspaceId != created.workspace.workspaceId);
    stdout.writeln('[ws] workspace.list clean again: $gone');
  } catch (e) {
    stderr.writeln('[ws] FAILED: $e');
    exit(1);
  } finally {
    await transport.close();
  }
  stdout.writeln('[ws] done');
  exit(0);
}
