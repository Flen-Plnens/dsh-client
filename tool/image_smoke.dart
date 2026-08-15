/// Headless image-input smoke against a live DSH service:
/// - build a real 1x1 PNG in memory
/// - send it as a session.prompt image part (mediaType + base64 data)
/// - the deployment's default model has no native image input, so the host
///   should reject with attachment-error — reaching that rejection proves the
///   payload shape is accepted end-to-end by rc.6 (image part semantics OK;
///   refusal is model routing, not client shape).
///
/// Usage:
///   dart run tool/image_smoke.dart [http://host:port]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

/// 1x1 transparent PNG bytes.
final Uint8List _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // RGBA
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, // IDAT
  0x78, 0x9C, 0x62, 0x64, 0x60, 0xF8, 0x5F, 0x0F, // ...
  0x00, 0x01, 0x06, 0x00, 0x03, 0xE8, 0x5D, 0x60, 0x00, // ...
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
  0xAE, 0x42, 0x60, 0x82,
]);

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final transport = HttpWsTransport.fromAddress(address);
  final gateway = SessionRepository(transport);

  try {
    // Reuse the most recent non-blank session.
    final sessions = await gateway.listSessions();
    final target = sessions
        .where((s) => !s.blank && s.origin != 'subagent')
        .firstOrNull;
    if (target == null) throw StateError('no non-blank session to send to');

    try {
      await gateway.prompt(target.sessionId, [
        {
          'type': 'image',
          'mediaType': 'image/png',
          'data': base64Encode(_png),
        },
      ]);
      stdout.writeln('[img] image part accepted (unexpected on this deployment)');
    } on SessionApiException catch (e) {
      // Expected: default model has no native image input. The important
      // signal is the error CODE — attachment-error means the payload shape
      // passed schema validation and the refusal came from model routing.
      stdout.writeln('[img] host refused: code=${e.code}');
      stdout.writeln('[img]   message=${e.message}');
      stdout.writeln('[img]   shape-ok=${e.code == 'attachment-error' || e.message.contains('does not support image')}');
    }
  } catch (e) {
    stderr.writeln('[img] FAILED: $e');
    exit(1);
  } finally {
    await transport.close();
  }
  stdout.writeln('[img] done');
  exit(0);
}
