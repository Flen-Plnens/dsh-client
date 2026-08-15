import 'dart:async';

import 'package:dsh_flutter/core/rpc/rpc_envelope.dart';
import 'package:dsh_flutter/core/session/session_models.dart';
import 'package:dsh_flutter/core/session/session_repository.dart';
import 'package:dsh_flutter/ui/session_list_page.dart';
import 'package:dsh_flutter/ui/workspace_browser_page.dart';
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
  return host;
}

const _home = DirectoryEntry(
    name: 'home', path: r'C:\home', hidden: false);
const _proj = DirectoryEntry(
    name: 'proj', path: r'C:\home\proj', hidden: false);

void main() {
  testWidgets('browser lists home, navigates folders and creates one',
      (tester) async {    final gateway = FakeGateway()
      ..directories[''] = const DirectoryListing(
        path: r'C:\home',
        home: r'C:\home',
        crumbs: [_home],
        entries: [_proj],
        truncated: false,
      )
      ..directories[r'C:\home\proj'] = const DirectoryListing(
        path: r'C:\home\proj',
        home: r'C:\home',
        crumbs: [_home, _proj],
        entries: [],
        truncated: false,
      );
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceBrowserPage(gateway: gateway),
    ));
    await tester.pumpAndSettle();

    // Home level lists the folder; crumbs show the home anchor.
    expect(find.text('proj'), findsOneWidget);
    expect(find.text('home'), findsOneWidget);

    // Enter the folder.
    await tester.tap(find.text('proj'));
    await tester.pumpAndSettle();
    expect(find.text('此目录没有子文件夹'), findsOneWidget);

    // Create a folder inside it.
    await tester.tap(find.text('新建文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sub');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(gateway.lastCreateDirectoryParent, r'C:\home\proj');
    expect(gateway.lastCreateDirectoryName, 'sub');
    expect(gateway.createdDirectories, [r'C:\home\proj\sub']);
    // The browser navigated into the freshly created folder.
    expect(find.text('此目录没有子文件夹'), findsOneWidget);
  });

  testWidgets('browser adopts the current directory as a workspace and pops',
      (tester) async {
    final gateway = FakeGateway()
      ..directories[''] = const DirectoryListing(
        path: r'C:\home',
        home: r'C:\home',
        crumbs: [_home],
        entries: [_proj],
        truncated: false,
      );
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceBrowserPage(gateway: gateway),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('使用此目录'));
    await tester.pumpAndSettle();

    expect(gateway.adoptedWorkspaces, [r'C:\home']);
    // Page popped (its own route is gone when pushed standalone the widget
    // is the root; here we assert the create result was produced).
    expect(gateway.workspaces.items.single.title, 'home');
  });

  testWidgets('browser surfaces a directory read error with retry',
      (tester) async {
    final gateway = FakeGateway()
      ..directoryError = StateError('directory-unreadable');
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceBrowserPage(gateway: gateway),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法读取目录'), findsOneWidget);

    // Heal and retry.
    gateway.directoryError = null;
    gateway.directories[''] = const DirectoryListing(
      path: r'C:\home',
      home: r'C:\home',
      crumbs: [_home],
      entries: [_proj],
      truncated: false,
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('proj'), findsOneWidget);
  });

  testWidgets('add-workspace entry adopts a directory and refreshes the list',
      (tester) async {
    final gateway = FakeGateway()
      ..directories[''] = const DirectoryListing(
        path: r'C:\home',
        home: r'C:\home',
        crumbs: [_home],
        entries: [_proj],
        truncated: false,
      );
    final host = await pumpListPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await tester.pumpAndSettle();

    // The browser is open; adopt the home directory.
    await tester.tap(find.text('使用此目录'));
    await tester.pumpAndSettle();

    expect(gateway.adoptedWorkspaces, [r'C:\home']);
    // Back on the list, refreshed: the new workspace shows as a section.
    expect(find.text('home'), findsWidgets);
    expect(find.byType(WorkspaceBrowserPage), findsNothing);

    await host.close();
  });

  testWidgets('falls back to the native picker when browse is unavailable',
      (tester) async {
    final gateway = FakeGateway()
      ..directoryError = SessionApiException(
        'host.listDirectory needs the browse capability; '
            'the composed picker serves "native"',
        code: 'directory-picker-unavailable',
      )
      ..pickDirectoryResult = r'C:\home\picked';
    final host = await pumpListPage(tester, gateway);

    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await tester.pumpAndSettle();

    // The browse fallback surface is shown, not a dead-end error.
    expect(find.text('此服务仅提供系统目录选择器'), findsOneWidget);
    expect(find.text('无法读取目录'), findsNothing);

    await tester.tap(find.text('选择目录'));
    await tester.pumpAndSettle();

    expect(gateway.pickDirectoryCalls, 1);
    expect(gateway.adoptedWorkspaces, [r'C:\home\picked']);
    // Popped back to the list; the adopted workspace section is visible.
    expect(find.byType(WorkspaceBrowserPage), findsNothing);
    expect(find.text('picked'), findsWidgets);

    await host.close();
  });

  testWidgets('truncated listings show every returned entry plus the notice',
      (tester) async {
    final gateway = FakeGateway()
      ..directories[''] = const DirectoryListing(
        path: r'C:\home',
        home: r'C:\home',
        crumbs: [_home],
        // The host caps at maxEntries and flags the cut; the returned rows
        // are all valid entries — no sentinel row to drop.
        entries: [
          DirectoryEntry(name: 'a', path: r'C:\home\a', hidden: false),
          DirectoryEntry(name: 'b', path: r'C:\home\b', hidden: false),
          DirectoryEntry(name: 'c', path: r'C:\home\c', hidden: false),
        ],
        truncated: true,
      );
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceBrowserPage(gateway: gateway),
    ));
    await tester.pumpAndSettle();

    // All three returned entries are shown (none dropped for the flag).
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
    expect(find.text('目录条目过多，仅显示前 1000 项'), findsOneWidget);
  });
}
