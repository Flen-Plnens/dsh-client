/// Headless T2 smoke against a live DSH service:
/// - session.fork: fork a throwaway session, verify the child lists with
///   parentSessionId and no origin (stays visible)
/// - session.export: download the ZIP and check the PK magic
/// - goal.create: create a goal and read it back from the history projections
/// - subagent.list: empty catalog on a leaf session, parentAvailable
/// - archive both throwaway sessions afterwards
///
/// Usage:
///   dart run tool/t2_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/session/session_models.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);
  final created = <String>[];

  try {
    final sessionId = await gateway.createSession();
    created.add(sessionId);
    stdout.writeln('[t2] throwaway=${sessionId.substring(0, 8)}…');

    // 1. Export (works on any session).
    final zip = await gateway.exportSession(sessionId);
    final isZip = zip.length > 4 &&
        zip[0] == 0x50 && zip[1] == 0x4B; // 'PK'
    stdout.writeln('[t2] export bytes=${zip.length} zip-magic=$isZip');

    // 2. Goal: create then read back from history projections; clear after.
    final ref = await gateway.goalCreate(sessionId, 'T2 冒烟目标',
        maxGoalRounds: 3);
    stdout.writeln('[t2] goal.create ref=${ref.id} rev=${ref.revision}');
    final page = await gateway.history(sessionId, maxMessages: 5);
    final goalValues = page.projectionValues;
    final goalRaw = goalValues?['goal'];
    if (goalRaw is Map<String, dynamic>) {
      final goal = GoalSnapshot.fromProjection(goalRaw);
      stdout.writeln('[t2] goal projection → objective=${goal.objective} '
          'phase=${goal.phase} rounds=${goal.roundsStarted} '
          'match=${goal.objective == 'T2 冒烟目标'}');
    } else {
      stdout.writeln('[t2] goal projection absent (may only arrive on mux)');
    }
    await gateway.goalClear(sessionId,
        GoalRef(id: ref.id, revision: ref.revision));
    stdout.writeln('[t2] goal.clear ok');

    // 3. Fork needs a session with a completed turn — use the most recent
    // non-blank session. Fork only creates a child (archived afterwards);
    // the source session is untouched.
    final sessions = await gateway.listSessions();
    final source = sessions
        .where((s) => !s.blank && s.origin != 'subagent')
        .firstOrNull;
    if (source == null) throw StateError('no session with a completed turn');
    final childId = await gateway.forkSession(source.sessionId);
    created.add(childId);
    stdout.writeln('[t2] fork(${source.sessionId.substring(0, 8)}…) '
        '→ ${childId.substring(0, 8)}…');
    final after = await gateway.listSessions();
    final child = after.where((s) => s.sessionId == childId).firstOrNull;
    final visible = child != null &&
        child.origin != 'subagent' &&
        child.parentSessionId == source.sessionId;
    stdout.writeln('[t2] child visible (origin != subagent, has parent) '
        '=> $visible');

    // 4. Subagent catalog of the child (leaf).
    final subagents = await gateway.subagents(childId);
    stdout.writeln('[t2] subagent.list entries=${subagents.entries.length} '
        'parentAvailable=${subagents.parentAvailable}');
  } catch (e) {
    stderr.writeln('[t2] FAILED: $e');
    exit(1);
  } finally {
    for (final id in created) {
      try {
        await gateway.archiveSession(id);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
    await transport.close();
  }
  stdout.writeln('[t2] done');
  exit(0);
}
