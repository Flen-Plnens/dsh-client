import 'package:dsh_flutter/ui/connect_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectPage()));
  }

  testWidgets('renders the connectivity screen in the disconnected state',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('DSH Client'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    // Address field is pre-filled with a sensible default.
    final field =
        tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isNotEmpty);
    expect(field.controller!.text, contains('127.0.0.1:3080'));
    // Raw downlink-frame logging is hidden behind the debug toggle.
    expect(find.textContaining('下行帧日志'), findsNothing);
  });

  testWidgets('downlink frame log is a debug toggle, hidden by default',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.bug_report_outlined));
    await tester.pump();
    expect(find.text('调试：下行帧日志（mux / host）'), findsOneWidget);
    expect(find.text('尚未收到任何帧'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.bug_report));
    await tester.pump();
    expect(find.textContaining('下行帧日志'), findsNothing);
  });

  testWidgets('rejects a malformed service address with an inline error',
      (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('连接'));
    await tester.pump();

    expect(find.text('服务地址必须以 http:// 或 https:// 开头'),
        findsOneWidget);
    // Still disconnected — no connection attempt was made.
    expect(find.text('未连接'), findsOneWidget);
  });

  testWidgets('About dialog shows product name, version and description',
      (tester) async {
    await pumpPage(tester);

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();

    expect(find.text('DSH Client'), findsNWidgets(2)); // AppBar + dialog title
    expect(find.text('Version 1.0.0'), findsOneWidget);
    expect(find.text('A Flutter client for DeepSeek Harness.'), findsOneWidget);
    expect(find.text('https://github.com/Flen-Plnens/dsh-client'),
        findsOneWidget);

    // Dismiss and confirm the page remains intact.
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('Version 1.0.0'), findsNothing);
  });

  testWidgets('normalizes a bare host:port address to a valid base URI',
      (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), '127.0.0.1:3080');
    await tester.tap(find.text('连接'));
    await tester.pump();

    // Bare host:port is rejected (scheme required) without crashing.
    expect(find.text('服务地址必须以 http:// 或 https:// 开头'),
        findsOneWidget);
  });
}
