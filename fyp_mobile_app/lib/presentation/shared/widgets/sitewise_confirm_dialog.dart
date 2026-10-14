import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Confirmation dialog for destructive actions (reject, delete…).

Future<bool> showSitewiseConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: destructive
              ? ElevatedButton.styleFrom(backgroundColor: SitewiseColors.danger)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
