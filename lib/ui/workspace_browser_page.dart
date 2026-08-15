import 'package:flutter/material.dart';

import '../core/session/session_models.dart';
import '../core/session/session_repository.dart';

/// Minimal workspace-creation flow (mirrors the WebUI picker): browse host
/// directories with `host.listDirectory`, create folders with
/// `host.createDirectory`, and adopt the current directory as a Workspace
/// with `workspace.create`. Pops with `true` when a workspace was created.
class WorkspaceBrowserPage extends StatefulWidget {
  const WorkspaceBrowserPage({super.key, required this.gateway});

  final SessionGateway gateway;

  @override
  State<WorkspaceBrowserPage> createState() => _WorkspaceBrowserPageState();
}

class _WorkspaceBrowserPageState extends State<WorkspaceBrowserPage> {
  DirectoryListing? _listing;
  bool _loading = true;
  bool _creating = false;
  String? _error;
  bool _browseUnavailable = false;

  @override
  void initState() {
    super.initState();
    _open(null);
  }

  Future<void> _open(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
      _browseUnavailable = false;
    });
    try {
      final listing = await widget.gateway.listDirectory(path: path);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on SessionApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
        // The deployment serves only the native folder picker (host.pickDirectory);
        // fall back to it instead of failing the whole flow.
        _browseUnavailable = e.code == 'directory-picker-unavailable';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pickNative() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final path = await widget.gateway.pickDirectory();
      if (path == null || !mounted) return; // cancelled
      await widget.gateway.createWorkspace(path);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('采用失败：$e')));
      setState(() => _creating = false);
    }
  }

  Future<void> _createFolder() async {
    final listing = _listing;
    if (listing == null || _creating) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '文件夹名称（单层路径段）',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    setState(() => _creating = true);
    try {
      final createdPath =
          await widget.gateway.createDirectory(listing.path, trimmed);
      if (!mounted) return;
      // Enter the freshly created folder so the user can adopt it directly.
      await _open(createdPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建失败：$e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _adopt() async {
    final listing = _listing;
    if (listing == null || _creating) return;
    setState(() => _creating = true);
    try {
      await widget.gateway.createWorkspace(listing.path);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('采用失败：$e')));
      setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    return Scaffold(
      appBar: AppBar(title: const Text('添加工作区')),
      body: Column(
        children: [
          if (listing != null) _Breadcrumbs(
            crumbs: listing.crumbs,
            onSelect: (entry) => _open(entry.path),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _creating ? null : _createFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建文件夹'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed:
                    (_creating || listing == null) ? null : _adopt,
                icon: _creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('使用此目录'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      // The host serves only the native picker: offer it instead of a dead end.
      if (_browseUnavailable) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open,
                  size: 40, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 8),
              const Text('此服务仅提供系统目录选择器'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _creating ? null : _pickNative,
                icon: _creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.folder_open),
                label: const Text('选择目录'),
              ),
              TextButton(
                onPressed: _loading
                    ? null
                    : () {
                        _open(null);
                      },
                child: const Text('重试目录浏览'),
              ),
            ],
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('无法读取目录：$_error'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _open(_listing?.path),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final listing = _listing!;
    if (listing.entries.isEmpty) {
      return Center(
        child: Text(
          listing.truncated ? '目录过大，仅显示部分' : '此目录没有子文件夹',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    // The host returns only valid entries (files filtered, listing capped at
    // maxEntries with `truncated` flagging a cut level) — no sentinel row, so
    // every returned entry is shown.
    final visible = listing.entries;
    return ListView(
      children: [
        for (final entry in visible)
          ListTile(
            leading: Icon(
              Icons.folder_outlined,
              color: entry.hidden ? Colors.grey : Colors.amber,
            ),
            title: Text(entry.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(entry.path),
          ),
        if (listing.truncated)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '目录条目过多，仅显示前 1000 项',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.crumbs, required this.onSelect});

  final List<DirectoryEntry> crumbs;
  final void Function(DirectoryEntry entry) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < crumbs.length; i++) ...[
              if (i > 0)
                Icon(Icons.chevron_right,
                    size: 14, color: theme.colorScheme.outline),
              InkWell(
                onTap: () => onSelect(crumbs[i]),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    i == 0 ? crumbs[i].name : crumbs[i].name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: i == crumbs.length - 1
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.primary,
                      fontWeight: i == crumbs.length - 1
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
