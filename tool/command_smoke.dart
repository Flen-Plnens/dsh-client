/// Headless command-lifecycle smoke against a live DSH service:
/// - create a throwaway session, execute `/goal` (read-only view: no args)
/// - the host durably logs `command/run` + `command/done`
/// - fetch history, fold it with the real SurfaceStore, and check the
///   command row rendered (kind=command, outcome set)
/// - archive the throwaway session to hide it from the lists
///
/// Usage:
///   dart run tool/command_smoke.dart [http://host:port]
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);

  try {
    final sessionId = await gateway.createSession();
    stdout.writeln('[cmd] throwaway session=${sessionId.substring(0, 8)}…');

    final execution = await gateway.commandsExecute(sessionId, '/goal');
    stdout.writeln('[cmd] execute /goal → '
        '${execution == null ? 'admission miss' : '${execution.kind} (${execution.commandId})'}');

    // Give the durable log a moment to drain the lifecycle appends.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final page = await gateway.history(sessionId, maxMessages: 20);
    final runEvents =
        page.events.where((e) => e.type == 'command/run').toList();
    final doneEvents =
        page.events.where((e) => e.type == 'command/done').toList();
    stdout.writeln('[cmd] history: command/run=${runEvents.length} '
        'command/done=${doneEvents.length}');

    final store = SurfaceStore();
    store.load(page.events);
    final commandViews =
        store.messages.where((m) => m.kind == MessageKind.command).toList();
    stdout.writeln('[cmd] folded command rows=${commandViews.length}');
    for (final view in commandViews) {
      stdout.writeln('[cmd]   /${view.commandName ?? '?'} '
          'outcome=${view.commandOutcome ?? 'pending'} '
          'text=${view.commandOutcomeText ?? '-'}');
    }
    if (commandViews.isEmpty) {
      throw StateError('no command row folded from real lifecycle events');
    }

    // Hide the throwaway session.
    await gateway.archiveSession(sessionId);
    stdout.writeln('[cmd] archived throwaway session');
  } catch (e) {
    stderr.writeln('[cmd] FAILED: $e');
    exit(1);
  } finally {
    await transport.close();
  }
  stdout.writeln('[cmd] done');
  exit(0);
}
