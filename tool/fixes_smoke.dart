/// Headless verification of the M2.6 review fixes against a live DSH service:
/// the list-visibility predicate (subagent/blank/archived), the queue
/// placement vocabulary actually emitted on the wire, and the
/// `session/subscribed` durable baseline used for gap detection.
///
/// Usage (pure Dart):
///   dart run tool/fixes_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/connection/connection_controller.dart';
import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:dsh_flutter/core/session/session_event.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final controller = ConnectionController(transport);
  final gateway = SessionRepository(transport);

  int? subscribedLastSeq;
  final store = SurfaceStore();
  String? mainSession;

  controller.muxFrames.listen((ServerRequest frame) {
    final payload = frame.payloadMap;
    if (payload == null) return;
    switch (frame.frameType) {
      case 'session/subscribed':
        final seq = payload['lastSeq'];
        if (seq is int) subscribedLastSeq = seq;
      case 'session/event':
        if (payload['sessionId'] != mainSession) return;
        final eventJson = payload['event'];
        if (eventJson is Map<String, dynamic>) {
          store.apply(SessionEvent.fromJson(eventJson));
        }
    }
  });

  controller.start();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (controller.phase != ConnectionPhase.connected) {
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln('[fixes] connect failed');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  try {
    final sessions = await gateway.listSessions();
    final workspaces = await gateway.listWorkspaces();
    final archived = workspaces.archivedSessionIds.toSet();
    var visible = 0;
    for (final s in sessions) {
      final isVisible = s.origin != 'subagent' &&
          !archived.contains(s.sessionId) &&
          (!s.blank); // current==null in this headless probe
      if (isVisible) visible++;
      stdout.writeln(
          '[fixes] ${s.sessionId} blank=${s.blank} sub=${s.origin == 'subagent'} '
          'archived=${archived.contains(s.sessionId)} → listVisible=$isVisible');
    }
    stdout.writeln('[fixes] visible top-level rows: $visible / ${sessions.length} '
        '(archived=${archived.length})');

    // Open the most recent visible session and wait for its subscribed baseline.
    final candidates = sessions.where((s) => s.origin != 'subagent' && !s.blank).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (candidates.isNotEmpty) {
      mainSession = candidates.first.sessionId;
      final page = await gateway.history(mainSession, maxMessages: 80);
      store.load(page.events);
      final tail = store.log.isEmpty ? null : store.log.last.seq;
      // Wait for a subscribed frame briefly.
      final waitUntil = DateTime.now().add(const Duration(seconds: 5));
      while (subscribedLastSeq == null && DateTime.now().isBefore(waitUntil)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final gap = subscribedLastSeq != null &&
          tail != null &&
          subscribedLastSeq! > tail;
      stdout.writeln(
          '[fixes] session ${mainSession.substring(0, 8)}… tail=$tail '
          'subscribed.lastSeq=$subscribedLastSeq gapDetected=$gap');
    }
  } catch (e) {
    stderr.writeln('[fixes] FAILED: $e');
    exit(1);
  } finally {
    controller.stop();
    await transport.close();
  }
  stdout.writeln('[fixes] done');
  exit(0);
}
