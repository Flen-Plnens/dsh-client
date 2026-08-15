/// Transport-agnostic RPC surface (mirrors the official ApiProxy contract).
///
/// Physical carriers (HTTP POST, WebSocket downlinks) are decoupled from the
/// logical four-quadrant messages: any implementation of this interface can
/// drive the ConnectionController and, later, the full session domain.
library;

import 'dart:typed_data';

import '../rpc/rpc_envelope.dart';

/// A carrier-level failure: HTTP non-2xx, refused connection, timeout,
/// malformed body. Distinct from business errors, which ride
/// [RpcResult.fail] inside a well-formed [ServerResponse].
class TransportException implements Exception {
  const TransportException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() {
    final code = statusCode == null ? '' : ', HTTP $statusCode';
    return 'TransportException($message$code)';
  }
}

/// The two downlink channels the wire uses for server pushes.
enum Downlink { mux, host }

/// The physical-carrier contract the connection layer consumes.
abstract class RpcTransport {
  /// Unary call: POST `/api/<method>` with a ClientRequest envelope.
  ///
  /// Throws [TransportException] on carrier failure; business errors come back
  /// as `result.ok == false`.
  Future<ServerResponse> call(
    String method,
    Map<String, dynamic> payload, {
    Duration? timeout,
  });

  /// Client response to a server request: POST /api/respond.
  Future<RpcReceipt> respond(ClientResponse message, {Duration? timeout});

  /// Raw binary GET for a server resource, e.g. `session.export?sessionId=…`.
  /// [pathAndQuery] is the `/api/`-relative path (query included). Throws
  /// [TransportException] on carrier failure (non-2xx, refused, timeout).
  Future<Uint8List> getBytes(String pathAndQuery, {Duration? timeout});

  /// Open the mux downlink (session events).
  ///
  /// [onOpen] fires once the physical socket is established — the
  /// stream-established signal the readiness handshake waits on, before any
  /// frame arrives. The stream must be single-subscription: cancelling the
  /// subscription closes the socket.
  Stream<ServerRequest> openMux({void Function()? onOpen});

  /// Open the host downlink (host events). Same contract as [openMux].
  Stream<ServerRequest> openHost({void Function()? onOpen});
}
