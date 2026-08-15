/// Headless M3-2 smoke against a live DSH service: a real steer-mode prompt
/// (interrupt semantics on an idle agent = runs immediately) and, when the
/// agent is busy, a live queue edit/remove round-trip via updateQueue.
///
/// Usage (pure Dart):
///   dart run tool/m32_smoke.dart [http://host:port]
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

  final store = SurfaceStore();
  String? sessionId;
  var turnEnded = false;
  final queueSnapshots = <List<Map<String, dynamic>>>[];

  controller.muxFrames.listen((ServerRequest frame) {
    final payload = frame.payloadMap;
    if (payload == null || payload['sessionId'] != sessionId) return;
    switch (frame.frameType) {
      case 'session/event':
        final eventJson = payload['event'];
        if (eventJson is! Map<String, dynamic>) return;
        final event = SessionEvent.fromJson(eventJson);
        store.apply(event);
        if (event.type == 'turn/end') turnEnded = true;
      case 'session/queue':
        final items = payload['items'];
        if (items is List) {
          queueSnapshots.add(items.cast<Map<String, dynamic>>());
        }
    }
  });

  controller.start();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (controller.phase != ConnectionPhase.connected) {
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln('[m32] connect failed');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  try {
    sessionId = await gateway.createSession();
    stdout.writeln('[m32] session ${sessionId.substring(0, 8)}…');

    // 1. Real steer-mode prompt on an idle agent → runs immediately.
    await gateway.prompt(sessionId, [
      {'type': 'text', 'text': 'Reply with exactly: steer-ok'}
    ], mode: 'steer');
    stdout.writeln('[m32] steer prompt accepted');
    final turnDeadline = DateTime.now().add(const Duration(seconds: 120));
    while (!turnEnded && DateTime.now().isBefore(turnDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final reply = store.messages
        .where((m) => m.kind == MessageKind.assistant)
        .map((m) => m.text)
        .join(' ');
    stdout.writeln('[m32] steer turn ended=$turnEnded reply="$reply"');

    // 2. Queue round-trip (only when the agent is busy and items are queued).
    await gateway.prompt(sessionId, [
      {'type': 'text', 'text': 'second message (queue)'}
    ], mode: 'queue');
    // Watch for a queued item briefly.
    final queueDeadline = DateTime.now().add(const Duration(seconds: 20));
    Map<String, dynamic>? queuedItem;
    while (queuedItem == null && DateTime.now().isBefore(queueDeadline)) {
      for (final snapshot in queueSnapshots.reversed) {
        for (final item in snapshot) {
          if (item['placement'] == 'queued') {
            queuedItem = item;
            break;
          }
        }
        if (queuedItem != null) break;
      }
      if (queuedItem == null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (queuedItem == null) {
      stdout.writeln('[m32] agent idle — no queued item observed; '
          'queue edit/remove skipped');
    } else {
      final id = queuedItem['id'] as String;
      final edited = 'edited-${DateTime.now().millisecondsSinceEpoch}';
      await gateway.updateQueue(sessionId, id, {
        'kind': 'edit',
        'content': [
          {'type': 'text', 'text': edited}
        ],
      });
      stdout.writeln('[m32] queue edit accepted for $id');
      await gateway.updateQueue(sessionId, id, {'kind': 'remove'});
      stdout.writeln('[m32] queue remove accepted for $id');
    }
  } catch (e) {
    stderr.writeln('[m32] FAILED: $e');
    exit(1);
  } finally {
    controller.stop();
    await transport.close();
  }
  stdout.writeln('[m32] done');
  exit(0);
}
