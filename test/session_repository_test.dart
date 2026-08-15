import 'dart:typed_data';

import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:dsh_flutter/core/session/session_models.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('SessionRepository', () {
    test('listSessions parses rows', () async {
      final transport = FakeTransport();
      transport.enqueue('session.list', FakeTransport.ok({
        'items': [
          {
            'sessionId': 's1',
            'updatedAt': 1700000000000,
            'running': true,
            'blank': false,
            'cwd': r'C:\work',
          },
          {
            'sessionId': 's2',
            'updatedAt': 0,
            'running': false,
            'blank': true,
          },
        ],
      }));
      final repository = SessionRepository(transport);
      final sessions = await repository.listSessions();

      expect(sessions.length, 2);
      expect(sessions[0].sessionId, 's1');
      expect(sessions[0].running, isTrue);
      expect(sessions[0].cwd, r'C:\work');
      expect(sessions[1].blank, isTrue);
    });

    test('listWorkspaces parses items and archived ids', () async {
      final transport = FakeTransport();
      transport.enqueue('workspace.list', FakeTransport.ok({
        'items': [
          {
            'workspaceId': 'w1',
            'path': r'C:\proj',
            'title': '项目',
            'sessionIds': ['s1', 's2'],
            'createdAt': '2026-01-01T00:00:00Z',
            'updatedAt': '2026-01-02T00:00:00Z',
          },
        ],
        'archivedSessionIds': ['s9'],
      }));
      final repository = SessionRepository(transport);
      final result = await repository.listWorkspaces();

      expect(result.items.length, 1);
      expect(result.items.single.title, '项目');
      expect(result.items.single.sessionIds, ['s1', 's2']);
      expect(result.archivedSessionIds, ['s9']);
    });

    test('history parses entries and hasMore', () async {
      final transport = FakeTransport();
      transport.enqueue('session.history', FakeTransport.ok({
        'events': [
          {
            'event': {
              'type': 'user/message',
              'seq': 3,
              'time': 1,
              'surfaceOp': 'append',
              'data': {
                'id': 'u3',
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': 'hi'}
                ],
              },
            },
          },
        ],
        'hasMore': true,
      }));
      final repository = SessionRepository(transport);
      final page = await repository.history('s1', beforeSeq: 10, maxMessages: 50);

      expect(page.hasMore, isTrue);
      expect(page.events.single.type, 'user/message');
      expect(page.events.single.seq, 3);
    });

    test('history sends beforeSeq and maxMessages in the payload', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        seenPayload = payload;
        return FakeTransport.ok({'events': <Object>[], 'hasMore': false});
      };
      final repository = SessionRepository(transport);
      await repository.history('s1', beforeSeq: 42, maxMessages: 7);

      expect(seenPayload, {
        'sessionId': 's1',
        'beforeSeq': 42,
        'maxMessages': 7,
      });
    });

    test('business errors surface as SessionApiException', () async {
      final transport = FakeTransport();
      transport.enqueue(
          'session.list', FakeTransport.fail('session-not-found', 'nope'));
      final repository = SessionRepository(transport);

      await expectLater(
        repository.listSessions(),
        throwsA(isA<SessionApiException>()
            .having((e) => e.code, 'code', 'session-not-found')),
      );
    });

    test('createSession returns the minted id and passes workspaceId',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        seenPayload = payload;
        return FakeTransport.ok({'sessionId': 'new-1'});
      };
      final repository = SessionRepository(transport);
      final id = await repository.createSession(workspaceId: 'w1');

      expect(id, 'new-1');
      expect(seenPayload, {'workspaceId': 'w1'});
    });

    test('prompt sends sessionId, mode and content parts', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.prompt');
        seenPayload = payload;
        return FakeTransport.ok({'accepted': true});
      };
      final repository = SessionRepository(transport);
      await repository.prompt(
        's1',
        [
          {'type': 'text', 'text': 'hello'}
        ],
        mode: 'queue',
      );

      expect(seenPayload, {
        'sessionId': 's1',
        'mode': 'queue',
        'content': [
          {'type': 'text', 'text': 'hello'}
        ],
      });
    });

    test('prompt rejects empty content', () async {
      final transport = FakeTransport();
      final repository = SessionRepository(transport);
      await expectLater(
        repository.prompt('s1', const []),
        throwsArgumentError,
      );
    });

    test('cancel sends session.cancel with the session id', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.cancel');
        seenPayload = payload;
        return FakeTransport.ok({'accepted': true});
      };
      final repository = SessionRepository(transport);
      await repository.cancel('s1');

      expect(seenPayload, {'sessionId': 's1'});
    });

    test('updateQueue sends itemId and the action object', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.updateQueue');
        seenPayload = payload;
        return FakeTransport.ok({'accepted': true});
      };
      final repository = SessionRepository(transport);
      await repository.updateQueue('s1', 'item-9', {'kind': 'steer'});

      expect(seenPayload, {
        'sessionId': 's1',
        'itemId': 'item-9',
        'action': {'kind': 'steer'},
      });
    });

    test('listDirectory omits path when absent and sends it when present',
        () async {
      final transport = FakeTransport();
      final payloads = <Map<String, dynamic>>[];
      transport.callOverride = (method, payload) async {
        expect(method, 'host.listDirectory');
        payloads.add(payload);
        return FakeTransport.ok({
          'path': r'C:\home',
          'home': r'C:\home',
          'crumbs': [
            {'name': 'home', 'path': r'C:\home', 'hidden': false}
          ],
          'entries': [
            {'name': '.hidden', 'path': r'C:\home\.hidden', 'hidden': true},
            {'name': 'proj', 'path': r'C:\home\proj', 'hidden': false},
          ],
          'truncated': false,
        });
      };
      final repository = SessionRepository(transport);

      final listing = await repository.listDirectory();
      expect(payloads[0], isEmpty);
      expect(listing.entries.length, 2);
      expect(listing.entries[0].hidden, isTrue);
      expect(listing.entries[1].name, 'proj');
      expect(listing.crumbs.single.path, r'C:\home');

      await repository.listDirectory(path: r'C:\home\proj');
      expect(payloads[1], {'path': r'C:\home\proj'});
    });

    test('createDirectory sends parent path and single-segment name',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'host.createDirectory');
        seenPayload = payload;
        return FakeTransport.ok({'path': r'C:\home\new-folder'});
      };
      final repository = SessionRepository(transport);
      final created = await repository.createDirectory(r'C:\home', 'new-folder');

      expect(seenPayload, {'path': r'C:\home', 'name': 'new-folder'});
      expect(created, r'C:\home\new-folder');
    });

    test('createWorkspace sends the path and parses workspace+created',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'workspace.create');
        seenPayload = payload;
        return FakeTransport.ok({
          'workspace': {
            'workspaceId': 'w1',
            'path': r'C:\home\proj',
            'title': 'proj',
            'sessionIds': <String>[],
            'createdAt': '2026-01-01T00:00:00Z',
            'updatedAt': '2026-01-01T00:00:00Z',
          },
          'created': true,
        });
      };
      final repository = SessionRepository(transport);
      final result = await repository.createWorkspace(r'C:\home\proj');

      expect(seenPayload, {'path': r'C:\home\proj'});
      expect(result.created, isTrue);
      expect(result.workspace.workspaceId, 'w1');
      expect(result.workspace.title, 'proj');
    });

    test('createWorkspace surfaces workspace-invalid-path as an API error',
        () async {
      final transport = FakeTransport();
      transport.callOverride = (method, payload) async {
        return FakeTransport.fail(
            'workspace-invalid-path', 'cannot create a workspace at "x"');
      };
      final repository = SessionRepository(transport);

      await expectLater(
        repository.createWorkspace(r'C:\missing'),
        throwsA(isA<SessionApiException>()
            .having((e) => e.code, 'code', 'workspace-invalid-path')),
      );
    });

    test('SessionSummary parses the title projection', () {
      final session = SessionSummary.fromJson(const {
        'sessionId': 's1',
        'updatedAt': 0,
        'running': false,
        'blank': false,
        'projections': {
          'asOfSeq': 5,
          'values': {'title': '为 Flutter 客户端开发搜索汇总 README'},
        },
      });
      expect(session.title, '为 Flutter 客户端开发搜索汇总 README');
    });

    test('SessionSummary tolerates a missing projections block', () {
      const session = SessionSummary(
          sessionId: 's1', updatedAt: 0, running: false, blank: false);
      expect(session.title, isNull);
    });

    test('HistoryPage parses the tail title projection', () {
      final page = HistoryPage.fromJson(const {
        'events': <Object>[],
        'hasMore': false,
        'projections': {
          'asOfSeq': 7,
          'values': {'title': '会话标题'},
        },
      });
      expect(page.title, '会话标题');
    });

    test('sessionModels parses current, groups and failures', () async {
      final transport = FakeTransport();
      transport.callOverride = (method, payload) async {
        expect(method, 'session.models');
        expect(payload, {'sessionId': 's1'});
        return FakeTransport.ok({
          'current': {'provider': 'p1', 'model': 'm1'},
          'routable': true,
          'groups': [
            {
              'id': 'p1',
              'name': 'Provider 1',
              'models': [
                {'id': 'm1', 'name': 'Model One'},
                {'id': 'm2', 'name': 'Model Two'},
              ],
            },
          ],
          'failures': [
            {'id': 'p2', 'name': 'Provider 2', 'message': 'boom'},
          ],
        });
      };
      final repository = SessionRepository(transport);
      final catalog = await repository.sessionModels('s1');

      expect(catalog.current.provider, 'p1');
      expect(catalog.groups.single.models.length, 2);
      expect(catalog.groups.single.models[1].name, 'Model Two');
      expect(catalog.failures.single.message, 'boom');
    });

    test('selectModel sends provider/model and parses the selection', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.selectModel');
        seenPayload = payload;
        return FakeTransport.ok({
          'selected': {'provider': 'p1', 'model': 'm2'},
        });
      };
      final repository = SessionRepository(transport);
      final selection = await repository.selectModel('s1', 'p1', 'm2');

      expect(seenPayload, {'sessionId': 's1', 'provider': 'p1', 'model': 'm2'});
      expect(selection.model, 'm2');
    });

    test('listSkills parses the skill rows', () async {
      final transport = FakeTransport();
      transport.callOverride = (method, payload) async {
        expect(method, 'skill.list');
        return FakeTransport.ok({
          'skills': [
            {
              'name': 'net-proxy',
              'description': 'proxy fetching',
              'whenToUse': 'network',
              'modelInvocable': true,
            },
            {
              'name': 'vision-tools',
              'description': 'visual tools',
              'modelInvocable': false,
            },
          ],
        });
      };
      final repository = SessionRepository(transport);
      final skills = await repository.listSkills('s1');

      expect(skills.length, 2);
      expect(skills[0].name, 'net-proxy');
      expect(skills[0].modelInvocable, isTrue);
      expect(skills[1].modelInvocable, isFalse);
    });

    test('renameSession sends the raw title and returns the normalized one',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.rename');
        seenPayload = payload;
        return FakeTransport.ok({
          'title': '规范化后的标题',
          'seq': 42,
        });
      };
      final repository = SessionRepository(transport);
      final title = await repository.renameSession('s1', '新标题');

      expect(seenPayload, {'sessionId': 's1', 'title': '新标题'});
      expect(title, '规范化后的标题');
    });

    test('answerQuestion posts a client-response echoing the rpcId', () async {
      final transport = FakeTransport();
      final repository = SessionRepository(transport);
      await repository.answerQuestion('s1', 'rpc-9', [
        {'id': 'q1', 'selected': ['是']},
      ]);

      expect(transport.responded.length, 1);
      final message = transport.responded.single;
      expect(message.rpcId, 'rpc-9');
      expect(message.result.ok, isTrue);
      expect(message.result.value, {
        'sessionId': 's1',
        'answer': {
          'answers': [
            {'id': 'q1', 'selected': ['是']}
          ],
        },
      });
    });

    test('answerQuestion surfaces a rejected receipt', () async {
      final transport = FakeTransport()..failRespond = true;
      final repository = SessionRepository(transport);

      await expectLater(
        repository.answerQuestion('s1', 'rpc-9', const []),
        throwsA(isA<SessionApiException>()
            .having((e) => e.code, 'code', 'not-pending')),
      );
    });

    test('renameWorkspace sends id and title', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'workspace.rename');
        seenPayload = payload;
        return FakeTransport.ok({'workspace': const <String, dynamic>{}});
      };
      final repository = SessionRepository(transport);
      await repository.renameWorkspace('w1', '新名字');

      expect(seenPayload, {'workspaceId': 'w1', 'title': '新名字'});
    });

    test('deleteWorkspace sends the workspace id', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'workspace.delete');
        seenPayload = payload;
        return FakeTransport.ok({'deleted': true});
      };
      final repository = SessionRepository(transport);
      await repository.deleteWorkspace('w1');

      expect(seenPayload, {'workspaceId': 'w1'});
    });

    test('archiveSession sends the session id', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'workspace.archiveSession');
        seenPayload = payload;
        return FakeTransport.ok({'archivedSessionIds': ['s1']});
      };
      final repository = SessionRepository(transport);
      await repository.archiveSession('s1');

      expect(seenPayload, {'sessionId': 's1'});
    });

    test('sessionSearch sends the query and parses the page', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.search');
        seenPayload = payload;
        return FakeTransport.ok({
          'items': [
            {'sessionId': 's1', 'snippet': '…匹配片段…'},
            {'sessionId': 's2', 'snippet': ''},
          ],
          'hasMore': true,
        });
      };
      final repository = SessionRepository(transport);
      final page = await repository.sessionSearch('flutter gap repair');

      expect(seenPayload, {'query': 'flutter gap repair'});
      expect(page.items.length, 2);
      expect(page.items.first.sessionId, 's1');
      expect(page.items.first.snippet, '…匹配片段…');
      expect(page.items.last.snippet, '');
      expect(page.hasMore, isTrue);
    });

    test('commandsList sends the Remote args and parses descriptors',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'commands/list');
        seenPayload = payload;
        return FakeTransport.ok([
          {
            'name': 'compact',
            'description': '压缩会话上下文',
          },
          {
            'name': 'rename',
            'description': '重命名会话',
            'input': {'hint': '新标题'},
          },
        ]);
      };
      final repository = SessionRepository(transport);
      final commands = await repository.commandsList('s1');

      expect(seenPayload, {
        'args': {'agentId': 's1'}
      });
      expect(commands.length, 2);
      expect(commands.first.name, 'compact');
      expect(commands.last.inputHint, '新标题');
    });

    test('commandsExecute sends the Remote args; null result = admission miss',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'commands/execute');
        seenPayload = payload;
        return FakeTransport.ok(null);
      };
      final repository = SessionRepository(transport);
      final miss = await repository.commandsExecute('s1', '/nope');

      expect(seenPayload, {
        'args': {'agentId': 's1', 'line': '/nope'}
      });
      expect(miss, isNull);
    });

    test('commandsExecute parses an admitted execution', () async {
      final transport = FakeTransport();
      transport.callOverride = (method, payload) async {
        expect(method, 'commands/execute');
        return FakeTransport.ok({
          'commandId': 'c1',
          'result': {'kind': 'error', 'text': 'boom'},
        });
      };
      final repository = SessionRepository(transport);
      final execution =
          await repository.commandsExecute('s1', '/rename 新标题');

      expect(execution!.commandId, 'c1');
      expect(execution.kind, 'error');
      expect(execution.text, 'boom');
    });

    test('insertWorkspaceBefore sends the anchor and parses the order',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'workspace.insertBefore');
        seenPayload = payload;
        return FakeTransport.ok({
          'workspaceIds': ['w2', 'w1'],
        });
      };
      final repository = SessionRepository(transport);
      final order = await repository.insertWorkspaceBefore('w2',
          beforeWorkspaceId: 'w1');

      expect(seenPayload, {'workspaceId': 'w2', 'beforeWorkspaceId': 'w1'});
      expect(order, ['w2', 'w1']);
    });

    test('insertWorkspaceBefore omits the anchor to append', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'workspace.insertBefore');
        seenPayload = payload;
        return FakeTransport.ok({
          'workspaceIds': ['w1', 'w2'],
        });
      };
      final repository = SessionRepository(transport);
      await repository.insertWorkspaceBefore('w2');

      expect(seenPayload, {'workspaceId': 'w2'});
    });

    test('insertSessionBefore sends ids and parses the wrapped workspace',
        () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'workspace.insertSessionBefore');
        seenPayload = payload;
        return FakeTransport.ok({
          'workspace': {
            'workspaceId': 'w1',
            'path': r'C:\proj',
            'title': '项目',
            'sessionIds': ['s2', 's1'],
            'createdAt': '',
            'updatedAt': '',
          },
        });
      };
      final repository = SessionRepository(transport);
      final workspace = await repository.insertSessionBefore('w1', 's2',
          beforeSessionId: 's1');

      expect(seenPayload,
          {'workspaceId': 'w1', 'sessionId': 's2', 'beforeSessionId': 's1'});
      expect(workspace.workspaceId, 'w1');
      expect(workspace.sessionIds, ['s2', 's1']);
    });

    test('forkSession sends the session id and parses the child', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.fork');
        seenPayload = payload;
        return FakeTransport.ok({'sessionId': 'child-1'});
      };
      final repository = SessionRepository(transport);
      final child = await repository.forkSession('s1', atSeq: 42);

      expect(seenPayload, {'sessionId': 's1', 'atSeq': 42});
      expect(child, 'child-1');
    });

    test('forkSession omits atSeq when not given', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'session.fork');
        seenPayload = payload;
        return FakeTransport.ok({'sessionId': 'child-1'});
      };
      final repository = SessionRepository(transport);
      await repository.forkSession('s1');

      expect(seenPayload, {'sessionId': 's1'});
    });

    test('exportSession downloads the export endpoint bytes', () async {
      final transport = FakeTransport()
        ..downloads['session.export?sessionId=s1'] =
            Uint8List.fromList([9, 8, 7]);
      final repository = SessionRepository(transport);
      final bytes = await repository.exportSession('s1');

      expect(transport.downloadCalls, ['session.export?sessionId=s1']);
      expect(bytes, [9, 8, 7]);
    });

    test('goalCreate sends the objective and parses the ref', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'goal.create');
        seenPayload = payload;
        return FakeTransport.ok({
          'ref': {'id': 'g1', 'revision': 1}
        });
      };
      final repository = SessionRepository(transport);
      final ref = await repository.goalCreate('s1', '完成 T2', maxGoalRounds: 5);

      expect(seenPayload,
          {'sessionId': 's1', 'objective': '完成 T2', 'maxGoalRounds': 5});
      expect(ref.id, 'g1');
      expect(ref.revision, 1);
    });

    test('goal mutations send the ref', () async {
      final transport = FakeTransport();
      final calls = <String>[];
      transport.callOverride = (method, payload) async {
        calls.add(method);
        expect(payload['sessionId'], 's1');
        expect(payload['ref'], {'id': 'g1', 'revision': 2});
        if (method == 'goal.clear') return FakeTransport.ok({'cleared': true});
        return FakeTransport.ok({
          'ref': {'id': 'g1', 'revision': 2}
        });
      };
      final repository = SessionRepository(transport);
      const ref = GoalRef(id: 'g1', revision: 2);
      await repository.goalPause('s1', ref);
      await repository.goalResume('s1', ref);
      await repository.goalComplete('s1', ref);
      await repository.goalClear('s1', ref);

      expect(calls, ['goal.pause', 'goal.resume', 'goal.complete', 'goal.clear']);
    });

    test('subagents parses entries and parent availability', () async {
      final transport = FakeTransport();
      transport.callOverride = (method, payload) async {
        expect(method, 'subagent.list');
        expect(payload, {'parentSessionId': 's1'});
        return FakeTransport.ok({
          'entries': [
            {
              'kind': 'child',
              'id': 'c1',
              'mode': 'one-shot',
              'activity': 'inactive',
              'hasChildren': false,
              'label': '子代理甲',
            },
            {
              'kind': 'diagnostic',
              'id': 'c2',
              'reason': 'corrupt',
            },
          ],
          'parentAvailable': true,
        });
      };
      final repository = SessionRepository(transport);
      final list = await repository.subagents('s1');

      expect(list.parentAvailable, isTrue);
      expect(list.entries.length, 2);
      expect(list.entries.first.label, '子代理甲');
      expect(list.entries.last.kind, 'diagnostic');
      expect(list.entries.last.reason, 'corrupt');
    });

    test('interruptSubagent sends ids and mode', () async {
      final transport = FakeTransport();
      Map<String, dynamic>? seenPayload;
      transport.callOverride = (method, payload) async {
        expect(method, 'subagent.interrupt');
        seenPayload = payload;
        return FakeTransport.ok({'accepted': true});
      };
      final repository = SessionRepository(transport);
      await repository.interruptSubagent('s1', 'c1', 'continuable');

      expect(seenPayload,
          {'parentSessionId': 's1', 'childSessionId': 'c1', 'mode': 'continuable'});
    });

    test('approveOrReject echoes the rpcId with the approval outcome',
        () async {
      final transport = FakeTransport();
      final repository = SessionRepository(transport);
      await repository.approveOrReject('s1', 'rpc-ap', 'ap-1', allow: true);
      await repository.approveOrReject('s1', 'rpc-ap2', 'ap-2', allow: false);

      expect(transport.responded.length, 2);
      final allow = transport.responded[0];
      expect(allow.rpcId, 'rpc-ap');
      expect(allow.result.ok, isTrue);
      expect(allow.result.value,
          {'sessionId': 's1', 'approvalId': 'ap-1', 'outcome': 'allowed-once'});
      final reject = transport.responded[1];
      expect(reject.result.value?['outcome'], 'rejected');
    });

    test('approveOrReject surfaces a rejected receipt', () async {
      final transport = FakeTransport()..failRespond = true;
      final repository = SessionRepository(transport);
      await expectLater(
        repository.approveOrReject('s1', 'rpc-ap', 'ap-1', allow: true),
        throwsA(isA<SessionApiException>()),
      );
    });

    test('cancelQuestion sends a cancelled error result', () async {
      final transport = FakeTransport();
      final repository = SessionRepository(transport);
      await repository.cancelQuestion('s1', 'rpc-q');

      final message = transport.responded.single;
      expect(message.rpcId, 'rpc-q');
      expect(message.result.ok, isFalse);
      expect(message.result.error?.code, 'cancelled');
    });

    test('GoalSnapshot.fromProjection parses the whole-value wire shape',
        () {
      final goal = GoalSnapshot.fromProjection({
        'goal': {
          'id': 'g1',
          'revision': 2,
          'objective': '目标',
          'phase': 'blocked',
          'blockedReason': {'code': 'x', 'message': '卡住了'},
          'maxGoalRounds': 9,
        },
        'roundsStarted': 12,
        'createdAt': 1000,
        'updatedAt': 2000,
      });

      expect(goal.id, 'g1');
      expect(goal.revision, 2);
      expect(goal.objective, '目标');
      expect(goal.phase, 'blocked');
      expect(goal.maxGoalRounds, 9);
      expect(goal.roundsStarted, 12);
      expect(goal.createdAt, 1000);
      expect(goal.updatedAt, 2000);
      expect(goal.blockedReasonMessage, '卡住了');
    });
  });

  group('SessionEventRouter', () {
    test('routes session/event frames to the attached store', () async {
      final transport = FakeTransport();
      final router = SessionEventRouter(transport.mux.stream);
      final store = SurfaceStore();
      router.attach('s1', store);

      transport.mux.add(const ServerRequest(
        rpcId: 'r',
        method: 'session/event',
        payload: {
          'type': 'session/event',
          'sessionId': 's1',
          'event': {
            'type': 'user/message',
            'seq': 0,
            'time': 1,
            'surfaceOp': 'append',
            'data': {
              'id': 'u0',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'live'}
              ],
            },
          },
        },
      ));
      // Let the synchronous broadcast delivery run.
      await Future<void>.delayed(Duration.zero);

      expect(store.messages.length, 1);
      expect(store.messages.single.text, 'live');
      await router.dispose();
    });

    test('ignores frames for unattached sessions', () async {
      final transport = FakeTransport();
      final router = SessionEventRouter(transport.mux.stream);
      final store = SurfaceStore();
      router.attach('s1', store);

      transport.mux.add(const ServerRequest(
        rpcId: 'r',
        method: 'session/event',
        payload: {
          'type': 'session/event',
          'sessionId': 'other',
          'event': {
            'type': 'user/message',
            'seq': 0,
            'time': 1,
            'surfaceOp': 'append',
            'data': {
              'id': 'u0',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'not for me'}
              ],
            },
          },
        },
      ));
      await Future<void>.delayed(Duration.zero);

      expect(store.messages, isEmpty);
      await router.dispose();
    });

    test('detach stops delivery', () async {
      final transport = FakeTransport();
      final router = SessionEventRouter(transport.mux.stream);
      final store = SurfaceStore();
      router.attach('s1', store);
      router.detach('s1');

      transport.mux.add(const ServerRequest(
        rpcId: 'r',
        method: 'session/event',
        payload: {
          'type': 'session/event',
          'sessionId': 's1',
          'event': {
            'type': 'user/message',
            'seq': 0,
            'time': 1,
            'surfaceOp': 'append',
            'data': {'id': 'u0', 'role': 'user', 'content': <Object>[]},
          },
        },
      ));
      await Future<void>.delayed(Duration.zero);

      expect(store.messages, isEmpty);
      await router.dispose();
    });
  });
}
