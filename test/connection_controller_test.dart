import 'package:dsh_flutter/core/connection/connection_controller.dart';
import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// Fast timing so reconnect tests run in milliseconds.
ConnectionConfig get _fastConfig => const ConnectionConfig(
      backoffBaseMs: 1,
      backoffMaxMs: 5,
      streamOpenTimeout: Duration(seconds: 1),
    );

/// Slightly slower backoff so the `reconnecting` window is observable by the
/// 2 ms polling loop (avoids test races with ultra-fast reconnects).
ConnectionConfig get _reconnectConfig => const ConnectionConfig(
      backoffBaseMs: 20,
      backoffMaxMs: 20,
      streamOpenTimeout: Duration(seconds: 1),
    );

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

ServerRequest _streamErrorFrame() => const ServerRequest(
      rpcId: 'srv',
      method: 'mux',
      payload: <String, dynamic>{
        'type': 'stream/error',
        'error': {
          'code': 'internal',
          'message': 'stream closed',
          'details': <String, dynamic>{},
        },
      },
    );

void main() {
  test('connect: describe + both streams → connected', () async {
    final transport = FakeTransport();
    final controller = ConnectionController(transport, config: _fastConfig);
    controller.start();
    await _waitFor(() => controller.phase == ConnectionPhase.connected);

    expect(transport.describeCalls, 1);
    expect(controller.attempt, 0);
    expect(controller.isConnected, isTrue);
    expect(controller.host?.version, '0.0.1');
    expect(controller.host?.cwd, r'C:\test');
    expect(controller.host?.attachedSessions, 3);

    await controller.dispose();
  });

  test('mux stream end → reconnecting → connected again', () async {
    final transport = FakeTransport();
    final controller = ConnectionController(transport, config: _reconnectConfig);
    controller.start();
    await _waitFor(() => controller.phase == ConnectionPhase.connected);

    await transport.mux.close();
    await _waitFor(() => controller.phase == ConnectionPhase.reconnecting);
    await _waitFor(() => controller.phase == ConnectionPhase.connected);

    expect(transport.describeCalls, 2);
    expect(controller.attempt, 0); // reset on success

    await controller.dispose();
  });

  test('host stream error → reconnecting', () async {
    final transport = FakeTransport();
    final controller = ConnectionController(transport, config: _reconnectConfig);
    controller.start();
    await _waitFor(() => controller.phase == ConnectionPhase.connected);

    transport.host
        .addError(StateError('socket died'));
    await _waitFor(
        () => controller.phase == ConnectionPhase.reconnecting &&
            (controller.lastError ?? '').contains('socket died'));

    await controller.dispose();
  });

  test('stream/error frame ends the generation → reconnect', () async {
    final transport = FakeTransport();
    final controller = ConnectionController(transport, config: _reconnectConfig);
    controller.start();
    await _waitFor(() => controller.phase == ConnectionPhase.connected);

    transport.mux.add(_streamErrorFrame());
    await _waitFor(() => controller.phase == ConnectionPhase.reconnecting);
    await _waitFor(() => controller.phase == ConnectionPhase.connected);
    expect(transport.describeCalls, 2);

    await controller.dispose();
  });

  test('describe failure → reconnecting → recovers when host heals', () async {
    final transport = FakeTransport()..failDescribe = true;
    final controller = ConnectionController(transport, config: _reconnectConfig);
    controller.start();
    await _waitFor(() => controller.phase == ConnectionPhase.reconnecting);
    expect(controller.lastError, contains('boom'));

    transport.failDescribe = false;
    await _waitFor(() => controller.phase == ConnectionPhase.connected);
    // At least two describe calls: the failed one plus the successful one
    // (a fast backoff may have run more than one failed generation).
    expect(transport.describeCalls, greaterThanOrEqualTo(2));

    await controller.dispose();
  });

  test('backoff grows across attempts (config-level behavior)', () {
    const config = ConnectionConfig(
      backoffBaseMs: 500,
      backoffFactor: 2,
      backoffMaxMs: 10000,
      streamOpenTimeout: Duration(seconds: 3),
    );
    // attempt 1 → cap 500 → 250..500ms
    // attempt 2 → cap 1000 → 500..1000ms
    // attempt 4 → cap 4000 → 2000..4000ms
    // attempt 5 → cap 8000 → 4000..8000ms
    // attempt 6 → cap 10000 → 5000..10000ms (capped)
    // Recompute via the private method through a controller.
    final controller =
        ConnectionController(FakeTransport(), config: config);
    final delays = <Duration>[];
    for (var attempt = 1; attempt <= 6; attempt++) {
      delays.add(controller.delayForAttempt(attempt));
    }
    expect(delays[0] >= const Duration(milliseconds: 250), isTrue);
    expect(delays[0] <= const Duration(milliseconds: 500), isTrue);
    expect(delays[1] >= const Duration(milliseconds: 500), isTrue);
    expect(delays[1] <= const Duration(milliseconds: 1000), isTrue);
    expect(delays[3] >= const Duration(milliseconds: 2000), isTrue);
    expect(delays[3] <= const Duration(milliseconds: 4000), isTrue);
    expect(delays[4] >= const Duration(milliseconds: 4000), isTrue);
    expect(delays[4] <= const Duration(milliseconds: 8000), isTrue);
    expect(delays[5] >= const Duration(milliseconds: 5000), isTrue);
    expect(delays[5] <= const Duration(milliseconds: 10000), isTrue);
  });

  test('stop() → disconnected and loop exits', () async {
    final transport = FakeTransport();
    final controller = ConnectionController(transport, config: _fastConfig);
    controller.start();
    await _waitFor(() => controller.phase == ConnectionPhase.connected);

    controller.stop();
    expect(controller.phase, ConnectionPhase.disconnected);
    await _waitFor(() => !controller.isRunning);
    expect(controller.host, isNull);

    await controller.dispose();
  });

  test('downlink frames are forwarded to the broadcast sinks', () async {
    final transport = FakeTransport();
    final controller = ConnectionController(transport, config: _fastConfig);
    final seen = <String>[];
    controller.muxFrames.listen((f) => seen.add(f.frameType ?? '?'));
    controller.start();
    await _waitFor(() => controller.phase == ConnectionPhase.connected);

    transport.mux.add(const ServerRequest(
      rpcId: 'x',
      method: 'mux',
      payload: <String, dynamic>{
        'type': 'session/event',
        'sessionId': 's1',
      },
    ));
    await _waitFor(() => seen.contains('session/event'));
    expect(seen, ['session/event']);

    await controller.dispose();
  });
}
