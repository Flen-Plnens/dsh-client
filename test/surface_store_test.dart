import 'package:dsh_flutter/core/session/surface_store.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('SurfaceStore fold (append)', () {
    test('folds user and assistant messages in order', () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, '你好'),
        assistantMessage(1, [
          {'type': 'text', 'text': '你好！'}
        ]),
      ]);

      final messages = store.messages;
      expect(messages.length, 2);
      expect(messages[0].kind, MessageKind.user);
      expect(messages[0].text, '你好');
      expect(messages[1].kind, MessageKind.assistant);
      expect(messages[1].text, '你好！');
    });

    test('assistant message reads data.message; user message IS data', () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, '问题'),
        assistantMessage(1, [
          {'type': 'text', 'text': '答案'},
          {'type': 'reasoning', 'text': '推理过程'},
          {
            'type': 'tool-call',
            'id': 'call-1',
            'name': 'bash',
            'arguments': '{"cmd":"ls"}'
          },
        ]),
      ]);

      final assistant = store.messages[1];
      expect(assistant.text, '答案');
      expect(assistant.reasoning, '推理过程');
      expect(assistant.toolCalls.length, 1);
      expect(assistant.toolCalls.first.name, 'bash');
      expect(assistant.toolCalls.first.arguments, '{"cmd":"ls"}');
    });

    test('empty assistant message produces no message view', () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, 'hi'),
        assistantMessage(1, const []),
      ]);
      expect(store.messages.length, 1);
      expect(store.messages.single.kind, MessageKind.user);
    });

    test('tool/result derives a tool result view', () {
      final store = SurfaceStore();
      store.load([
        ev('tool/result', 0, {
          'message': {
            'id': 't0',
            'role': 'user',
            'content': [
              {
                'type': 'tool-result',
                'toolCallId': 'call-1',
                'isError': false,
                'content': [
                  {'type': 'text', 'text': 'command output'}
                ],
              }
            ],
          }
        }, surfaceOp: 'append'),
      ]);

      final result = store.messages.single;
      expect(result.kind, MessageKind.toolResult);
      expect(result.toolResultToolCallId, 'call-1');
      expect(result.text, 'command output');
      expect(result.toolIsError, isFalse);
    });

    test('image blocks render as a placeholder', () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, '看这张图'),
        assistantMessage(1, [
          {'type': 'image', 'attachment': {'attachmentId': 'img-1'}},
        ]),
      ]);
      expect(store.messages[1].text, '[图片]');
    });

    test('image blocks carry attachment refs for session.attachment', () {
      final store = SurfaceStore();
      store.load([
        assistantMessage(0, [
          {
            'type': 'image',
            'attachment': {
              'attachmentId': 'img-1',
              'mediaType': 'image/png',
              'width': 640,
              'height': 480,
            },
          },
        ]),
      ]);
      final images = store.messages.single.images;
      expect(images.length, 1);
      expect(images.single.attachmentId, 'img-1');
      expect(images.single.mediaType, 'image/png');
      expect(images.single.width, 640);
    });

    test('subagent context rows carry the sender session id', () {
      final store = SurfaceStore();
      store.load([
        ev('user/message', 0, {
          'id': 'u0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '汇报'}
          ],
          'source': {
            'kind': 'subagent-report',
            'form': 'relay',
            'senderSessionId': 'child-1',
          },
        }, surfaceOp: 'append'),
      ]);
      final message = store.messages.single;
      expect(message.kind, MessageKind.context);
      expect(message.senderSessionId, 'child-1');
      expect(message.producerLabel, 'subagent-report');
    });

    test('command/run opens a pending command row', () {
      final store = SurfaceStore();
      store.load([
        ev('command/run', 0, {
          'commandId': 'c1',
          'name': 'compact',
          'args': null,
          'source': {'kind': 'user'},
        }, surfaceOp: 'append'),
      ]);
      final message = store.messages.single;
      expect(message.kind, MessageKind.command);
      expect(message.commandId, 'c1');
      expect(message.commandName, 'compact');
      expect(message.commandArgs, isNull);
      expect(message.commandOutcome, isNull);
    });

    test('command/done pairs by id and sets the outcome', () {
      final store = SurfaceStore();
      store.load([
        ev('command/run', 0, {
          'commandId': 'c1',
          'name': 'compact',
          'source': {'kind': 'user'},
        }, surfaceOp: 'append'),
        ev('command/done', 1, {
          'commandId': 'c1',
          'kind': 'success',
        }, surfaceOp: 'append'),
      ]);
      final messages = store.messages;
      expect(messages.length, 1); // paired in place, not duplicated
      expect(messages.single.commandOutcome, 'success');
      expect(messages.single.commandName, 'compact');
    });

    test('command/done error carries its handler text', () {
      final store = SurfaceStore();
      store.load([
        ev('command/run', 0, {
          'commandId': 'c2',
          'name': 'rename',
          'args': '新标题',
          'source': {'kind': 'user'},
        }, surfaceOp: 'append'),
        ev('command/done', 1, {
          'commandId': 'c2',
          'kind': 'error',
          'text': '标题非法',
        }, surfaceOp: 'append'),
      ]);
      final message = store.messages.single;
      expect(message.commandOutcome, 'error');
      expect(message.commandOutcomeText, '标题非法');
      expect(message.commandArgs, '新标题');
    });

    test('command/done without a prior run renders a standalone row', () {
      final store = SurfaceStore();
      store.load([
        ev('command/done', 0, {
          'commandId': 'c9',
          'kind': 'success',
        }, surfaceOp: 'append'),
      ]);
      final message = store.messages.single;
      expect(message.kind, MessageKind.command);
      expect(message.commandId, 'c9');
      expect(message.commandName, isNull);
      expect(message.commandOutcome, 'success');
    });

    test('command events never finalize a streaming preview', () {
      final store = SurfaceStore();
      store.apply(userMessage(0, 'q'));
      store.apply(textDelta(1, '流式'));
      store.apply(ev('command/run', 2, {
        'commandId': 'c1',
        'name': 'compact',
        'source': {'kind': 'user'},
      }, surfaceOp: 'append'));
      expect(store.streaming, isNotNull);
      expect(store.streaming!.text, '流式');
    });
  });

  group('SurfaceStore replacement (model-only)', () {
    test('replacement copies never enter the transcript or remove history', () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, 'a'),
        assistantMessage(1, [
          {'type': 'text', 'text': 'b'}
        ]),
        assistantMessage(2, [
          {'type': 'text', 'text': 'b（压缩后）'}
        ], surfaceOp: {'op': 'replace', 'start': 0, 'end': 1}),
      ]);

      // The append-origin history stays; the replacement is model-only.
      final messages = store.messages;
      expect(messages.length, 2);
      expect(messages[0].text, 'a');
      expect(messages[1].text, 'b');
    });

    test('a replacement referencing an unloaded range is skipped without '
        'touching history', () {
      final store = SurfaceStore();
      store.load([
        // Tail page: the replace references seqs 0..1 that were never loaded.
        userMessage(10, 'x'),
        assistantMessage(11, [
          {'type': 'text', 'text': 'y'}
        ], surfaceOp: {'op': 'replace', 'start': 0, 'end': 1}),
      ]);
      // Append-origin history stays; the replacement is model-only, so no
      // fold tolerance is needed even though the shadowed range was absent.
      expect(store.messages.length, 1);
      expect(store.messages.single.text, 'x');
      expect(store.toleratedSkips, 0);
    });

    test('tool/result rewrite stays model-only; the original result is shown',
        () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, 'run it'),
        ev('tool/result', 1, {
          'message': {
            'id': 't1',
            'role': 'user',
            'content': [
              {
                'type': 'tool-result',
                'toolCallId': 'call-1',
                'isError': false,
                'content': [
                  {'type': 'text', 'text': 'original output'}
                ],
              }
            ],
          }
        }, surfaceOp: 'append'),
        // A tool/result rewrite changes only the model-visible content; the
        // human transcript keeps the original result.
        ev('tool/result', 2, {
          'message': {
            'id': 't2',
            'role': 'user',
            'content': [
              {
                'type': 'tool-result',
                'toolCallId': 'call-1',
                'isError': false,
                'content': [
                  {'type': 'text', 'text': 'rewritten output'}
                ],
              }
            ],
          }
        }, surfaceOp: {'op': 'replace', 'start': 1, 'end': 1}),
      ]);

      final results = store.messages
          .where((m) => m.kind == MessageKind.toolResult)
          .toList();
      expect(results.length, 1);
      expect(results.single.text, 'original output');
      expect(store.messages.length, 2); // user + the original tool result
    });

    test('strict mode throws on non-contiguous seqs', () {
      final store = SurfaceStore();
      expect(
        () => store.load([
          userMessage(0, 'a'),
          userMessage(2, 'gap'), // seq 1 missing
        ], strict: true),
        throwsFormatException,
      );
    });

    test('non-strict mode tolerates gaps', () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, 'a'),
        userMessage(2, 'gap'),
      ]);
      expect(store.messages.length, 2);
      expect(store.toleratedSkips, greaterThan(0));
    });
  });

  group('SurfaceStore streaming', () {
    test('chunk deltas accumulate into a streaming preview', () {
      final store = SurfaceStore();
      store.apply(userMessage(0, 'hi'));
      store.apply(textDelta(1, '你'));
      store.apply(textDelta(2, '好'));

      final streaming = store.streaming;
      expect(streaming, isNotNull);
      expect(streaming!.text, '你好');
      expect(store.messages.length, 1); // user message only
    });

    test('a surface event supersedes the streaming preview', () {
      final store = SurfaceStore();
      store.apply(textDelta(0, '流式文本'));
      expect(store.streaming!.text, '流式文本');

      store.apply(assistantMessage(1, [
        {'type': 'text', 'text': '最终文本'}
      ]));
      expect(store.streaming, isNull);
      final messages = store.messages;
      expect(messages.length, 1);
      expect(messages.single.text, '最终文本');
    });

    test('chunks from multiple blocks render in first-seen order', () {
      final store = SurfaceStore();
      store.apply(textDelta(0, 'A', index: 1));
      store.apply(textDelta(1, 'B', index: 0));
      // Official BlockAssembler renders blocks in first-seen order.
      expect(store.streaming!.text, 'AB');
    });

    test('tool-call deltas stream tool calls', () {
      final store = SurfaceStore();
      store.apply(ev('assistant/chunk', 0, {
        'chunk': {
          'type': 'tool-call-delta',
          'index': 0,
          'id': 'call-1',
          'name': 'bash',
          'argumentsDelta': '{"cmd":"'
        },
      }));
      store.apply(ev('assistant/chunk', 1, {
        'chunk': {
          'type': 'tool-call-delta',
          'index': 0,
          'id': 'call-1',
          'argumentsDelta': 'ls"}'
        },
      }));
      final calls = store.streaming!.toolCalls;
      expect(calls.length, 1);
      expect(calls.single.name, 'bash');
      expect(calls.single.arguments, '{"cmd":"ls"}');
    });
  });

  group('SurfaceStore message classification', () {
    test('user/message with source.kind "user" renders as a user bubble', () {
      final store = SurfaceStore();
      store.load([userMessage(0, '你好')]);
      expect(store.messages.single.kind, MessageKind.user);
      expect(store.messages.single.sourceKind, 'user');
    });

    test('user/message with plugin source renders as context, not user',
        () {
      final store = SurfaceStore();
      store.load([
        ev('user/message', 0, {
          'id': 'u0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'background job pwsh-1 finished'}
          ],
          'source': {'kind': 'plugin', 'plugin': 'tool-jobs', 'form': 'notice'},
        }, surfaceOp: 'append'),
      ]);
      final message = store.messages.single;
      expect(message.kind, MessageKind.context);
      expect(message.text, 'background job pwsh-1 finished');
      expect(message.sourceKind, 'plugin');
      expect(message.producerLabel, 'tool-jobs');
    });

    test('subagent-report source renders as context with kind label', () {
      final store = SurfaceStore();
      store.load([
        ev('user/message', 0, {
          'id': 'u0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'subagent reported'}
          ],
          'source': {
            'kind': 'subagent-report',
            'form': 'relay',
            'senderSessionId': 'child-1',
          },
        }, surfaceOp: 'append'),
      ]);
      final message = store.messages.single;
      expect(message.kind, MessageKind.context);
      // Unknown kinds degrade to the kind itself (merge-extensible wire).
      expect(message.producerLabel, 'subagent-report');
    });

    test('unknown source kinds degrade to context, never user', () {
      final store = SurfaceStore();
      store.load([
        ev('user/message', 0, {
          'id': 'u0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'something'}
          ],
          'source': {'kind': 'future-source-kind'},
        }, surfaceOp: 'append'),
      ]);
      expect(store.messages.single.kind, MessageKind.context);
    });

    test('compaction checkpoint is model-only and never removes history', () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, 'a'),
        assistantMessage(1, [
          {'type': 'text', 'text': 'b'}
        ]),
        // Compaction replaces the turn with a plugin "compact" user/message.
        ev('user/message', 2, {
          'id': 'c0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'previous conversation summarized'}
          ],
          'source': {'kind': 'plugin', 'plugin': 'compact'},
        }, surfaceOp: {'op': 'replace', 'start': 0, 'end': 1}),
      ]);
      // The compacted history stays visible; the checkpoint itself is skipped.
      final messages = store.messages;
      expect(messages.length, 2);
      expect(messages[0].text, 'a');
      expect(messages[1].text, 'b');
    });

    test('context messages keep node order alongside user messages', () {
      final store = SurfaceStore();
      store.load([
        ev('user/message', 0, {
          'id': 'c0',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'notice'}
          ],
          'source': {'kind': 'plugin', 'plugin': 'tool-jobs'},
        }, surfaceOp: 'append'),
        userMessage(1, 'hello'),
      ]);
      final messages = store.messages;
      expect(messages.length, 2);
      expect(messages[0].kind, MessageKind.context);
      expect(messages[1].kind, MessageKind.user);
    });
  });

  group('SurfaceStore streaming finalization', () {
    test('turn/end finalizes a partial preview into a message', () {
      final store = SurfaceStore();
      store.apply(userMessage(0, 'hi'));
      store.apply(textDelta(1, '部分'));
      store.apply(textDelta(2, '输出'));
      expect(store.streaming!.text, '部分输出');

      store.apply(ev('turn/end', 3, {'turn': 1, 'reason': {'kind': 'cancelled'}}));
      expect(store.streaming, isNull);
      final messages = store.messages;
      expect(messages.length, 2);
      final partial = messages[1];
      expect(partial.kind, MessageKind.assistant);
      expect(partial.text, '部分输出');
      expect(partial.complete, isFalse);
    });

    test('turn/end with empty streaming leaves nothing behind', () {
      final store = SurfaceStore();
      store.apply(userMessage(0, 'hi'));
      store.apply(ev('turn/end', 1, {'turn': 1, 'reason': {'kind': 'completed'}}));
      expect(store.streaming, isNull);
      expect(store.partials, isEmpty);
      expect(store.messages.length, 1);
    });

    test('assistant/message supersedes the preview without a partial', () {
      final store = SurfaceStore();
      store.apply(userMessage(0, 'hi'));
      store.apply(textDelta(1, '流式'));
      store.apply(assistantMessage(2, [
        {'type': 'text', 'text': '最终'}
      ]));
      expect(store.streaming, isNull);
      expect(store.partials, isEmpty);
      expect(store.messages.last.text, '最终');
    });

    test('a user message mid-stream finalizes the partial first', () {
      final store = SurfaceStore();
      store.apply(userMessage(0, 'q1'));
      store.apply(textDelta(1, '答了一半'));
      store.apply(userMessage(2, 'q2'));
      final kinds = store.messages.map((m) => m.kind).toList();
      expect(kinds, [MessageKind.user, MessageKind.assistant, MessageKind.user]);
      expect(store.messages[1].text, '答了一半');
      expect(store.messages[1].complete, isFalse);
    });

    test('load of a running turn keeps the preview streaming', () {
      final store = SurfaceStore();
      // History snapshot taken mid-turn: chunks without a final message.
      store.load([
        userMessage(0, 'hi'),
        textDelta(1, '还在'),
        textDelta(2, '生成'),
      ]);
      expect(store.streaming, isNotNull);
      expect(store.streaming!.text, '还在生成');
      // The live final message then supersedes it.
      store.apply(assistantMessage(3, [
        {'type': 'text', 'text': '完成了'}
      ]));
      expect(store.streaming, isNull);
      expect(store.messages.last.text, '完成了');
    });

    test('load of an interrupted turn (turn/end in log) finalizes the partial',
        () {
      final store = SurfaceStore();
      store.load([
        userMessage(0, 'hi'),
        textDelta(1, '部分'),
        ev('turn/end', 2, {'turn': 1, 'reason': {'kind': 'interrupted'}}),
      ]);
      expect(store.streaming, isNull);
      expect(store.partials.length, 1);
      expect(store.partials.single.text, '部分');
    });
  });

  group('SurfaceStore incremental apply', () {
    test('stale (already-seen) seqs are ignored', () {
      final store = SurfaceStore();
      store.apply(userMessage(0, 'a'));
      store.apply(userMessage(0, 'dup'));
      expect(store.messages.length, 1);
      expect(store.log.length, 1);
    });

    test('listeners fire on load and apply', () {
      final store = SurfaceStore();
      var notified = 0;
      store.addListener(() => notified++);
      store.load([userMessage(0, 'a')]);
      expect(notified, 1);
      store.apply(userMessage(1, 'b'));
      expect(notified, 2);
    });

    test('isEmpty reflects nodes, partials and streaming', () {
      final store = SurfaceStore();
      expect(store.isEmpty, isTrue);
      store.apply(textDelta(0, 'x'));
      expect(store.isEmpty, isFalse);
      store.apply(ev('turn/end', 1, {'turn': 1, 'reason': {'kind': 'x'}}));
      expect(store.isEmpty, isFalse); // partial keeps content
    });
  });
}
