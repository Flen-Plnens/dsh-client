/// Physical carrier over `dart:io`.
///
/// - Unary and respond: HTTP POST to `/api/<method>` and `/api/respond` with
///   `content-type: application/json` (anything else is refused with 415 by
///   the host before dispatch).
/// - Downlinks: one WebSocket per stream at `/api/events.mux` and
///   `/api/events.host`. Each text message is a full ServerRequest envelope;
///   the client sends nothing over these sockets (downlink-only).
///
/// The `Host` header is derived from [baseUri] by dart:io, which is exactly
/// what the host's browser-trust fence checks (loopback or `trustedHosts`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../rpc/rpc_envelope.dart';
import 'rpc_transport.dart';

/// Physical carrier over dart:io HttpClient + dart:io WebSocket.
class HttpWsTransport implements RpcTransport {
  HttpWsTransport(
    this.baseUri, {
    this.defaultTimeout = const Duration(seconds: 30),
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10)) {
    // The service address is a user-entered local/LAN endpoint; it must be
    // reached DIRECTLY, never through an environment proxy. dart:io otherwise
    // honors HTTP(S)_PROXY by default, which would route (and mangle, e.g.
    // strip WebSocket upgrade headers on) requests meant for the DSH host.
    _httpClient.findProxy = null;
  }

  /// Parse and normalize a user-entered service address.
  ///
  /// Accepts `http://host:port` / `https://host:port` (with or without a
  /// trailing slash); any path/query/fragment is dropped. Throws
  /// [FormatException] on missing scheme or host.
  factory HttpWsTransport.fromAddress(
    String address, {
    Duration? defaultTimeout,
    HttpClient? httpClient,
  }) {
    final trimmed = address.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw FormatException('服务地址必须以 http:// 或 https:// 开头', trimmed);
    }
    if (uri.host.isEmpty) {
      throw FormatException('服务地址缺少主机名', trimmed);
    }
    final normalized = uri.replace(path: '/', query: null, fragment: null);
    return HttpWsTransport(
      normalized,
      defaultTimeout: defaultTimeout ?? const Duration(seconds: 30),
      httpClient: httpClient,
    );
  }

  /// The origin the client talks to, e.g. `http://127.0.0.1:3080`.
  final Uri baseUri;

  /// Default unary timeout. User-paced methods (e.g. host.pickDirectory) must
  /// pass their own longer/null timeout — not exercised in M0.
  final Duration defaultTimeout;

  final HttpClient _httpClient;

  static final _rpcIdCounter = DateTime.now().microsecondsSinceEpoch;

  static RpcId _mintRpcId() =>
      'm0-$_rpcIdCounter-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
  static int _seq = 0;

  Uri _api(String path) =>
      baseUri.replace(path: '/api/$path', query: null, fragment: null);

  Uri _ws(String path) => baseUri.replace(
        scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/$path',
        query: null,
        fragment: null,
      );

  @override
  Future<ServerResponse> call(
    String method,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    final request = ClientRequest(
      rpcId: _mintRpcId(),
      method: method,
      payload: payload,
    );
    final effectiveTimeout = timeout ?? defaultTimeout;

    final httpRequest = await _httpClient.postUrl(_api(method));
    httpRequest.headers.contentType = ContentType.json;
    httpRequest.write(request.encode());

    final response = await httpRequest.close().timeout(
          effectiveTimeout,
          onTimeout: () {
            httpRequest.abort();
            throw TransportException('unary timeout for $method',
                cause: TimeoutException(effectiveTimeout.toString()));
          },
        );
    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransportException('transport failure for $method',
          statusCode: response.statusCode);
    }

    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('response is not a JSON object');
      }
      json = decoded;
    } on FormatException catch (e) {
      throw TransportException('malformed JSON response for $method', cause: e);
    }

    final parsed = ServerResponse.fromJson(json);
    if (parsed.rpcId != request.rpcId) {
      throw TransportException(
          'rpcId mismatch for $method: sent ${request.rpcId}, got ${parsed.rpcId}');
    }
    return parsed;
  }

  @override
  Future<RpcReceipt> respond(ClientResponse message, {Duration? timeout}) async {
    final httpRequest = await _httpClient.postUrl(_api('respond'));
    httpRequest.headers.contentType = ContentType.json;
    httpRequest.write(message.encode());

    final response = await httpRequest.close()
        .timeout(timeout ?? defaultTimeout);
    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransportException('transport failure for respond',
          statusCode: response.statusCode);
    }
    return RpcReceipt.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  @override
  Future<Uint8List> getBytes(String pathAndQuery, {Duration? timeout}) async {
    // Downloads (e.g. session.export ZIP) can outlive a unary RPC.
    final effectiveTimeout = timeout ?? const Duration(seconds: 60);
    final request =
        await _httpClient.getUrl(baseUri.resolve('/api/$pathAndQuery'));
    final response = await request.close().timeout(
          effectiveTimeout,
          onTimeout: () {
            request.abort();
            throw TransportException('download timeout for $pathAndQuery',
                cause: TimeoutException(effectiveTimeout.toString()));
          },
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransportException('download failed for $pathAndQuery',
          statusCode: response.statusCode);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Stream<ServerRequest> openMux({void Function()? onOpen}) =>
      _openDownlink('events.mux', onOpen);

  @override
  Stream<ServerRequest> openHost({void Function()? onOpen}) =>
      _openDownlink('events.host', onOpen);

  /// Close the shared HttpClient. A dart:io HttpClient keeps idle keep-alive
  /// connections open, which would otherwise keep the process alive after the
  /// last logical operation; long-lived hosts should call this on shutdown.
  Future<void> close() async {
    _httpClient.close(force: true);
  }

  /// Single-subscription downlink reader.
  ///
  /// One malformed frame is dropped without killing the stream (the
  /// connection layer's gap detection covers whatever the frame carried).
  /// Cancelling the subscription closes the socket.
  Stream<ServerRequest> _openDownlink(String path, void Function()? onOpen) async* {
    final wsUri = _ws(path);
    WebSocket? socket;
    try {
      // Reuse the proxy-free HttpClient so the handshake reaches the DSH host
      // directly (a proxy would strip the Upgrade headers → HTTP 426).
      socket = await WebSocket.connect(
        wsUri.toString(),
        customClient: _httpClient,
      );
      onOpen?.call();
      await for (final data in socket) {
        if (data is! String) {
          // The protocol sends text frames only; drop anything else.
          continue;
        }
        ServerRequest? frame;
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map<String, dynamic>) {
            frame = ServerRequest.fromJson(decoded);
          }
        } catch (_) {
          // Drop malformed frame; do not kill the stream.
        }
        if (frame != null) yield frame;
      }
    } finally {
      if (socket != null) {
        try {
          await socket.close();
        } catch (_) {
          // Socket already closed or closing; nothing to clean up.
        }
      }
    }
  }
}
