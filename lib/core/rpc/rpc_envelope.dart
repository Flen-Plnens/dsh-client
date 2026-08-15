/// Four-quadrant RPC message model (DSH wire protocol).
///
/// Mirrors the official contract in `@deepseek-ai/dsh-host-apiproxy`:
/// logical messages are channel-independent and form a four-member
/// discriminated union:
///
///   1) client-request  — C→S unary (POST `/api/<method>` body)
///   2) server-response — S→C answer to that POST (body)
///   3) server-request  — S→C push (each WebSocket downlink text message)
///   4) client-response — C→S answer to a server request (POST `/api/respond`)
///
/// Responses always echo the matching request's `rpcId` and never mint a new
/// one. Business errors ride the `result` error branch; HTTP status expresses
/// only the carrier (see TransportException).
library;

import 'dart:convert';

/// Opaque correlation id, minted by the initiator (UUIDs in practice).
typedef RpcId = String;

/// Business error body: `{ code, message, details }`, where `details` is
/// required and its shape is closed per code (RpcErrorDetailsMap).
class RpcError {  const RpcError({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, dynamic> details;

  factory RpcError.fromJson(Map<String, dynamic> json) {
    return RpcError(
      code: json['code'] as String? ?? 'unknown',
      message: json['message'] as String? ?? '',
      details: (json['details'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  Map<String, dynamic> toJson() =>
      {'code': code, 'message': message, 'details': details};

  @override
  String toString() => 'RpcError($code): $message';
}

/// Parsed `result` slot of an RPC message: `{ok:true, value?}` or
/// `{ok:false, error}` (a void success serializes without `value`).
class RpcResult<T> {
  const RpcResult.ok(T this.value)
      : ok = true,
        error = null;

  const RpcResult.fail(RpcError this.error)
      : ok = false,
        value = null;

  final bool ok;
  final T? value;
  final RpcError? error;

  RpcResult<U> cast<U>() => ok ? RpcResult<U>.ok(value as U) : RpcResult<U>.fail(error!);
}

/// 1) client-request — the POST `/api/<method>` body.
class ClientRequest {
  const ClientRequest({
    required this.rpcId,
    required this.method,
    required this.payload,
  });

  final RpcId rpcId;
  final String method;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
        'type': 'client-request',
        'rpcId': rpcId,
        'method': method,
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());
}

/// 2) server-response — the body of a unary POST's answer.
class ServerResponse {
  const ServerResponse({required this.rpcId, required this.result});

  final RpcId rpcId;
  final RpcResult<dynamic> result;

  factory ServerResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['result'];
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('server-response missing result object');
    }
    final ok = raw['ok'] == true;
    final result = ok
        ? RpcResult<dynamic>.ok(raw['value'])
        : RpcResult<dynamic>.fail(RpcError.fromJson(
            (raw['error'] as Map?)?.cast<String, dynamic>() ?? const {}));
    return ServerResponse(
      rpcId: json['rpcId'] as String? ?? '',
      result: result,
    );
  }
}

/// 3) server-request — one WebSocket downlink text message (full form).
///
/// `payload` is the frame: a JSON object whose `type` field is the frame
/// discriminant (`session/event`, `host/session-added`, `stream/error`, ...).
class ServerRequest {
  const ServerRequest({
    required this.rpcId,
    required this.method,
    required this.payload,
  });

  final RpcId rpcId;
  final String method;
  final dynamic payload;

  /// The frame object when the payload is a JSON object, else null.
  Map<String, dynamic>? get payloadMap =>
      payload is Map<String, dynamic> ? payload as Map<String, dynamic> : null;

  /// The frame discriminant (`payload.type`), e.g. `session/event`.
  String? get frameType => payloadMap?['type'] as String?;

  factory ServerRequest.fromJson(Map<String, dynamic> json) {
    return ServerRequest(
      rpcId: json['rpcId'] as String? ?? '',
      method: json['method'] as String? ?? '',
      payload: json['payload'],
    );
  }

  @override
  String toString() => 'ServerRequest($frameType)';
}

/// 4) client-response — the POST /api/respond body answering a server request.
class ClientResponse {
  const ClientResponse({required this.rpcId, required this.result});

  final RpcId rpcId;
  final RpcResult<dynamic> result;

  Map<String, dynamic> toJson() => {
        'type': 'client-response',
        'rpcId': rpcId,
        'result': result.ok
            ? {'ok': true, 'value': result.value}
            : {'ok': false, 'error': result.error!.toJson()},
      };

  String encode() => jsonEncode(toJson());
}

/// Receipt of POST /api/respond: `{accepted:true}` or
/// `{accepted:false, reason: 'not-pending' | 'bad-response'}`.
class RpcReceipt {
  const RpcReceipt({required this.accepted, this.reason});

  final bool accepted;
  final String? reason;

  factory RpcReceipt.fromJson(Map<String, dynamic> json) {
    return RpcReceipt(
      accepted: json['accepted'] == true,
      reason: json['reason'] as String?,
    );
  }
}

/// The host.describe response value (readiness handshake payload).
///
/// Wire shape: `{ version, cwd, provider?, model?, attachedSessions,
/// canOpenPath }`.
class HostDescription {
  const HostDescription({
    required this.version,
    required this.cwd,
    this.provider,
    this.model,
    required this.attachedSessions,
    required this.canOpenPath,
  });

  final String version;
  final String cwd;
  final String? provider;
  final String? model;
  final int attachedSessions;
  final bool canOpenPath;

  factory HostDescription.fromJson(Map<String, dynamic> json) {
    return HostDescription(
      version: json['version'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      attachedSessions: (json['attachedSessions'] as num?)?.toInt() ?? 0,
      canOpenPath: json['canOpenPath'] as bool? ?? false,
    );
  }
}
