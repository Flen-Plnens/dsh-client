import 'package:flutter/material.dart';

/// Application identity. Keep [kAppVersion] in sync with `pubspec.yaml`
/// (this release: 1.0.0).
const String kAppName = 'DSH Client';
const String kAppVersion = '1.0.0';
const String kAppDescription = 'A Flutter client for DeepSeek Harness.';
const String kAppRepository = 'https://github.com/Flen-Plnens/dsh-client';

/// Opens the About dialog for DSH Client.
Future<void> showDshAboutDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _AboutDialogContent(),
  );
}

class _AboutDialogContent extends StatelessWidget {
  const _AboutDialogContent();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.chat_bubble_outline, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          const Text(kAppName),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Version $kAppVersion'),
          const SizedBox(height: 8),
          const Text(kAppDescription),
          const SizedBox(height: 12),
          const Text('项目仓库 / Repository:'),
          const SizedBox(height: 4),
          SelectableText(
            kAppRepository,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
