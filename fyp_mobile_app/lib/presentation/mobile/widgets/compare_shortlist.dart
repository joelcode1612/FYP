import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../shell/entrepreneur_tab_scope.dart';

/// One tap on a list card's Compare control, shared by every screen that
/// offers it (Recommendations, Explore, Favourites).
///
/// A tap on an already-selected property removes it; a tap on a new one adds
/// it. The shortlist is capped, and the controller refuses an add beyond the
/// cap WITHOUT mutating the selection — so the refusal is stated here instead
/// of being a silently ignored tap, and a successful add carries the way into
/// the comparison itself.
void toggleComparedWithFeedback(
  WidgetRef ref,
  BuildContext context,
  String id,
) {
  final notifier = ref.read(appNotifierProvider.notifier);
  final alreadySelected = ref.read(appNotifierProvider).compared.contains(id);
  final String message;
  if (alreadySelected) {
    notifier.toggleCompared(id);
    message = 'Removed from comparison.';
  } else if (notifier.addCompared(id)) {
    final count = ref.read(appNotifierProvider).compared.length;
    message =
        'Added to comparison ($count of ${AppState.maxCompare} selected).';
  } else {
    message =
        'You can compare up to ${AppState.maxCompare} properties. '
        'Remove one first.';
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      action: alreadySelected
          ? null
          : SnackBarAction(
              label: 'View comparison',
              onPressed: () =>
                  EntrepreneurTabScope.open(context, '/entrepreneur/compare'),
            ),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
