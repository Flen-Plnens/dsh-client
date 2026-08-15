/// Connection lifecycle: readiness handshake + dual-stream supervision +
/// exponential-backoff reconnect.
///
/// Semantics mirror the official `ConnectionController` in
/// `@deepseek-ai/dsh-client-connection`:
///
/// - A generation opens BOTH WebSocket downlinks (mux + host).
/// - Readiness requires the `host.describe` unary to succeed AND both sockets
///   to open within [ConnectionConfig.streamOpenTimeout].
/// - ANY stream ending (socket close, error, or a `stream/error` frame) fails
///   the whole generation: both sockets are torn down and rebuilt.
/// - Reconnect uses exponential backoff: base × factor^(attempt-1), capped,
///   with ±50% jitter; `attempt` resets to 0 on a successful connect.
///
/// This file is Flutter-free on purpose: the controller (and the whole core
/// layer) runs under plain `dart run`, so a headless smoke tool can drive a
/// real connection without a widget tree.
library;

import 'dart:async';
import 'dart:math' as math;

import '../rpc/rpc_envelope.dart';
import '../transport/rpc_transport.dart';

/// Connection phase as seen by the UI.
enum ConnectionPhase { disconnected, connecting, connected, reconnecting }

/// Immutable view of the connection state.
class ConnectionSnapshot {
  const ConnectionSnapshot({
    required this.phase,
    this.host,
    this.attempt = 0,
    this.lastError,
  });

  final ConnectionPhase phase;
  final HostDescription? host;
  final int attempt;
  final String? lastError;

  bool get isConnected => phase == ConnectionPhase.connected;

  @override
  String toString() =>
      'ConnectionSnapshot($phase, attempt=$attempt, host=${host?.version})';
}

/// Backoff and handshake timing (official defaults).
class ConnectionConfig {
  const ConnectionConfig({
    this.backoffBaseMs = 500,
    this.backoffFactor = 2,
    this.backoffMaxMs = 10000,
    this.streamOpenTimeout = const Duration(seconds: 3),
  });

  final int backoffBaseMs;
  final int backoffFactor;
  final int backoffMaxMs;
  final Duration streamOpenTimeout;
}

/// Listener signature (ChangeNotifier-compatible shape, no Flutter import).
typedef ConnectionListener = void Function();

/// Owns the connect/reconnect loop for one service address.
class ConnectionController {
  ConnectionController(
    this.transport, {
    ConnectionConfig config = const ConnectionConfig(),
  }) : _config = config;

  final RpcTransport transport;
  final ConnectionConfig _config;
  final math.Random _random = math.Random();

  final List<ConnectionListener> _listeners = [];

  // Frame sinks: broadcast so the UI (and later milestones) can observe the
  // raw downlink frames without owning the sockets.
  final StreamController<ServerRequest> _muxController =
      StreamController<ServerRequest>.broadcast();
  final StreamController<ServerRequest> _hostController =
      StreamController<ServerRequest>.broadcast();

  Stream<ServerRequest> get muxFrames => _muxController.stream;
  Stream<ServerRequest> get hostFrames => _hostController.stream;

  ConnectionPhase _phase = ConnectionPhase.disconnected;
  HostDescription? _host;
  int _attempt = 0;
  String? _lastError;

  int _generation = 0;
  int _epoch = 0;
  bool _running = false;

  StreamSubscription<ServerRequest>? _muxSub;
  StreamSubscription<ServerRequest>? _hostSub;
  Completer<void>? _generationDone;
  Completer<void>? _wake;

  ConnectionPhase get phase => _phase;
  HostDescription? get host => _host;
  int get attempt => _attempt;
  String? get lastError => _lastError;
  bool get isRunning => _running;
  bool get isConnected => _phase == ConnectionPhase.connected;

  ConnectionSnapshot get snapshot => ConnectionSnapshot(
        phase: _phase,
        host: _host,
        attempt: _attempt,
        lastError: _lastError,
      );

  void addListener(ConnectionListener listener) => _listeners.add(listener);

  void removeListener(ConnectionListener listener) =>
      _listeners.remove(listener);

  /// Begin the connect/pump/reconnect loop (idempotent).
  void start() {
    if (_running) return;
    _running = true;
    _epoch += 1;
    unawaited(_runLoop(_epoch));
  }

  /// Stop the loop and close the current generation's sockets.
  void stop() {
    _running = false;
    _epoch += 1;
    _wake?.complete();
    _wake = null;
    unawaited(_cancelGeneration(_generation));
    _host = null;
    _lastError = null;
    _attempt = 0;
    _setPhase(ConnectionPhase.disconnected);
  }

  /// Immediately restart the connect loop (resets the backoff attempt count).
  void reconnect() {
    if (_running) {
      stop();
    }
    start();
  }

  Future<void> dispose() async {
    stop();
    await _muxController.close();
    await _hostController.close();
  }

  Future<void> _runLoop(int epoch) async {
    _wake = null; // fresh interrupt signal for this loop
    try {
      while (_running && epoch == _epoch) {
        final gen = ++_generation;
        _setPhase(ConnectionPhase.connecting);

        final generationDone = Completer<void>();
        _generationDone = generationDone;

        var muxOpened = false;
        var hostOpened = false;
        final bothOpen = Completer<void>();
        void maybeBothOpen() {
          if (muxOpened && hostOpened && !bothOpen.isCompleted) {
            bothOpen.complete();
          }
        }

        void settleOne() {
          if (!generationDone.isCompleted) generationDone.complete();
        }

        _muxSub = _attachDownlink(
          gen,
          transport.openMux(
              onOpen: () {
                muxOpened = true;
                maybeBothOpen();
              }),
          settleOne,
          _muxController,
        );
        _hostSub = _attachDownlink(
          gen,
          transport.openHost(
              onOpen: () {
                hostOpened = true;
                maybeBothOpen();
              }),
          settleOne,
          _hostController,
        );

        // ── Readiness handshake ──────────────────────────────────────────
        var connectedThisGen = false;
        try {
          final response =
              await transport.call('host.describe', const <String, dynamic>{});
          if (epoch != _epoch || !_running) return;

          if (!response.result.ok) {
            _lastError =
                response.result.error?.toString() ?? 'host.describe failed';
          } else {
            // describe is fine: both sockets must also open in time. The
            // generation may end early (a stream errored) — race that too so
            // the real error text is not masked by the open timeout.
            await Future.any([
              bothOpen.future.timeout(_config.streamOpenTimeout),
              generationDone.future,
              _wakeSignal(),
            ]);
            if (epoch != _epoch || !_running) return;
            if (bothOpen.isCompleted) {
              final value = response.result.value;
              _host = HostDescription.fromJson(
                  value is Map<String, dynamic>
                      ? value
                      : const <String, dynamic>{});
              _attempt = 0;
              _lastError = null;
              _setPhase(ConnectionPhase.connected);
              connectedThisGen = true;
            } else if (!generationDone.isCompleted) {
              // Neither socket opened in time and the generation is still
              // alive (no stream error to report).
              _lastError =
                  'stream open timeout (${_config.streamOpenTimeout})';
            }
            // else: a stream already ended; its error text stays in _lastError.
          }
        } catch (e) {
          if (epoch == _epoch && _running) _lastError = e.toString();
        }

        // Generation is over when any stream settles (or the handshake
        // failed). On handshake failure we close the sockets ourselves.
        if (!connectedThisGen) {
          await _cancelGeneration(gen);
        }
        if (epoch != _epoch || !_running) return;
        await Future.any([generationDone.future, _wakeSignal()]);
        if (epoch != _epoch || !_running) return;

        await _cancelGeneration(gen);
        _attempt += 1;
        _lastError ??= 'connection lost';
        _setPhase(ConnectionPhase.reconnecting);
        await Future.any([
          Future<void>.delayed(delayForAttempt(_attempt)),
          _wakeSignal(),
        ]);
      }
    } finally {
      if (epoch == _epoch) _running = false;
    }
  }

  StreamSubscription<ServerRequest> _attachDownlink(
    int gen,
    Stream<ServerRequest> stream,
    void Function() settleOne,
    StreamController<ServerRequest> sink,
  ) {
    return stream.listen(
      (frame) {
        if (gen != _generation || !_running) return;
        // The host signals stream-end via a stream/error frame; treat it as
        // the stream ending (official: break the pump loop).
        if (frame.frameType == 'stream/error') {
          settleOne();
          return;
        }
        sink.add(frame);
      },
      onError: (Object e) {
        if (gen == _generation && _running) _lastError = e.toString();
        settleOne();
      },
      onDone: settleOne,
      cancelOnError: true,
    );
  }

  /// Close the current generation's sockets, if any, and mark it settled
  /// (cancelled subscriptions never fire onDone). Safe to call more than once
  /// per generation.
  Future<void> _cancelGeneration(int gen) async {
    if (gen != _generation) return;
    final mux = _muxSub;
    final host = _hostSub;
    _muxSub = null;
    _hostSub = null;
    await Future.wait([
      if (mux != null) mux.cancel(),
      if (host != null) host.cancel(),
    ]);
    final done = _generationDone;
    _generationDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Fresh interrupt signal; a completed [Completer] makes every subsequent
  /// wait return immediately (used by stop()).
  Future<void> _wakeSignal() {
    final wake = _wake ??= Completer<void>();
    return wake.future;
  }

  /// Reconnect delay for a given attempt count (official formula: base ×
  /// factor^(attempt-1), capped, with ±50% jitter). Public as a test seam.
  Duration delayForAttempt(int attempt) {
    final exponent = math.max(0, attempt - 1);
    final cap = math.min(
      _config.backoffMaxMs,
      _config.backoffBaseMs *
          math.pow(_config.backoffFactor, exponent).toInt(),
    );
    // Official jitter: cap/2 + random × cap/2.
    final ms = cap / 2 + _random.nextDouble() * (cap / 2);
    return Duration(milliseconds: ms.round());
  }

  void _setPhase(ConnectionPhase phase) {
    _phase = phase;
    _notifyListeners();
  }

  void _notifyListeners() {
    for (final listener in List<ConnectionListener>.of(_listeners)) {
      listener();
    }
  }
}
