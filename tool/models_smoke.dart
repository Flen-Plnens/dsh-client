/// Headless smoke for the model picker / skill menu / rename features against
/// a live DSH service: list the session's model catalog and skills, then do a
/// rename round-trip (rename to a test title, verify, rename back) so the
/// user's session is left untouched. Model selection is NOT exercised live —
/// it persists as the deployment default.
///
/// Usage (pure Dart):
///   dart run tool/models_smoke.dart [http://host:port]
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
    final candidates = sessions
        .where((s) => s.origin != 'subagent' && !s.blank)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (candidates.isEmpty) {
      stdout.writeln('[models] no visible session to inspect');
      return;
    }
    final session = candidates.first;
    final originalTitle = session.title;
    stdout.writeln('[models] session ${session.sessionId} '
        'title="${originalTitle ?? '(none)'}"');

    // 1. Model catalog.
    final catalog = await gateway.sessionModels(session.sessionId);
    stdout.writeln('[models] current=${catalog.current.provider}/${catalog.current.model} '
        'routable=${catalog.routable} groups=${catalog.groups.length} failures=${catalog.failures.length}');
    for (final group in catalog.groups) {
      final models = group.models.map((m) => m.id).join(', ');
      stdout.writeln('[models]   ${group.name} (${group.id}): $models');
    }

    // 2. Skill catalog.
    final skills = await gateway.listSkills(session.sessionId);
    stdout.writeln('[models] skills: ${skills.length}');
    for (final skill in skills.take(8)) {
      stdout.writeln('[models]   ${skill.name} '
          'modelInvocable=${skill.modelInvocable}');
    }

    // 3. Rename round-trip (only when the session has a title to restore).
    if (originalTitle != null && originalTitle.isNotEmpty) {
      final testTitle = '$originalTitle-verify-${DateTime.now().millisecondsSinceEpoch}';
      final renamed = await gateway.renameSession(session.sessionId, testTitle);
      stdout.writeln('[models] rename → "$renamed"');
      final page =
          await gateway.history(session.sessionId, maxMessages: 5);
      stdout.writeln('[models] title projection after rename: "${page.title}" '
          'match=${page.title == testTitle}');
      final restored = await gateway.renameSession(session.sessionId, originalTitle);
      stdout.writeln('[models] rename back → "$restored"');
    } else {
      stdout.writeln('[models] session has no title; skipping rename round-trip');
    }
  } catch (e) {
    stderr.writeln('[models] FAILED: $e');
    exit(1);
  } finally {
    await transport.close();
  }
  stdout.writeln('[models] done');
  exit(0);
}
