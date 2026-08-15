/// Headless M0 smoke test: drives a REAL connection against a live DSH
/// service and prints the handshake + first downlink frames.
///
/// Usage (pure Dart, no Flutter needed):
///   dart run tool/m0_smoke.dart [http://host:port]
library;

import 'dart:io';

import 'package:dsh_flutter/core/connection/connection_controller.dart';
import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:dsh_flutter/core/transport/http_ws_transport.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  stdout.writeln('[smoke] connecting to $address');

  final HttpWsTransport transport;
  try {
    transport = HttpWsTransport.fromAddress(address);
  } on FormatException catch (e) {
    stderr.writeln('[smoke] bad address: ${e.message}');
    exit(2);
  }

  final controller = ConnectionController(transport);

  final muxFrames = <String>[];
  final hostFrames = <String>[];
  controller.muxFrames.take(5).listen(
      (ServerRequest f) => muxFrames.add(f.frameType ?? '(non-object)'));
  controller.hostFrames.take(5).listen(
      (ServerRequest f) => hostFrames.add(f.frameType ?? '(non-object)'));

  controller.addListener(() {
    final s = controller.snapshot;
    final host = s.host;
    final parts = <String>['phase=${s.phase}', 'attempt=${s.attempt}'];
    if (host != null) {
      parts
        ..add('version=${host.version}')
        ..add('cwd=${host.cwd}')
        ..add('model=${host.provider}/${host.model}')
        ..add('attached=${host.attachedSessions}');
    }
    if (s.lastError != null) parts.add('error=${s.lastError}');
    stdout.writeln('[smoke] ${parts.join(' ')}');
  });

  controller.start();

  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (controller.phase != ConnectionPhase.connected) {
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln(
          '[smoke] FAILED to connect within 10s: ${controller.lastError}');
      controller.stop();
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  stdout.writeln('[smoke] CONNECTED — collecting downlink frames for 3s …');
  await Future<void>.delayed(const Duration(seconds: 3));

  stdout.writeln('[smoke] mux frames: '
      '${muxFrames.isEmpty ? '(none)' : muxFrames.join(', ')}');
  stdout.writeln('[smoke] host frames: '
      '${hostFrames.isEmpty ? '(none)' : hostFrames.join(', ')}');

  controller.stop();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await transport.close(); // release idle keep-alive connections
  stdout.writeln('[smoke] done (exit 0)');
  // exit() forces termination: in some environments dart:io leaves a lingering
  // socket/isolate handle after the last WebSocket closes, which would
  // otherwise keep the tool process alive after main() returns.
  exit(0);
}
