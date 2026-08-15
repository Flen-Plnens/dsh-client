import 'dart:async';

import 'package:flutter/material.dart';

import '../core/connection/connection_controller.dart';
import '../core/rpc/rpc_envelope.dart';
import '../core/session/session_models.dart';
import '../core/session/session_repository.dart';
import 'session_page.dart';
import 'workspace_browser_page.dart';

/// Workspace/session browsing. Loads `workspace.list` + `session.list`,
/// keeps the list fresh from host frames, and opens [SessionPage]s.
class SessionListPage extends StatefulWidget {
  const SessionListPage({
    super.key,
    required this.gateway,
    required this.muxFrames,
    required this.hostFrames,
    this.connection,
  });

  final SessionGateway gateway;
  final Stream<ServerRequest> muxFrames;
  final Stream<ServerRequest> hostFrames;

  /// The live connection controller, forwarded to opened sessions (reconnect
  /// banner).
  final ConnectionController? connection;

  @override
  State<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends State<SessionListPage> {
  List<WorkspaceView> _workspaces = const [];
  List<SessionSummary> _sessions = const [];
  final Map<String, String> _titles = {};
  final Map<String, int> _titleSeqs = {};
  Set<String> _archived = const {};
  String? _currentSessionId;
  bool _loading = true;
  String? _error;
  StreamSubscription<ServerRequest>? _hostSub;
  StreamSubscription<ServerRequest>? _muxSub;
  Timer? _debounce;
  bool _creating = false;

  // M4 session search (local metadata + host content search).
  final TextEditingController _searchController = TextEditingController();
  final List<({String sessionId, String snippet})> _searchResults = [];
  bool _searchExpanded = false;
  bool _searching = false;
  String? _searchError;
  bool _searchHasMore = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Host frames announce membership/running changes; refresh (debounced).
    _hostSub = widget.hostFrames.listen((frame) {
      switch (frame.frameType) {
        case 'host/session-added':
        case 'host/session-removed':
        case 'host/session-status':
        case 'host/workspace-changed':
        case 'host/workspace-removed':
        case 'host/workspace-order-changed':
        case 'host/archived-sessions-changed':
          final archived = frame.payloadMap?['archivedSessionIds'];
          if (archived is List && mounted) {
            setState(() =>
                _archived = archived.whereType<String>().toSet());
          }
          _scheduleRefresh();
      }
    });
    // Session title projections (key == 'title') enrich list rows; a stale
    // frame never overwrites a newer one (higher-seq-wins).
    _muxSub = widget.muxFrames.listen((frame) {
      if (frame.frameType != 'session/projection') return;
      final payload = frame.payloadMap;
      if (payload == null || payload['key'] != 'title') return;
      final sessionId = payload['sessionId'];
      final value = payload['value'];
      final seq = (payload['seq'] as num?)?.toInt() ?? -1;
      if (sessionId is! String || value is! String || value.isEmpty) return;
      final known = _titleSeqs[sessionId];
      if (known != null && seq <= known) return;
      if (!mounted) return;
      setState(() {
        _titleSeqs[sessionId] = seq;
        _titles[sessionId] = value;
      });
    });
  }

  @override
  void dispose() {
    _hostSub?.cancel();
    _muxSub?.cancel();
    _debounce?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Official `session.search` wire bound: strip NUL, cap 500 UTF-16 units.
  static String _sanitizeQuery(String value) {
    final withoutNul = value.replaceAll('\u0000', '');
    return withoutNul.length <= 500 ? withoutNul : withoutNul.substring(0, 500);
  }

  void _onSearchChanged(String raw) {
    final query = _sanitizeQuery(raw).trim();
    _searchDebounce?.cancel();
    setState(() => _searchError = null);
    if (query.isEmpty) {
      setState(() {
        _searching = false;
        _searchResults.clear();
        _searchHasMore = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      _runSearch(query);
    });
  }

  Future<void> _runSearch(String query) async {
    // Local title/metadata matches first (name matching is instant).
    final local = <String, String>{};
    for (final session in _displaySessions) {
      final title = _titles[session.sessionId] ??
          session.title ??
          _SessionTile._basename(session.cwd);
      if (title.toLowerCase().contains(query.toLowerCase()) ||
          session.sessionId.contains(query)) {
        local[session.sessionId] = '';
      }
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final page = await widget.gateway.sessionSearch(query);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchResults
          ..clear()
          ..addAll([
            // Host-ranked content matches (with snippet).
            for (final item in page.items) (sessionId: item.sessionId, snippet: item.snippet),
            // Local-only title matches not already surfaced by content search.
            for (final entry in local.entries)
              if (!page.items.any((i) => i.sessionId == entry.key))
                (sessionId: entry.key, snippet: ''),
          ]);
        _searchHasMore = page.hasMore;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = e.toString();
        // Content search failed: fall back to name matches only.
        _searchResults
          ..clear()
          ..addAll([
            for (final entry in local.entries)
              (sessionId: entry.key, snippet: ''),
          ]);
        _searchHasMore = false;
      });
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchExpanded = !_searchExpanded;
      if (!_searchExpanded) {
        _searchController.clear();
        _searchResults.clear();
        _searchError = null;
        _searching = false;
        _searchHasMore = false;
        _searchDebounce?.cancel();
      }
    });
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _refresh);
  }

  Future<void> _refresh() async {
    try {
      final results = await Future.wait([
        widget.gateway.listSessions(),
        widget.gateway.listWorkspaces(),
      ]);
      if (!mounted) return;
      setState(() {
        _sessions = results[0] as List<SessionSummary>;
        final workspaces = (results[1] as WorkspaceListResult);
        _workspaces = workspaces.items;
        _archived = workspaces.archivedSessionIds.toSet();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _newSession() async {
    // Distinguish "dismissed" (null) from "default directory" (''): with no
    // workspaces there is no sheet at all, and the session must still be
    // created in the host default directory.
    String? workspaceId;
    var proceed = true;
    if (_workspaces.isNotEmpty) {
      workspaceId = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                leading: Icon(Icons.create_new_folder_outlined),
                title: Text('创建新会话'),
                subtitle: Text('选择一个工作区'),
              ),
              for (final workspace in _workspaces)
                ListTile(
                  title: Text(workspace.title),
                  subtitle: Text(workspace.path),
                  onTap: () => Navigator.pop(context, workspace.workspaceId),
                ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('默认目录'),
                subtitle: const Text('不关联工作区'),
                onTap: () => Navigator.pop(context, ''),
              ),
            ],
          ),
        ),
      );
      if (workspaceId == null) return; // dismissed
      if (workspaceId.isEmpty) workspaceId = null; // default directory
    }
    if (!proceed || !mounted) return;
    setState(() => _creating = true);
    try {
      final sessionId = await widget.gateway.createSession(workspaceId: workspaceId);
      if (!mounted) return;
      await _openSession(sessionId, title: '新会话');
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建失败：$e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _openSession(String sessionId, {String? title}) {
    final summary = _byId(sessionId);
    // The currently viewed session stays visible even when blank (official
    // sessionVisible: `!session.blank || session.id === current`).
    _currentSessionId = sessionId;
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(
          gateway: widget.gateway,
          muxFrames: widget.muxFrames,
          hostFrames: widget.hostFrames,
          sessionId: sessionId,
          title: title ?? _titles[sessionId],
          initialRunning: summary?.running ?? false,
          connection: widget.connection,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_searchExpanded ? '搜索会话' : '会话列表'),
        actions: [
          IconButton(
            tooltip: _searchExpanded ? '关闭搜索' : '搜索会话',
            icon: Icon(_searchExpanded ? Icons.close : Icons.search),
            onPressed: _toggleSearch,
          ),
          IconButton(
            tooltip: '添加工作区',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _addWorkspace,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _creating ? null : _newSession,
        icon: _creating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_creating ? '创建中…' : '新会话'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          hintText: '搜索会话…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searching
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    final Widget body;
    if (_searchResults.isEmpty && !_searching) {
      final query = _searchController.text.trim();
      body = Center(
        child: Text(
          query.isEmpty
              ? '输入关键字搜索会话…'
              : (_searchError != null ? '内容搜索暂不可用，仅显示名称匹配。' : '无匹配会话'),
        ),
      );
    } else {
      body = ListView(
        children: [
          if (_searchError != null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('内容搜索暂不可用，仅显示名称匹配。',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          for (final result in _searchResults) _buildSearchRow(result),
          if (_searchHasMore)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: Text('仅显示前 20 条结果，请缩小搜索范围。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchField(),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildSearchRow(({String sessionId, String snippet}) result) {
    final session = _byId(result.sessionId);
    final title =
        (_titles[result.sessionId] ??
                session?.title ??
                _SessionTile._basename(session?.cwd))
            .trim();
    final workspace = _workspaces
        .where((w) => w.sessionIds.contains(result.sessionId))
        .firstOrNull;
    return ListTile(
      leading: const Icon(Icons.search, size: 18),
      title: Text(
        title.isNotEmpty ? title : '会话 ${result.sessionId}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (result.snippet.isNotEmpty) result.snippet,
          if (workspace != null) workspace.title,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _openSession(result.sessionId),
    );
  }

  Future<void> _renameWorkspace(WorkspaceView workspace) async {
    final controller = TextEditingController(text: workspace.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名工作区'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '工作区标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    try {
      await widget.gateway.renameWorkspace(workspace.workspaceId, trimmed);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
  }

  Future<void> _deleteWorkspace(WorkspaceView workspace) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除工作区'),
        content: Text(
            '删除「${workspace.title}」的注册？目录与会话日志保留，会话将变为未分组。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.gateway.deleteWorkspace(workspace.workspaceId);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  Future<void> _archiveSession(SessionSummary session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('归档会话'),
        content: const Text('归档后会话从列表隐藏，日志保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.gateway.archiveSession(session.sessionId);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('归档失败：$e')));
    }
  }

  /// Long-press sheet: session reorder (workspace.insertSessionBefore) and
  /// archive. Anchor omitted appends to the end; passing the first sibling
  /// moves the session to the top.
  Future<void> _sessionActions(SessionSummary session) async {
    final workspace = _workspaces
        .where((w) => w.sessionIds.contains(session.sessionId))
        .firstOrNull;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                _titles[session.sessionId] ??
                    session.title ??
                    _SessionTile._basename(session.cwd),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (workspace != null) ...[
              ListTile(
                leading: const Icon(Icons.vertical_align_top),
                title: const Text('移至顶部'),
                onTap: () => Navigator.pop(context, 'top'),
              ),
              ListTile(
                leading: const Icon(Icons.vertical_align_bottom),
                title: const Text('移至底部'),
                onTap: () => Navigator.pop(context, 'bottom'),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('创建副本（fork）'),
              onTap: () => Navigator.pop(context, 'fork'),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('归档'),
              onTap: () => Navigator.pop(context, 'archive'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'top':
        final members = _workspaceMembers(workspace!);
        await _moveSession(
            workspace, session.sessionId,
            beforeSessionId: members.length > 1 ? members.first.sessionId : null);
      case 'bottom':
        await _moveSession(workspace!, session.sessionId);
      case 'fork':
        await _forkSession(session);
      case 'archive':
        await _archiveSession(session);
    }
  }

  /// Fork the session (session.fork): the child keeps `parentSessionId` but
  /// has no `origin`, so it stays visible as a top-level session.
  Future<void> _forkSession(SessionSummary session) async {
    try {
      final childId = await widget.gateway.forkSession(session.sessionId);
      if (!mounted) return;
      _refresh();
      await _openSession(childId, title: '副本');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建副本失败：$e')));
    }
  }

  Future<void> _moveSession(
    WorkspaceView workspace,
    String sessionId, {
    String? beforeSessionId,
  }) async {
    try {
      await widget.gateway
          .insertSessionBefore(workspace.workspaceId, sessionId,
              beforeSessionId: beforeSessionId);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('移动失败：$e')));
    }
  }

  /// Workspace reorder (workspace.insertBefore). Anchor omitted appends to the
  /// end; passing the first workspace moves this one to the top.
  Future<void> _moveWorkspace(WorkspaceView workspace, {required bool top}) async {
    if (_workspaces.length < 2) return;
    final anchor = top ? _workspaces.first.workspaceId : null;
    if (!top && _workspaces.last.workspaceId == workspace.workspaceId) return;
    if (top && _workspaces.first.workspaceId == workspace.workspaceId) return;
    try {
      final order = await widget.gateway.insertWorkspaceBefore(
        workspace.workspaceId,
        beforeWorkspaceId: anchor,
      );
      if (!mounted) return;
      if (order.isNotEmpty) {
        setState(() {
          final byId = {for (final w in _workspaces) w.workspaceId: w};
          _workspaces = [
            for (final id in order)
              if (byId[id] != null) byId[id]!,
          ];
        });
      }
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('移动失败：$e')));
    }
  }

  Future<void> _addWorkspace() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => WorkspaceBrowserPage(gateway: widget.gateway),
      ),
    );
    if (created == true) {
      // A workspace was adopted; the host also pushes host/workspace-changed,
      // but refreshing here keeps the list correct immediately.
      _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('工作区已添加')),
        );
      }
    }
  }

  Widget _buildBody() {
    if (_searchExpanded) return _buildSearchResults();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：$_error'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _refresh, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_displaySessions.isEmpty && _workspaces.isEmpty) {
      return const Center(child: Text('暂无会话，点击「新会话」开始'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        children: [
          for (final workspace in _workspaces) ...[
            _SectionHeader(
              title: workspace.title,
              subtitle: workspace.path,
              onRename: () => _renameWorkspace(workspace),
              onDelete: () => _deleteWorkspace(workspace),
              onMoveTop: () => _moveWorkspace(workspace, top: true),
              onMoveBottom: () => _moveWorkspace(workspace, top: false),
            ),
            for (final session in _workspaceMembers(workspace))
              _SessionTile(
                session: session,
                title: _titles[session.sessionId],
                onTap: () => _openSession(session.sessionId),
                onLongPress: () => _sessionActions(session),
              ),
          ],
          if (_ungrouped.isNotEmpty) ...[
            const _SectionHeader(title: '未分组'),
            for (final session in _ungrouped)
              _SessionTile(
                session: session,
                title: _titles[session.sessionId],
                onTap: () => _openSession(session.sessionId),
                onLongPress: () => _sessionActions(session),
              ),
          ],
        ],
      ),
    );
  }

  /// Official `sessionVisible`: subagent children are never top-level rows
  /// (`origin == "subagent"`), archived sessions are hidden everywhere, and a
  /// blank session is visible only while it is the currently viewed session.
  /// A fork child carries `parentSessionId` but no `origin` and stays visible.
  bool _visible(SessionSummary s) =>
      s.origin != 'subagent' &&
      !_archived.contains(s.sessionId) &&
      (!s.blank || s.sessionId == _currentSessionId);

  /// Top-level visible sessions, newest first (official `byRecency`).
  List<SessionSummary> get _displaySessions {
    final sessions = _sessions.where(_visible).toList();
    sessions.sort(byRecency);
    return sessions;
  }

  static int byRecency(SessionSummary a, SessionSummary b) {
    if (b.updatedAt != a.updatedAt) return b.updatedAt.compareTo(a.updatedAt);
    return a.sessionId.compareTo(b.sessionId);
  }

  List<SessionSummary> _workspaceMembers(WorkspaceView workspace) {
    final members = workspace.sessionIds
        .map(_byId)
        .whereType<SessionSummary>()
        .where(_visible)
        .toList()
      ..sort(byRecency);
    return members;
  }

  List<SessionSummary> get _ungrouped => _displaySessions
      .where((s) => !_inAnyWorkspace(s.sessionId))
      .toList();

  SessionSummary? _byId(String id) {
    for (final session in _sessions) {
      if (session.sessionId == id) return session;
    }
    return null;
  }

  bool _inAnyWorkspace(String id) =>
      _workspaces.any((w) => w.sessionIds.contains(id));
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.subtitle,
    this.onRename,
    this.onDelete,
    this.onMoveTop,
    this.onMoveBottom,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onMoveTop;
  final VoidCallback? onMoveBottom;

  @override
  Widget build(BuildContext context) {
    final hasMenu = onRename != null ||
        onDelete != null ||
        onMoveTop != null ||
        onMoveBottom != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(subtitle!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey)),
              ],
            ),
          ),
          if (hasMenu)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (value) {
                if (value == 'rename') onRename?.call();
                if (value == 'delete') onDelete?.call();
                if (value == 'move-top') onMoveTop?.call();
                if (value == 'move-bottom') onMoveBottom?.call();
              },
              itemBuilder: (context) => [
                if (onMoveTop != null)
                  const PopupMenuItem(
                    value: 'move-top',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.vertical_align_top, size: 18),
                      title: Text('移至顶部'),
                    ),
                  ),
                if (onMoveBottom != null)
                  const PopupMenuItem(
                    value: 'move-bottom',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.vertical_align_bottom, size: 18),
                      title: Text('移至底部'),
                    ),
                  ),
                if (onRename != null)
                  const PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.edit_outlined, size: 18),
                      title: Text('重命名'),
                    ),
                  ),
                if (onDelete != null)
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.delete_outline, size: 18),
                      title: Text('删除'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    this.title,
    required this.onTap,
    this.onLongPress,
  });

  final SessionSummary session;
  final String? title;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static String _basename(String? cwd) {
    if (cwd == null || cwd.isEmpty) return '';
    final cleaned = cwd.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final idx = cleaned.lastIndexOf('/');
    return idx == -1 ? cleaned : cleaned.substring(idx + 1);
  }

  @override
  Widget build(BuildContext context) {
    // Title precedence: live projection frame (title param) → the row's own
    // title projection from session.list → cwd basename → short id. The
    // workspace title is never used for session rows.
    final liveTitle = title;
    final base = _basename(session.cwd);
    final sessionTitle = session.title;
    final displayTitle = (liveTitle != null && liveTitle.isNotEmpty)
        ? liveTitle
        : (sessionTitle != null && sessionTitle.isNotEmpty)
            ? sessionTitle
            : (base.isNotEmpty
                ? base
                : '会话 ${session.sessionId.length > 8 ? session.sessionId.substring(0, 8) : session.sessionId}');
    final time = session.updatedAt == 0
        ? ''
        : _formatTime(session.updatedAt);
    final running = session.running;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: running
            ? Colors.green.withValues(alpha: 0.2)
            : Colors.deepPurple.withValues(alpha: 0.15),
        child: Icon(
          running ? Icons.play_arrow : Icons.chat_bubble_outline,
          size: 18,
          color: running ? Colors.green : Colors.deepPurple,
        ),
      ),
      title: Text(displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (running) '运行中',
          if (session.blank) '空白',
          if (time.isNotEmpty) time,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  static String _formatTime(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
