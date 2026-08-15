import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_flutter/core/connection/connection_controller.dart';
import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:dsh_flutter/core/session/session_models.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/ui/session_list_page.dart';
import 'package:dsh_flutter/ui/session_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<StreamController<ServerRequest>> pumpListPage(
  WidgetTester tester,
  FakeGateway gateway,
) async {
  final mux = StreamController<ServerRequest>.broadcast();
  final host = StreamController<ServerRequest>.broadcast();
  await tester.pumpWidget(MaterialApp(
    home: SessionListPage(
      gateway: gateway,
      muxFrames: mux.stream,
      hostFrames: host.stream,
    ),
  ));
  await tester.pumpAndSettle();
  return host; // caller closes to avoid leaks
}

/// Pump a SessionPage wired to fresh broadcast streams; returns (mux, host).
Future<(StreamController<ServerRequest>, StreamController<ServerRequest>)>
    pumpSessionPage(
  WidgetTester tester,
  FakeGateway gateway, {
  bool initialRunning = false,
  ConnectionController? connection,
  Future<List<({Uint8List bytes, String mediaType})>> Function()? imagePicker,
  Future<String?> Function(String sessionId, Uint8List bytes)? saveFile,
}) async {
  final mux = StreamController<ServerRequest>.broadcast();
  final host = StreamController<ServerRequest>.broadcast();
  await tester.pumpWidget(MaterialApp(
    home: SessionPage(
      gateway: gateway,
      muxFrames: mux.stream,
      hostFrames: host.stream,
      sessionId: 's1',
      initialRunning: initialRunning,
      connection: connection,
      imagePicker: imagePicker,
      saveFile: saveFile,
    ),
  ));
  await tester.pumpAndSettle();
  return (mux, host);
}

void main() {
  testWidgets('list page groups sessions by workspace and shows ungrouped',
      (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1', updatedAt: 0, running: true, blank: false),
        const SessionSummary(
            sessionId: 's2', updatedAt: 0, running: false, blank: false),
        const SessionSummary(
            sessionId: 's3',
            updatedAt: 0,
            running: false,
            blank: false,
            cwd: r'C:\loose'),
      ]
      ..workspaces = const WorkspaceListResult(
        items: [
          WorkspaceView(
            workspaceId: 'w1',
            path: r'C:\proj',
            title: '项目 A',
            sessionIds: ['s1', 's2'],
            createdAt: '',
            updatedAt: '',
          ),
        ],
        archivedSessionIds: [],
      );
    final host = await pumpListPage(tester, gateway);

    expect(find.text('项目 A'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    // Session tiles: basename of cwd for ungrouped, short id otherwise.
    expect(find.text('loose'), findsOneWidget);
    expect(find.textContaining('会话 '), findsNWidgets(2));
    expect(find.textContaining('运行中'), findsOneWidget);

    await host.close();
  });

  testWidgets('list page surfaces load errors with a retry button',
      (tester) async {
    final gateway = FakeGateway()
      ..listError = StateError('server exploded');
    final host = await pumpListPage(tester, gateway);

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // Heal and retry.
    gateway.listError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无会话，点击「新会话」开始'), findsOneWidget);

    await host.close();
  });

  testWidgets('tapping a session opens its page', (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1', updatedAt: 0, running: false, blank: false),
      ];
    final host = await pumpListPage(tester, gateway);

    await tester.tap(find.textContaining('会话 '));
    await tester.pumpAndSettle();

    expect(find.byType(SessionPage), findsOneWidget);
    expect(find.text('新会话，输入消息开始对话'), findsOneWidget);

    await host.close();
  });

  testWidgets('new session flow asks for a workspace and navigates',
      (tester) async {
    final gateway = FakeGateway()
      ..workspaces = const WorkspaceListResult(
        items: [
          WorkspaceView(
            workspaceId: 'w1',
            path: r'C:\proj',
            title: '项目 A',
            sessionIds: [],
            createdAt: '',
            updatedAt: '',
          ),
        ],
        archivedSessionIds: [],
      );
    final host = await pumpListPage(tester, gateway);

    await tester.tap(find.text('新会话'));
    await tester.pumpAndSettle();
    expect(find.text('项目 A'), findsWidgets);

    await tester.tap(find.text('项目 A').last);
    await tester.pumpAndSettle();

    expect(gateway.lastCreateWorkspaceId, 'w1');
    expect(find.byType(SessionPage), findsOneWidget);

    await host.close();
  });

  testWidgets('session page renders folded history messages',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = HistoryPage(
      events: [
        userMessage(0, '你好，DeepSeek'),
        assistantMessage(1, [
          {'type': 'text', 'text': '你好！有什么可以帮你？'}
        ]),
      ],
      hasMore: false,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    expect(find.text('你好，DeepSeek'), findsOneWidget);
    expect(find.text('你好！有什么可以帮你？'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('subagent sessions are hidden while fork children stay visible',
      (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 'top-1',
            updatedAt: 3000,
            running: false,
            blank: false,
            cwd: r'C:\work\app'),
        const SessionSummary(
            sessionId: 'child-1',
            updatedAt: 5000,
            running: true,
            blank: false,
            origin: 'subagent'),
        // A fork child carries parentSessionId but no origin: it is NOT a
        // subagent and must remain a top-level row.
        const SessionSummary(
            sessionId: 'fork-1',
            updatedAt: 4000,
            running: false,
            blank: false,
            parentSessionId: 'top-1'),
      ];
    final host = await pumpListPage(tester, gateway);

    // Subagent children (origin == "subagent") are hidden; fork children
    // (parentSessionId only) stay visible.
    expect(find.text('child-1'), findsNothing);
    expect(find.textContaining('fork-1'), findsOneWidget);
    expect(find.text('app'), findsOneWidget);

    await host.close();
  });

  testWidgets('sessions are ordered by updatedAt, newest first',
      (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's-old',
            updatedAt: 1000,
            running: false,
            blank: false,
            cwd: r'C:\w\old'),
        const SessionSummary(
            sessionId: 's-new',
            updatedAt: 9000,
            running: false,
            blank: false,
            cwd: r'C:\w\new'),
        const SessionSummary(
            sessionId: 's-mid',
            updatedAt: 5000,
            running: false,
            blank: false,
            cwd: r'C:\w\mid'),
      ];
    final host = await pumpListPage(tester, gateway);

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    final titles = tiles
        .map((t) => (t.title as Text).data)
        .whereType<String>()
        .toList();
    expect(titles, ['new', 'mid', 'old']);

    await host.close();
  });

  testWidgets(
      'session rows show their own title projection, never the workspace title',
      (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        SessionSummary(
          sessionId: 's1',
          updatedAt: 2000,
          running: false,
          blank: false,
          cwd: r'D:\dsh-flutter',
          projectionValues: const {
            'title': '为 Flutter 客户端开发搜索汇总 README',
          },
        ),
        // No title projection: falls back to the cwd basename.
        const SessionSummary(
            sessionId: 's2',
            updatedAt: 1000,
            running: false,
            blank: false,
            cwd: r'D:\other\untitled'),
      ]
      ..workspaces = const WorkspaceListResult(
        items: [
          WorkspaceView(
            workspaceId: 'w1',
            path: r'D:\dsh-flutter',
            title: 'dsh-flutter',
            sessionIds: ['s1', 's2'],
            createdAt: '',
            updatedAt: '',
          ),
        ],
        archivedSessionIds: [],
      );
    final host = await pumpListPage(tester, gateway);

    // The workspace header keeps the WORKSPACE title.
    expect(find.text('dsh-flutter'), findsOneWidget);
    // Session rows show their own titles (projection / cwd basename).
    expect(find.text('为 Flutter 客户端开发搜索汇总 README'), findsOneWidget);
    expect(find.text('untitled'), findsOneWidget);

    await host.close();
  });

  testWidgets('session page seeds the AppBar title from the history tail',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = const HistoryPage(
      events: [],
      hasMore: false,
      projectionValues: {'title': '为 Flutter 客户端开发搜索汇总 README'},
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    expect(find.text('为 Flutter 客户端开发搜索汇总 README'), findsOneWidget);
    expect(find.textContaining('会话 '), findsNothing);

    await mux.close();
    await host.close();
  });

  testWidgets('context messages render as system rows, not user bubbles',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = HistoryPage(
      events: [
        userMessage(0, '真正的问题'),
        ev('user/message', 1, {
          'id': 'u1',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'background job pwsh-1 finished'}
          ],
          'source': {'kind': 'plugin', 'plugin': 'tool-jobs', 'form': 'notice'},
        }, surfaceOp: 'append'),
      ],
      hasMore: false,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    expect(find.text('真正的问题'), findsOneWidget);
    expect(find.text('系统：tool-jobs · notice'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('context row expands to show the injected content',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = HistoryPage(
      events: [
        ev('user/message', 0, {
          'id': 'u0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'background job pwsh-1 finished with output'}
          ],
          'source': {'kind': 'plugin', 'plugin': 'tool-jobs', 'form': 'notice'},
        }, surfaceOp: 'append'),
      ],
      hasMore: false,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    // Collapsed: the label only, no content.
    expect(find.text('系统：tool-jobs · notice'), findsOneWidget);
    expect(
        find.text('background job pwsh-1 finished with output',
            findRichText: true),
        findsNothing);

    await tester.tap(find.text('系统：tool-jobs · notice'));
    await tester.pumpAndSettle();
    expect(
        find.text('background job pwsh-1 finished with output',
            findRichText: true),
        findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('assistant markdown is rendered (bold/heading)',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = HistoryPage(
      events: [
        userMessage(0, 'hi'),
        assistantMessage(1, [
          {'type': 'text', 'text': '**加粗标题**\n\n普通段落'}
        ]),
      ],
      hasMore: false,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    expect(find.text('加粗标题', findRichText: true), findsOneWidget);
    expect(find.text('普通段落', findRichText: true), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('tool call cards are collapsed by default and expand on tap',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = HistoryPage(
      events: [
        userMessage(0, 'hi'),
        assistantMessage(1, [
          {
            'type': 'tool-call',
            'id': 'call-1',
            'name': 'bash',
            'arguments': '{"cmd":"ls -la"}'
          },
        ]),
      ],
      hasMore: false,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    // Collapsed: the arguments are hidden, the name is visible.
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('{"cmd":"ls -la"}'), findsNothing);

    await tester.tap(find.text('bash'));
    await tester.pumpAndSettle();
    expect(find.text('{"cmd":"ls -la"}'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('sending a prompt calls gateway.prompt in queue mode',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.enterText(find.byType(TextField), '你好 Harness');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(gateway.prompts.length, 1);
    expect(gateway.prompts.single.sessionId, 's1');
    expect(gateway.prompts.single.text, '你好 Harness');
    expect(gateway.prompts.single.mode, 'queue');
    // The input is cleared after a successful send.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);

    await mux.close();
    await host.close();
  });

  testWidgets('cancel button appears while running and calls gateway.cancel',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway,
        initialRunning: true);

    // Both the app bar action and the input-bar stop button are present.
    expect(find.byIcon(Icons.stop_circle_outlined), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.stop_circle_outlined).first);
    await tester.pumpAndSettle();
    expect(gateway.cancels, ['s1']);

    await mux.close();
    await host.close();
  });

  testWidgets('running state follows host/session-status frames',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);

    host.add(ServerRequest(
      rpcId: 'r',
      method: 'host',
      payload: {
        'type': 'host/session-status',
        'sessionId': 's1',
        'running': true,
      },
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.stop_circle_outlined), findsNWidgets(2));

    await mux.close();
    await host.close();
  });

  testWidgets('queue strip separates queued (operable) from steering and '
      'hides context', (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/queue',
        'sessionId': 's1',
        'items': [
          {
            'id': 'item-queued',
            'placement': 'queued',
            'message': {
              'id': 'm1',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '排队的问题'}
              ],
            },
          },
          {
            'id': 'item-steering',
            'placement': 'steering',
            'message': {
              'id': 'm2',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '引导中的问题'}
              ],
            },
          },
          {
            'id': 'item-context',
            'placement': 'context',
            'message': {
              'id': 'm3',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '内部上下文不进队列'}
              ],
            },
          },
        ],
      },
    ));
    await tester.pumpAndSettle();

    // Queued: shown as an operable chip.
    expect(find.text('待处理队列'), findsOneWidget);
    expect(find.text('排队的问题'), findsOneWidget);
    // Steering: read-only notice, no operation buttons on it.
    expect(find.textContaining('正在引导：'), findsOneWidget);
    expect(find.textContaining('引导中的问题'), findsOneWidget);
    // Context: never in the user queue UI.
    expect(find.text('内部上下文不进队列'), findsNothing);
    // Exactly one removable chip (the queued item).
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(gateway.queueActions.single.itemId, 'item-queued');
    expect(gateway.queueActions.single.action, {'kind': 'remove'});

    await mux.close();
    await host.close();
  });

  testWidgets('subscribed baseline beyond the window tail triggers a gap '
      'repull', (tester) async {
    final gateway = FakeGateway();
    gateway.historyPages.add(HistoryPage(
      events: [
        userMessage(0, '旧问题'),
        assistantMessage(1, [
          {'type': 'text', 'text': '旧回答'}
        ]),
      ],
      hasMore: false,
    ));
    gateway.historyPages.add(HistoryPage(
      events: [
        userMessage(0, '旧问题'),
        assistantMessage(1, [
          {'type': 'text', 'text': '旧回答'}
        ]),
        userMessage(2, '断线期间的问题'),
        assistantMessage(3, [
          {'type': 'text', 'text': '补上的回答'}
        ]),
      ],
      hasMore: false,
    ));
    final (mux, host) = await pumpSessionPage(tester, gateway);
    expect(find.text('旧回答'), findsOneWidget);
    expect(gateway.historyCallCount, 1);

    // The host's durable baseline is ahead of our window tail (seq 1).
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/subscribed',
        'sessionId': 's1',
        'lastSeq': 3,
      },
    ));
    await tester.pumpAndSettle();

    expect(gateway.historyCallCount, 2);
    expect(find.text('断线期间的问题'), findsOneWidget);
    expect(find.text('补上的回答'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('a live event seq gap buffers and repulls the tail page',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyPages.add(HistoryPage(
      events: [userMessage(0, 'a')],
      hasMore: false,
    ));
    gateway.historyPages.add(HistoryPage(
      events: [
        userMessage(0, 'a'),
        assistantMessage(1, [
          {'type': 'text', 'text': '缺失的片段'}
        ]),
      ],
      hasMore: false,
    ));
    final (mux, host) = await pumpSessionPage(tester, gateway);
    expect(find.text('a'), findsOneWidget);
    expect(gateway.historyCallCount, 1);

    // A live event jumping past the window tail (tail=0, event seq=5).
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'session/event',
      payload: {
        'type': 'session/event',
        'sessionId': 's1',
        'event': {
          'type': 'user/message',
          'seq': 5,
          'time': 1,
          'surfaceOp': 'append',
          'data': {
            'id': 'u5',
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '新问题'}
            ],
            'source': {'kind': 'user'},
          },
        },
      },
    ));
    await tester.pumpAndSettle();

    expect(gateway.historyCallCount, 2);
    // The repulled tail filled the hole, and the buffered live event landed.
    expect(find.text('缺失的片段'), findsOneWidget);
    expect(find.text('新问题'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('stale title projection frames never overwrite newer ones',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/projection',
        'sessionId': 's1',
        'key': 'title',
        'value': '新标题',
        'seq': 10,
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('新标题'), findsOneWidget);

    // A stale lower-seq frame must not regress the title.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/projection',
        'sessionId': 's1',
        'key': 'title',
        'value': '旧标题',
        'seq': 5,
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('新标题'), findsOneWidget);
    expect(find.text('旧标题'), findsNothing);

    await mux.close();
    await host.close();
  });

  testWidgets('blank sessions hide unless current; archived sessions hide',
      (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 'blank-1',
            updatedAt: 3000,
            running: false,
            blank: true,
            cwd: r'C:\b'),
        const SessionSummary(
            sessionId: 'normal',
            updatedAt: 2000,
            running: false,
            blank: false,
            cwd: r'C:\n'),
        const SessionSummary(
            sessionId: 'arch-1',
            updatedAt: 1000,
            running: false,
            blank: false,
            cwd: r'C:\a'),
      ]
      ..workspaces = const WorkspaceListResult(
        items: [],
        archivedSessionIds: ['arch-1'],
      );
    final host = await pumpListPage(tester, gateway);

    // Blank (not current) and archived rows are hidden; normal stays.
    expect(find.text('n'), findsOneWidget);
    expect(find.text('b'), findsNothing);
    expect(find.text('a'), findsNothing);

    await host.close();
  });

  testWidgets('workspace header menu renames and deletes a workspace',
      (tester) async {
    final gateway = FakeGateway()
      ..workspaces = const WorkspaceListResult(
        items: [
          WorkspaceView(
            workspaceId: 'w1',
            path: r'C:\proj',
            title: '项目 A',
            sessionIds: <String>[],
            createdAt: '',
            updatedAt: '',
          ),
        ],
        archivedSessionIds: [],
      );
    final host = await pumpListPage(tester, gateway);

    // Rename via the header menu.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '项目 B',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(gateway.workspaceRenames, ['w1:项目 B']);

    // Delete via the header menu (confirm dialog).
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last); // confirm in the dialog
    await tester.pumpAndSettle();
    expect(gateway.workspaceDeletes, ['w1']);

    await host.close();
  });

  testWidgets('long-pressing a session row archives it', (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1',
            updatedAt: 1000,
            running: false,
            blank: false,
            cwd: r'C:\work\app'),
      ];
    final host = await pumpListPage(tester, gateway);

    // Long-press opens the action sheet; archive confirms in the dialog.
    await tester.longPress(find.text('app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档').last);
    await tester.pumpAndSettle();

    expect(gateway.sessionArchives, ['s1']);

    await host.close();
  });

  testWidgets('a blank session created via the new-session flow stays visible '
      'as the current session', (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 'created-1',
            updatedAt: 0,
            running: false,
            blank: true,
            cwd: r'C:\new'),
      ]
      ..createdId = 'created-1';
    final host = await pumpListPage(tester, gateway);

    // Blank and not yet current: hidden.
    expect(find.text('new'), findsNothing);

    // New-session flow (no workspaces → default directory) opens it.
    await tester.tap(find.text('新会话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionPage), findsOneWidget);

    // Back on the list: the blank session is now the current session.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('new'), findsOneWidget);

    await host.close();
  });

  testWidgets('live events that race the initial history load are buffered',
      (tester) async {
    final gateway = FakeGateway();
    final gate = Completer<void>();
    gateway.historyGate = gate;
    final mux = StreamController<ServerRequest>.broadcast();
    final host = StreamController<ServerRequest>.broadcast();
    await tester.pumpWidget(MaterialApp(
      home: SessionPage(
        gateway: gateway,
        muxFrames: mux.stream,
        hostFrames: host.stream,
        sessionId: 's1',
      ),
    ));
    await tester.pump();

    // While history is still in flight, a live chunk arrives.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'session/event',
      payload: {
        'type': 'session/event',
        'sessionId': 's1',
        'event': {
          'type': 'assistant/chunk',
          'seq': 0,
          'time': 1,
          'data': {
            'chunk': {'type': 'text-delta', 'index': 0, 'text': '缓冲输出'}
          },
        },
      },
    ));
    await tester.pump();

    // Release the history snapshot (empty); the buffered event must survive.
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('缓冲输出'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('session page streams live chunks from the mux stream',
      (tester) async {
    final gateway = FakeGateway(); // empty history
    final (mux, host) = await pumpSessionPage(tester, gateway);
    expect(find.text('新会话，输入消息开始对话'), findsOneWidget);

    // A live assistant chunk for this session arrives over the mux stream.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'session/event',
      payload: {
        'type': 'session/event',
        'sessionId': 's1',
        'event': {
          'type': 'assistant/chunk',
          'seq': 0,
          'time': 1,
          'data': {
            'chunk': {'type': 'text-delta', 'index': 0, 'text': '正在流式输出'}
          },
        },
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('正在流式输出'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('a live turn/end clears the thinking indicator',
      (tester) async {
    final gateway = FakeGateway(); // empty history
    final (mux, host) = await pumpSessionPage(tester, gateway);

    // Reasoning-only chunks: the bubble shows the thinking indicator. A
    // timed pump flushes the broadcast delivery microtask and renders one
    // frame — pumpAndSettle would never settle (spinner animates forever).
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'session/event',
      payload: {
        'type': 'session/event',
        'sessionId': 's1',
        'event': {
          'type': 'assistant/chunk',
          'seq': 0,
          'time': 1,
          'data': {
            'chunk': {
              'type': 'reasoning-delta',
              'index': 0,
              'text': '分析中'
            }
          },
        },
      },
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('正在思考…'), findsOneWidget);

    // The turn ends: the indicator must disappear.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'session/event',
      payload: {
        'type': 'session/event',
        'sessionId': 's1',
        'event': {
          'type': 'turn/end',
          'seq': 1,
          'time': 2,
          'data': {'turn': 1, 'reason': {'kind': 'completed'}},
        },
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('正在思考…'), findsNothing);

    await mux.close();
    await host.close();
  });

  testWidgets('model picker lists groups and switches the model',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    // No model label until loaded.
    expect(find.textContaining('模型：'), findsNothing);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('选择模型'), findsOneWidget);
    expect(find.text('Provider 1'), findsOneWidget);
    expect(find.text('Model Two'), findsOneWidget);

    await tester.tap(find.text('Model Two'));
    await tester.pumpAndSettle();

    expect(gateway.modelSelections.single.provider, 'p1');
    expect(gateway.modelSelections.single.model, 'm2');
    expect(find.text('模型：Model Two'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('skill picker inserts the slash invocation into the input',
      (tester) async {
    final gateway = FakeGateway()
      ..skills = const [
        SkillEntry(
          name: 'net-proxy',
          description: 'proxy fetching',
          modelInvocable: true,
        ),
      ];
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.bolt_outlined));
    await tester.pumpAndSettle();
    expect(find.text('技能'), findsOneWidget);
    expect(find.text('net-proxy'), findsOneWidget);

    await tester.tap(find.text('net-proxy'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '/net-proxy ');

    await mux.close();
    await host.close();
  });

  testWidgets('rename dialog renames the session and updates the app bar',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '新标题',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(gateway.renames, ['新标题']);
    expect(find.text('新标题'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('question/requested shows a dialog and submits the answer',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'rpc-q1',
      method: 'mux',
      payload: {
        'type': 'question/requested',
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q1',
            'question': '继续吗？',
            'options': [
              {'label': '继续'},
              {'label': '停止'},
            ],
          },
        ],
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('模型提问'), findsOneWidget);
    expect(find.text('继续吗？'), findsOneWidget);

    await tester.tap(find.text('继续'));
    await tester.tap(find.text('提交回答'));
    await tester.pumpAndSettle();

    expect(gateway.questionAnswers.single.rpcId, 'rpc-q1');
    final answer = gateway.questionAnswers.single.answers.single;
    expect(answer['id'], 'q1');
    expect(answer['selected'], ['继续']);

    await mux.close();
    await host.close();
  });

  testWidgets('long-pressing send submits in steer mode', (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.enterText(find.byType(TextField), '别管刚才的');
    await tester.longPress(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(gateway.prompts.single.mode, 'steer');
    expect(gateway.prompts.single.text, '别管刚才的');

    await mux.close();
    await host.close();
  });

  testWidgets('queued item can be edited via updateQueue edit',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/queue',
        'sessionId': 's1',
        'items': [
          {
            'id': 'item-1',
            'placement': 'queued',
            'message': {
              'id': 'm1',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '原内容'}
              ],
            },
          },
        ],
      },
    ));
    await tester.pumpAndSettle();

    // The chip's edit button (tooltip '编辑'; the app-bar one is '重命名会话').
    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '新内容',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(gateway.queueActions.single.itemId, 'item-1');
    expect(gateway.queueActions.single.action, {
      'kind': 'edit',
      'content': [
        {'type': 'text', 'text': '新内容'}
      ],
    });

    await mux.close();
    await host.close();
  });

  testWidgets('image messages load their attachment bytes and render',
      (tester) async {
    // A minimal 1x1 transparent PNG.
    final pngBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
    final gateway = FakeGateway()
      ..attachments['img-1'] = pngBytes;
    gateway.historyBySession['s1'] = HistoryPage(
      events: [
        userMessage(0, '看这张图'),
        assistantMessage(1, [
          {
            'type': 'image',
            'attachment': {
              'attachmentId': 'img-1',
              'mediaType': 'image/png',
              'width': 1,
              'height': 1,
            },
          },
        ]),
      ],
      hasMore: false,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    expect(find.byType(Image), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('picking images shows thumbnails and sends image parts',
      (tester) async {
    final pngBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(
      tester,
      gateway,
      imagePicker: () async => [
        (bytes: pngBytes, mediaType: 'image/png'),
      ],
    );

    // No thumbnails yet.
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.byIcon(Icons.image_outlined));
    await tester.pumpAndSettle();
    // Thumbnail strip appears (1 image).
    expect(find.byType(Image), findsWidgets);

    await tester.enterText(find.byType(TextField), '附图');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(gateway.prompts.length, 1);
    final content = gateway.prompts.single.content;
    expect(content.length, 2);
    expect(content[0]['type'], 'image');
    expect(content[0]['data'], base64Encode(pngBytes));
    expect(content[1], {'type': 'text', 'text': '附图'});

    await mux.close();
    await host.close();
  });

  testWidgets('a failing image picker surfaces the error instead of staying '
      'silent', (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(
      tester,
      gateway,
      imagePicker: () async => throw StateError('picker exploded'),
    );

    await tester.tap(find.byIcon(Icons.image_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('打开文件选择器失败'), findsOneWidget);
    expect(find.textContaining('picker exploded'), findsOneWidget);
    // No crash and the button stays usable.
    expect(tester.takeException(), isNull);

    await mux.close();
    await host.close();
  });

  testWidgets('a disconnected transport shows a reconnect banner',
      (tester) async {
    final connection = ConnectionController(
      FakeTransport(),
      config: const ConnectionConfig(
        backoffBaseMs: 20,
        backoffMaxMs: 20,
        streamOpenTimeout: Duration(seconds: 1),
      ),
    );
    connection.start();
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(
      tester,
      gateway,
      connection: connection,
    );
    // Connected: no banner.
    expect(find.textContaining('连接已断开'), findsNothing);

    connection.stop();
    // The banner shows a spinner — pumpAndSettle would never settle; use
    // timed pumps instead.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('连接已断开'), findsOneWidget);

    await connection.dispose();
    await mux.close();
    await host.close();
  });

  testWidgets('subagent context rows open the child session',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = HistoryPage(
      events: [
        ev('user/message', 0, {
          'id': 'u0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '子代理已汇报'}
          ],
          'source': {
            'kind': 'subagent-report',
            'form': 'relay',
            'senderSessionId': 'child-1',
          },
        }, surfaceOp: 'append'),
      ],
      hasMore: false,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    expect(find.text('系统：subagent-report · relay'), findsOneWidget);
    await tester.tap(find.text('系统：subagent-report · relay'));
    await tester.pumpAndSettle();
    expect(find.text('打开子代理会话'), findsOneWidget);

    await tester.ensureVisible(find.text('打开子代理会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开子代理会话'));
    await tester.pumpAndSettle();

    // The child session page is pushed on top (the opaque route hides the
    // parent, so exactly one SessionPage remains in the tree).
    expect(find.byType(SessionPage), findsOneWidget);
    expect(find.text('新会话，输入消息开始对话'), findsOneWidget);
    // The producer label seeds the child page's title until its own title
    // projection arrives.
    expect(find.text('subagent-report'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('approval frames render a read-only notice and resolve away',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'approval/requested',
        'sessionId': 's1',
        'approvalId': 'ap-1',
        'toolName': 'bash',
        'reason': 'run rm -rf',
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('等待审批：bash'), findsOneWidget);

    // The card answers: allow-once echoes the frame's rpcId with the
    // approval outcome.
    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();
    expect(gateway.approvalAnswers.single,
        (sessionId: 's1', rpcId: 'r', approvalId: 'ap-1', allow: true));

    // The resolved frame removes the card (UI converges).
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'approval/resolved',
        'sessionId': 's1',
        'approvalId': 'ap-1',
        'outcome': 'allowed-once',
      },
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('等待审批'), findsNothing);

    await mux.close();
    await host.close();
  });

  testWidgets('approval reject answers with rejected', (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'rpc-ap2',
      method: 'mux',
      payload: {
        'type': 'approval/requested',
        'sessionId': 's1',
        'approvalId': 'ap-2',
        'toolName': 'bash',
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(gateway.approvalAnswers.single,
        (sessionId: 's1', rpcId: 'rpc-ap2', approvalId: 'ap-2', allow: false));

    await mux.close();
    await host.close();
  });

  testWidgets('model picker asks for the reasoning effort when advertised',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // The current-model header uses display names, not wire ids.
    expect(find.textContaining('当前：Model One'), findsOneWidget);

    // Select the vision model: it advertises two efforts.
    await tester.tap(find.text('Vision Model'));
    await tester.pumpAndSettle();
    expect(find.text('推理等级（Vision Model）'), findsOneWidget);
    expect(find.text('高'), findsOneWidget);

    await tester.tap(find.text('高'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(gateway.modelSelections.single.model, 'm3');
    expect(gateway.modelSelections.single.reasoningEffort, 'high');
    // Label uses display names (model + effort), not raw wire ids.
    expect(find.text('模型：Vision Model（高）'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('model picker shows the reasoning block immediately when the '
      'current model advertises levels', (tester) async {
    final gateway = FakeGateway()
      ..modelCatalog = const ModelCatalog(
        current: ModelSelection(
            provider: 'p1', model: 'm3', reasoningEffort: 'high'),
        routable: true,
        groups: [
          ModelProviderGroup(
            id: 'p1',
            name: 'Provider 1',
            models: [
              ModelEntry(
                id: 'm3',
                name: 'Vision Model',
                reasoning: ModelReasoning(
                  efforts: [
                    ModelReasoningEffort(id: 'low', name: '低'),
                    ModelReasoningEffort(id: 'high', name: '高'),
                  ],
                  defaultEffort: 'low',
                ),
              ),
            ],
          ),
        ],
        failures: [],
      );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // Two blocks visible together: the model list AND the reasoning levels —
    // no click needed to reveal the effort block.
    expect(find.text('Vision Model'), findsOneWidget);
    expect(find.text('推理等级（Vision Model）'), findsOneWidget);
    expect(find.text('高'), findsOneWidget);

    // The current effort (high) is pre-selected; confirm applies it as-is.
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(gateway.modelSelections.single.model, 'm3');
    expect(gateway.modelSelections.single.reasoningEffort, 'high');

    await mux.close();
    await host.close();
  });

  testWidgets('a question with options also offers a custom answer input',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'rpc-q3',
      method: 'mux',
      payload: {
        'type': 'question/requested',
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q3',
            'question': '选哪个？',
            'options': [
              {'label': 'A'},
              {'label': 'B'},
            ],
          },
        ],
      },
    ));
    await tester.pumpAndSettle();

    // The free-form input sits below the options.
    final customField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(customField, findsOneWidget);
    await tester.enterText(customField, '自定义补充');
    await tester.tap(find.text('A'));
    await tester.tap(find.text('提交回答'));
    await tester.pumpAndSettle();

    final answer = gateway.questionAnswers.single.answers.single;
    expect(answer['id'], 'q3');
    expect(answer['selected'], ['A']);
    expect(answer['custom'], '自定义补充');

    await mux.close();
    await host.close();
  });

  testWidgets('reconnect banner offers an immediate reconnect action',
      (tester) async {
    final connection = ConnectionController(
      FakeTransport(),
      config: const ConnectionConfig(
        backoffBaseMs: 20,
        backoffMaxMs: 20,
        streamOpenTimeout: Duration(seconds: 1),
      ),
    );
    connection.start();
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(
      tester,
      gateway,
      connection: connection,
    );

    connection.stop();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('连接已断开'), findsOneWidget);

    await tester.tap(find.text('立即重连'));
    await tester.pump(const Duration(milliseconds: 50));
    // The loop restarted: back to the connecting phase (no longer stopped).
    expect(connection.isRunning, isTrue);

    await connection.dispose();
    await mux.close();
    await host.close();
  });

  testWidgets('markdown renders plain text, untagged fences and tagged fences '
      'without throwing', (tester) async {
    final gateway = FakeGateway();
    gateway.historyPages.add(HistoryPage(
      events: [
        assistantMessage(0, [
          {
            'type': 'text',
            'text': '普通段落。\n\n```\n无语言代码块\n```\n\n'
                '```dart\nvoid main() {}\n```',
          }
        ]),
      ],
      hasMore: false,
    ));
    final (mux, host) = await pumpSessionPage(tester, gateway);

    // Plain paragraph (no code).
    expect(find.text('普通段落。', findRichText: true), findsOneWidget);
    // Fenced block without a language marker.
    expect(
        find.text('无语言代码块', findRichText: true), findsOneWidget);
    // Fenced block with a language marker.
    expect(find.text('void main() {}', findRichText: true), findsOneWidget);
    // No red ErrorWidget and no build/layout exception was recorded.
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);

    await mux.close();
    await host.close();
  });

  testWidgets('session search merges host content matches and local title '
      'matches', (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1',
            updatedAt: 1000,
            running: false,
            blank: false,
            cwd: r'C:\work\app'),
        const SessionSummary(
            sessionId: 's2',
            updatedAt: 900,
            running: false,
            blank: false,
            cwd: r'C:\docs\flutter'),
      ]
      ..searchResult = const SearchPage(
        items: [SearchItem(sessionId: 's1', snippet: '…匹配片段…')],
        hasMore: false,
      );
    final host = await pumpListPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'flutter');
    await tester.pump(const Duration(milliseconds: 300)); // debounce
    await tester.pumpAndSettle();

    expect(gateway.searchQueries, ['flutter']);
    // s1 from host content search (with snippet); s2 local basename match.
    expect(find.text('…匹配片段…'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('flutter'),
      ),
      findsOneWidget,
    );

    // Tapping a result opens that session.
    await tester.tap(find.text('…匹配片段…'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionPage), findsOneWidget);

    await host.close();
  });

  testWidgets('content search failure falls back to name matches only',
      (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1',
            updatedAt: 1000,
            running: false,
            blank: false,
            cwd: r'C:\work\app'),
      ]
      ..searchError = StateError('search exploded');
    final host = await pumpListPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'app');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.textContaining('内容搜索暂不可用'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('app'),
      ),
      findsOneWidget,
    );

    await host.close();
  });

  testWidgets('session search with no matches shows a notice', (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1',
            updatedAt: 1000,
            running: false,
            blank: false,
            cwd: r'C:\work\app'),
      ];
    final host = await pumpListPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('无匹配会话'), findsOneWidget);

    await host.close();
  });

  testWidgets('command picker inserts a slash line and send routes through '
      'commands.execute', (tester) async {
    final gateway = FakeGateway()
      ..commands = [
        const CommandEntry(name: 'compact', description: '压缩会话上下文'),
      ];
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.tag));
    await tester.pumpAndSettle();
    expect(find.text('/compact'), findsOneWidget);
    expect(gateway.commandListCalls, ['s1']);
    await tester.tap(find.text('/compact'));
    await tester.pumpAndSettle();
    expect(find.text('/compact '), findsOneWidget);

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    // The send path trims the line: '/compact ' → '/compact'.
    expect(gateway.commandExecutions.single.line, '/compact');
    expect(gateway.prompts, isEmpty);

    await mux.close();
    await host.close();
  });

  testWidgets('a commands/change frame invalidates the cached command catalog',
      (tester) async {
    final gateway = FakeGateway()
      ..commands = const [CommandEntry(name: 'compact', description: '')];
    final (mux, host) = await pumpSessionPage(tester, gateway);

    // First open fetches the catalog once.
    await tester.tap(find.byIcon(Icons.tag));
    await tester.pumpAndSettle();
    expect(gateway.commandListCalls, ['s1']);
    await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
    await tester.pumpAndSettle();

    // Registry notification: the next open must refetch.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {'type': 'commands/change'},
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.tag));
    await tester.pumpAndSettle();
    expect(gateway.commandListCalls, ['s1', 's1']);

    await mux.close();
    await host.close();
  });

  testWidgets('command/run and command/done render as a persistent command '
      'row', (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/event',
        'sessionId': 's1',
        'event': {
          'type': 'command/run',
          'seq': 1,
          'time': 1,
          'surfaceOp': 'append',
          'data': {
            'commandId': 'c1',
            'name': 'compact',
            'source': {'kind': 'user'},
          },
        },
      },
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('/compact', findRichText: true), findsOneWidget);
    expect(find.text('执行中…'), findsOneWidget);

    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/event',
        'sessionId': 's1',
        'event': {
          'type': 'command/done',
          'seq': 2,
          'time': 1,
          'surfaceOp': 'append',
          'data': {
            'commandId': 'c1',
            'kind': 'success',
          },
        },
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('/compact', findRichText: true), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('an unknown slash line reports an admission miss without a '
      'prompt', (tester) async {
    final gateway = FakeGateway()..commandExecutionResult = null;
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.enterText(find.byType(TextField), '/nope');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(gateway.commandExecutions.single.line, '/nope');
    expect(gateway.prompts, isEmpty);
    expect(find.textContaining('未知或格式错误的命令'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('an admitted command error surfaces its handler text',
      (tester) async {
    final gateway = FakeGateway()
      ..commandExecutionResult = const CommandExecution(
        commandId: 'c1',
        kind: 'error',
        text: 'boom',
      );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.enterText(find.byType(TextField), '/rename 新标题');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(gateway.commandExecutions.single.line, '/rename 新标题');
    expect(gateway.prompts, isEmpty);
    expect(find.textContaining('命令执行失败：boom'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('question intent labels the plan-review and pre-selects the '
      'approve option', (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'rpc-q2',
      method: 'mux',
      payload: {
        'type': 'question/requested',
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q2',
            'question': '确认计划？',
            'detail': '计划正文…',
            'intent': {'kind': 'plan-review', 'approve': '批准'},
            'options': [
              {'label': '批准'},
              {'label': '拒绝'},
            ],
          },
        ],
      },
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('计划评审'), findsOneWidget);
    expect(find.textContaining('默认选择「批准」'), findsOneWidget);
    await tester.tap(find.text('提交回答'));
    await tester.pumpAndSettle();

    expect(gateway.questionAnswers.single.rpcId, 'rpc-q2');
    final answer = gateway.questionAnswers.single.answers.single;
    expect(answer['id'], 'q2');
    expect(answer['selected'], ['批准']);

    await mux.close();
    await host.close();
  });

  testWidgets('an image-capability refusal surfaces a model hint',
      (tester) async {
    final gateway = FakeGateway()
      ..promptError = const SessionApiException(
        'Model "deepseek-v4-pro" does not support image input',
        code: 'attachment-error',
      );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.enterText(find.byType(TextField), '看看这张图');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.textContaining('选择支持视觉的模型'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('a subscribed baseline racing the initial load clears the '
      'loading state after the repull', (tester) async {
    final gateway = FakeGateway();
    final gate = Completer<void>();
    gateway.historyGate = gate;
    gateway.historyPages.add(
        HistoryPage(events: [userMessage(0, '第一页')], hasMore: false));
    gateway.historyPages.add(HistoryPage(
        events: [userMessage(0, '第一页'), userMessage(3, '补拉')],
        hasMore: false));
    final mux = StreamController<ServerRequest>.broadcast();
    final host = StreamController<ServerRequest>.broadcast();
    await tester.pumpWidget(MaterialApp(
      home: SessionPage(
        gateway: gateway,
        muxFrames: mux.stream,
        hostFrames: host.stream,
        sessionId: 's1',
      ),
    ));
    await tester.pump();

    // The durable baseline (seq 3) arrives while the first history load is
    // still held by the gate.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/subscribed',
        'sessionId': 's1',
        'lastSeq': 3,
      },
    ));
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    // The repull branch must finish the loading state (no permanent spinner).
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('补拉'), findsOneWidget);
    expect(gateway.historyCallCount, 2);

    await mux.close();
    await host.close();
  });

  testWidgets('a goal from history survives reopening the session (P1)',
      (tester) async {
    final gateway = FakeGateway();
    gateway.historyBySession['s1'] = HistoryPage(
      events: [userMessage(0, 'hi')],
      hasMore: false,
      projectionValues: {
        'goal': {
          'goal': {
            'id': 'g1',
            'revision': 1,
            'objective': '已有目标',
            'phase': 'paused',
            'maxGoalRounds': 3,
          },
          'roundsStarted': 7,
          'createdAt': 1,
          'updatedAt': 2,
        },
      },
      projectionAsOfSeq: 5,
    );
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.flag_outlined));
    await tester.pumpAndSettle();
    expect(find.text('已有目标'), findsOneWidget);
    expect(find.textContaining('已运行 7 轮'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('dismissing the question dialog cancels it with the host (P2)',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'rpc-q',
      method: 'mux',
      payload: {
        'type': 'question/requested',
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q1',
            'question': '继续？',
            'options': [
              {'label': '是'},
              {'label': '否'},
            ],
          },
        ],
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('模型提问'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(gateway.cancelledQuestions, ['rpc-q']);
    expect(gateway.questionAnswers, isEmpty);

    await mux.close();
    await host.close();
  });

  testWidgets('a question/resolved frame dismisses the open dialog without a '
      'redundant cancel (P2)', (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    mux.add(ServerRequest(
      rpcId: 'rpc-q2',
      method: 'mux',
      payload: {
        'type': 'question/requested',
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q1',
            'question': '继续？',
            'options': [
              {'label': '是'},
              {'label': '否'},
            ],
          },
        ],
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('模型提问'), findsOneWidget);

    // The host settles the ask elsewhere while the dialog is open.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'question/resolved',
        'sessionId': 's1',
        'questionRpcId': 'rpc-q2',
        'outcome': 'cancelled',
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('模型提问'), findsNothing);
    // No redundant cancel response for an already-resolved question.
    expect(gateway.cancelledQuestions, isEmpty);

    await mux.close();
    await host.close();
  });

  testWidgets('session action sheet moves a session to the top of its '
      'workspace', (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1', updatedAt: 1000, running: false, blank: false),
        const SessionSummary(
            sessionId: 's2', updatedAt: 900, running: false, blank: false),
      ]
      ..workspaces = const WorkspaceListResult(
        items: [
          WorkspaceView(
            workspaceId: 'w1',
            path: r'C:\proj',
            title: '项目 A',
            sessionIds: ['s1', 's2'],
            createdAt: '',
            updatedAt: '',
          ),
        ],
        archivedSessionIds: [],
      );
    final host = await pumpListPage(tester, gateway);

    await tester.longPress(find.text('会话 s2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移至顶部'));
    await tester.pumpAndSettle();

    expect(gateway.sessionMoves.single.workspaceId, 'w1');
    expect(gateway.sessionMoves.single.sessionId, 's2');
    expect(gateway.sessionMoves.single.beforeSessionId, 's1');

    await host.close();
  });

  testWidgets('workspace header menu moves a workspace to the top',
      (tester) async {
    final gateway = FakeGateway()
      ..workspaces = const WorkspaceListResult(
        items: [
          WorkspaceView(
            workspaceId: 'w1',
            path: r'C:\a',
            title: 'A',
            sessionIds: <String>[],
            createdAt: '',
            updatedAt: '',
          ),
          WorkspaceView(
            workspaceId: 'w2',
            path: r'C:\b',
            title: 'B',
            sessionIds: <String>[],
            createdAt: '',
            updatedAt: '',
          ),
        ],
        archivedSessionIds: [],
      );
    final host = await pumpListPage(tester, gateway);

    // Second workspace header menu → 移至顶部.
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移至顶部'));
    await tester.pumpAndSettle();

    expect(gateway.workspaceMoves.single.workspaceId, 'w2');
    expect(gateway.workspaceMoves.single.beforeWorkspaceId, 'w1');

    await host.close();
  });

  testWidgets('long-pressing a session can fork it into a child page',
      (tester) async {
    final gateway = FakeGateway()
      ..sessions = [
        const SessionSummary(
            sessionId: 's1', updatedAt: 1000, running: false, blank: false),
      ]
      ..forkResult = 'child-1';
    final host = await pumpListPage(tester, gateway);

    await tester.longPress(find.text('会话 s1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建副本（fork）'));
    await tester.pumpAndSettle();

    expect(gateway.forks.single.sessionId, 's1');
    // The fork child page is pushed on top (opaque route hides the parent).
    expect(find.byType(SessionPage), findsOneWidget);

    await host.close();
  });

  testWidgets('export downloads the session log via the save seam',
      (tester) async {
    final gateway = FakeGateway()..exportBytes = Uint8List.fromList([1, 2, 3]);
    String? savedName;
    Uint8List? savedBytes;
    final (mux, host) = await pumpSessionPage(
      tester,
      gateway,
      saveFile: (name, bytes) async {
        savedName = name;
        savedBytes = bytes;
        return r'C:\out.zip';
      },
    );

    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pumpAndSettle();

    expect(gateway.exports, ['s1']);
    expect(savedName, 's1.zip');
    expect(savedBytes, [1, 2, 3]);
    expect(find.textContaining('已导出'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('a failed export surfaces a snackbar instead of staying silent',
      (tester) async {
    final gateway = FakeGateway()..exportError = StateError('disk full');
    final (mux, host) = await pumpSessionPage(
      tester,
      gateway,
      saveFile: (name, bytes) async => r'C:\out.zip',
    );

    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('导出失败'), findsOneWidget);
    expect(find.textContaining('disk full'), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('goal projection renders the panel and mutations apply',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    // rc.6 real whole-value projection: the counters live OUTSIDE the inner
    // goal object; no `activation` field.
    mux.add(ServerRequest(
      rpcId: 'r',
      method: 'mux',
      payload: {
        'type': 'session/projection',
        'sessionId': 's1',
        'key': 'goal',
        'seq': 1,
        'value': {
          'goal': {
            'id': 'g1',
            'revision': 1,
            'objective': '完成 T2',
            'phase': 'active',
            'blockedReason': {'code': 'x', 'message': '受阻原因'},
            'maxGoalRounds': 5,
          },
          'roundsStarted': 2,
          'createdAt': 1000,
          'updatedAt': 2000,
        },
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.flag_outlined));
    await tester.pumpAndSettle();
    expect(find.text('完成 T2'), findsOneWidget);
    expect(find.textContaining('进行中'), findsOneWidget);
    // P1-2: counters parsed from the OUTER projection level.
    expect(find.textContaining('已运行 2 轮'), findsOneWidget);
    expect(find.textContaining('上限 5 轮'), findsOneWidget);
    expect(find.textContaining('受阻：受阻原因'), findsOneWidget);

    await tester.tap(find.text('暂停'));
    await tester.pumpAndSettle();
    expect(gateway.goalActions, ['pause']);

    await mux.close();
    await host.close();
  });

  testWidgets('no goal shows the set-goal flow with goal.create',
      (tester) async {
    final gateway = FakeGateway();
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.flag_outlined));
    await tester.pumpAndSettle();
    expect(find.text('当前未设定目标。'), findsOneWidget);

    await tester.tap(find.text('设定目标'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ).first,
      '完成 T2',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(gateway.goalActions, ['create:完成 T2']);

    await mux.close();
    await host.close();
  });

  testWidgets('subagent panel lists children and opens one', (tester) async {
    final gateway = FakeGateway()
      ..subagentEntries = const [
        SubagentEntry(
          kind: 'child',
          id: 'c1',
          mode: 'one-shot',
          activity: 'inactive',
          hasChildren: false,
          label: '子代理甲',
        ),
      ];
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.account_tree_outlined));
    await tester.pumpAndSettle();
    expect(find.text('子代理甲'), findsOneWidget);
    expect(find.textContaining('一次性'), findsOneWidget);

    await tester.tap(find.text('子代理甲'));
    await tester.pumpAndSettle();
    // The child session page is pushed on top.
    expect(find.byType(SessionPage), findsOneWidget);

    await mux.close();
    await host.close();
  });

  testWidgets('subagent panel interrupts a continuable child', (tester) async {
    final gateway = FakeGateway()
      ..subagentEntries = const [
        SubagentEntry(
          kind: 'child',
          id: 'c1',
          mode: 'continuable',
          activity: 'running',
          hasChildren: false,
        ),
      ];
    final (mux, host) = await pumpSessionPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.account_tree_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pumpAndSettle();

    expect(gateway.subagentInterrupts.single,
        (parent: 's1', child: 'c1', mode: 'continuable'));

    await mux.close();
    await host.close();
  });
}
