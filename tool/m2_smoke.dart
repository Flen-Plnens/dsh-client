/// Headless M2 smoke test: against a live DSH service, create a fresh
/// session, submit a real prompt, and observe the full loop — prompt
/// acceptance, queue frames (when the agent is busy), streaming chunks, and
/// the final folded transcript.
///
/// Usage (pure Dart):
///   dart run tool/m2_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/connection/connection_controller.dart';
import 'package:dsh_flutter/core/session/session_event.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  stdout.writeln('[m2] connecting to $address');

  final transport = HttpWsTransport.fromAddress(address);
  final controller = ConnectionController(transport);
  final gateway = SessionRepository(transport);

  final store = SurfaceStore();
  final queueEvents = <Map<String, dynamic>>[];
  String? sessionId;
  var turnEnded = false;

  controller.muxFrames.listen((frame) {
    final payload = frame.payloadMap;
    if (payload == null) return;
    final frameSessionId = payload['sessionId'];
    if (frameSessionId != sessionId) return;
    switch (frame.frameType) {
      case 'session/event':
        final eventJson = payload['event'];
        if (eventJson is! Map<String, dynamic>) return;
        final event = SessionEvent.fromJson(eventJson);
        store.apply(event);
        if (event.type == 'turn/end') turnEnded = true;
      case 'session/queue':
        queueEvents.add(payload);
    }
  });

  controller.start();
  // Wait for connected.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (controller.phase != ConnectionPhase.connected) {
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln('[m2] connect failed: ${controller.lastError}');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  stdout.writeln('[m2] connected');

  try {
    sessionId = await gateway.createSession();
    stdout.writeln('[m2] created session $sessionId');

    await gateway.prompt(sessionId, [
      {'type': 'text', 'text': 'Reply with exactly one word: pong'}
    ], mode: 'queue');
    stdout.writeln('[m2] prompt accepted (queue mode)');

    final turnDeadline = DateTime.now().add(const Duration(seconds: 120));
    while (!turnEnded && DateTime.now().isBefore(turnDeadline)) {
      if (queueEvents.isNotEmpty) {
        final items =
            (queueEvents.last['items'] as List?)?.length ?? 0;
        if (items > 0) {
          stdout.writeln('[m2] queue: $items pending item(s)');
          queueEvents.clear();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    stdout.writeln('[m2] turn ended: $turnEnded');
    final messages = store.messages;
    stdout.writeln(
        '[m2] folded: ${messages.length} messages, '
        'streaming=${store.streaming?.isEmpty == false}, tolerated=${store.toleratedSkips}');
    for (final m in messages) {
      final text = m.text.replaceAll('\n', ' ');
      final snippet = text.length > 80 ? '${text.substring(0, 80)}…' : text;
      stdout.writeln(
          '[m2]   ${m.kind}${m.sourceKind != null ? '(${m.sourceKind})' : ''}: $snippet');
    }
  } catch (e) {
    stderr.writeln('[m2] FAILED: $e');
    exit(1);
  } finally {
    controller.stop();
    await transport.close();
  }
  stdout.writeln('[m2] done');
  exit(0);
}
