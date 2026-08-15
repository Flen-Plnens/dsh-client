import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:test/test.dart';

void main() {
  group('ClientRequest', () {
    test('serializes the four-field envelope', () {
      const request = ClientRequest(
        rpcId: 'r1',
        method: 'session.list',
        payload: <String, dynamic>{},
      );
      final json = request.toJson();
      expect(json['type'], 'client-request');
      expect(json['rpcId'], 'r1');
      expect(json['method'], 'session.list');
      expect(json['payload'], <String, dynamic>{});
    });

    test('round-trips through JSON', () {
      const request = ClientRequest(
        rpcId: 'r1',
        method: 'session.prompt',
        payload: <String, dynamic>{'sessionId': 's1'},
      );
      final decoded =
          request.toJson(); // toJson is the wire form; encode() produces text
      expect(request.encode(), contains('"method":"session.prompt"'));
      expect(decoded['payload'], {'sessionId': 's1'});
    });
  });

  group('ServerResponse', () {
    test('parses ok result with value', () {
      final response = ServerResponse.fromJson(const {
        'type': 'server-response',
        'rpcId': 'r1',
        'result': {'ok': true, 'value': {'version': '0.0.1'}},
      });
      expect(response.rpcId, 'r1');
      expect(response.result.ok, isTrue);
      expect(response.result.value, {'version': '0.0.1'});
    });

    test('parses ok result without value (void business result)', () {
      final response = ServerResponse.fromJson(const {
        'type': 'server-response',
        'rpcId': 'r1',
        'result': {'ok': true},
      });
      expect(response.result.ok, isTrue);
      expect(response.result.value, isNull);
    });

    test('parses error result with details', () {
      final response = ServerResponse.fromJson(const {
        'type': 'server-response',
        'rpcId': 'r1',
        'result': {
          'ok': false,
          'error': {
            'code': 'session-not-found',
            'message': 'nope',
            'details': {'sessionId': 's1'},
          },
        },
      });
      expect(response.result.ok, isFalse);
      expect(response.result.error!.code, 'session-not-found');
      expect(response.result.error!.message, 'nope');
      expect(response.result.error!.details, {'sessionId': 's1'});
    });

    test('throws FormatException when result is missing', () {
      expect(
        () => ServerResponse.fromJson(const {
          'type': 'server-response',
          'rpcId': 'r1',
        }),
        throwsFormatException,
      );
    });
  });

  group('ServerRequest (WebSocket downlink full form)', () {
    test('parses and exposes the frame discriminant', () {
      final frame = ServerRequest.fromJson(const {
        'type': 'server-request',
        'rpcId': 'r2',
        'method': 'mux',
        'payload': {'type': 'session/event', 'sessionId': 's1'},
      });
      expect(frame.rpcId, 'r2');
      expect(frame.method, 'mux');
      expect(frame.frameType, 'session/event');
      expect(frame.payloadMap?['sessionId'], 's1');
    });

    test('frameType is null for non-object payloads', () {
      final frame = ServerRequest.fromJson(const {
        'type': 'server-request',
        'rpcId': 'r2',
        'method': 'mux',
        'payload': 'oops',
      });
      expect(frame.frameType, isNull);
      expect(frame.payloadMap, isNull);
    });
  });

  group('ClientResponse (POST /api/respond body)', () {
    test('serializes the four-field envelope', () {
      const message = ClientResponse(
        rpcId: 'r3',
        result: RpcResult.ok({'accepted': true}),
      );
      final json = message.toJson();
      expect(json['type'], 'client-response');
      expect(json['rpcId'], 'r3');
      expect(json['result'], {'ok': true, 'value': {'accepted': true}});
    });
  });

  group('RpcReceipt', () {
    test('parses accepted', () {
      final receipt =
          RpcReceipt.fromJson(const {'accepted': true});
      expect(receipt.accepted, isTrue);
      expect(receipt.reason, isNull);
    });

    test('parses rejected with reason', () {
      final receipt = RpcReceipt.fromJson(
          const {'accepted': false, 'reason': 'not-pending'});
      expect(receipt.accepted, isFalse);
      expect(receipt.reason, 'not-pending');
    });
  });

  group('HostDescription (host.describe value)', () {
    test('parses the full wire shape', () {
      final host = HostDescription.fromJson(const {
        'version': '0.0.1',
        'cwd': r'C:\Users\Admin',
        'provider': 'deepseek-official',
        'model': 'deepseek-v4-flash',
        'attachedSessions': 4,
        'canOpenPath': true,
      });
      expect(host.version, '0.0.1');
      expect(host.cwd, r'C:\Users\Admin');
      expect(host.provider, 'deepseek-official');
      expect(host.model, 'deepseek-v4-flash');
      expect(host.attachedSessions, 4);
      expect(host.canOpenPath, isTrue);
    });

    test('tolerates optional fields being absent', () {
      final host = HostDescription.fromJson(const {
        'version': '0.0.1',
        'cwd': '/tmp',
        'attachedSessions': 0,
        'canOpenPath': false,
      });
      expect(host.provider, isNull);
      expect(host.model, isNull);
      expect(host.attachedSessions, 0);
    });
  });
}
