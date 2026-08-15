/// Headless session-title smoke test against a live DSH service: parses the
/// real `session.list` rows with the fixed models and prints each row's title
/// projection, then opens one session's history tail and prints the seeded
/// title — validating the list/AppBar title data flow against real rc.6.
///
/// Usage (pure Dart):
///   dart run tool/title_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);

  try {
    final sessions = await gateway.listSessions();
    stdout.writeln('[title] session.list rows: ${sessions.length}');
    var withTitle = 0;
    for (final s in sessions) {
      final title = s.title;
      stdout.writeln(
          '[title]   ${s.sessionId} → "${title ?? '(no title)'}" cwd=${s.cwd ?? '-'}');
      if (title != null && title.isNotEmpty) withTitle++;
    }
    stdout.writeln('[title] rows with a title projection: $withTitle');

    final titled =
        sessions.where((s) => s.title != null && s.title!.isNotEmpty).toList();
    if (titled.isNotEmpty) {
      final session = titled.first;
      final page =
          await gateway.history(session.sessionId, maxMessages: 5);
      stdout.writeln('[title] history tail of ${session.sessionId}: '
          'seededTitle="${page.title ?? '(none)'}" '
          'match=${page.title == session.title}');
    }
  } catch (e) {
    stderr.writeln('[title] FAILED: $e');
    exit(1);
  } finally {
    await transport.close();
  }
  stdout.writeln('[title] done');
  exit(0);
}
