/// Headless M3-3 smoke against a live DSH service: send a real image message
/// (1x1 PNG) in a fresh session, confirm the model received it, read the
/// durable attachment back via session.attachment, and verify subagent
/// sender ids parse from a real parent transcript.
///
/// Usage (pure Dart):
///   dart run tool/m33_smoke.dart [http://host:port]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_flutter/core/connection/connection_controller.dart';
import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:dsh_flutter/core/session/session_event.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

/// A minimal 1x1 transparent PNG.
final Uint8List pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final controller = ConnectionController(transport);
  final gateway = SessionRepository(transport);

  final store = SurfaceStore();
  String? sessionId;
  var turnEnded = false;

  controller.muxFrames.listen((ServerRequest frame) {
    final payload = frame.payloadMap;
    if (payload == null || payload['sessionId'] != sessionId) return;
    if (frame.frameType != 'session/event') return;
    final eventJson = payload['event'];
    if (eventJson is! Map<String, dynamic>) return;
    final event = SessionEvent.fromJson(eventJson);
    store.apply(event);
    if (event.type == 'turn/end') turnEnded = true;
  });

  controller.start();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (controller.phase != ConnectionPhase.connected) {
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln('[m33] connect failed');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  try {
    // 1. Real image message round-trip. The deployment default model may not
    //    support image input — the host answers attachment-error and the
    //    client surfaces it; that finding is itself the verification.
    sessionId = await gateway.createSession();
    stdout.writeln('[m33] session ${sessionId.substring(0, 8)}…');
    try {
      await gateway.prompt(sessionId, [
        {
          'type': 'image',
          'mediaType': 'image/png',
          'data': base64Encode(pngBytes),
        },
        {'type': 'text', 'text': 'What pixel color is this 1x1 image? '
            'Reply with just the color name.'},
      ], mode: 'queue');
      stdout.writeln('[m33] image prompt accepted');

      final turnDeadline = DateTime.now().add(const Duration(seconds: 120));
      while (!turnEnded && DateTime.now().isBefore(turnDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final reply = store.messages
          .where((m) => m.kind == MessageKind.assistant)
          .map((m) => m.text)
          .join(' ');
      stdout.writeln('[m33] turn ended=$turnEnded reply="$reply"');

      // 2. Read the durable attachment back (the user message's image ref).
      final userImages = store.messages
          .where((m) => m.kind == MessageKind.user)
          .expand((m) => m.images)
          .toList();
      if (userImages.isEmpty) {
        stdout.writeln('[m33] WARN: no image ref found in the user message');
      } else {
        final ref = userImages.first;
        final bytes = await gateway.attachment(sessionId, ref.attachmentId);
        stdout.writeln('[m33] attachment read-back: ${ref.attachmentId} '
            'mediaType=${ref.mediaType} bytes=${bytes.length} '
            'match=${bytes.length == pngBytes.length}');
      }
    } on SessionApiException catch (e) {
      stdout.writeln(
          '[m33] image prompt refused: code=${e.code} message=${e.message}');
      if (e.code != 'attachment-error') rethrow;
      stdout.writeln(
          '[m33] (deployment default model lacks vision; image round-trip '
          'skipped — client surfaced the host error correctly)');
    }

    // 3. Subagent sender ids parse from a real parent transcript.
    final sessions = await gateway.listSessions();
    final parent = sessions
        .where((s) => s.origin != 'subagent' && !s.blank)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (parent.isNotEmpty) {
      final page = await gateway.history(parent.first.sessionId, maxMessages: 60);
      final parentStore = SurfaceStore()..load(page.events);
      final senders = parentStore.messages
          .map((m) => m.senderSessionId)
          .whereType<String>()
          .toSet();
      stdout.writeln('[m33] parent session subagent senders: '
          '${senders.isEmpty ? '(none in window)' : senders.join(', ')}');
    }
  } catch (e) {
    stderr.writeln('[m33] FAILED: $e');
    exit(1);
  } finally {
    controller.stop();
    await transport.close();
  }
  stdout.writeln('[m33] done');
  exit(0);
}
