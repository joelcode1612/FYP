import 'package:flutter/material.dart';

/// Presentation-only CQ design tokens. No questionnaire rules or decisions
/// are defined here: wording, options, routing and authorization come from API.
abstract final class CqUiColors {
  static const navy = Color(0xFF102B57);
  static const blue = Color(0xFF1356DD);
  static const blueSoft = Color(0xFFEAF2FF);
  static const ink = Color(0xFF152744);
  static const secondary = Color(0xFF53657C);
  static const outline = Color(0xFFD9E3F0);
  static const page = Color(0xFFF4F8FE);
  static const success = Color(0xFF137C55);
  static const successSoft = Color(0xFFE8F7EF);
  static const warning = Color(0xFF976000);
  static const warningSoft = Color(0xFFFFF4DA);
  static const danger = Color(0xFFAD3443);
  static const dangerSoft = Color(0xFFFFEEF1);
}

class CqPageFrame extends StatelessWidget {
  const CqPageFrame({
    super.key,
    required this.children,
    this.controller,
    this.onRefresh,
  });

  final List<Widget> children;
  final ScrollController? controller;

  /// When supplied, the page gains pull-to-refresh instead of a Refresh button.
  /// The list is forced scrollable so a short page (a single notice, or the
  /// empty state) can still be pulled — otherwise the gesture is unreachable.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      controller: controller,
      physics: onRefresh == null ? null : const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final child in children)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: child,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    final refresh = onRefresh;
    return ColoredBox(
      color: CqUiColors.page,
      child: refresh == null
          ? list
          : RefreshIndicator(
              color: CqUiColors.blue,
              backgroundColor: Colors.white,
              onRefresh: refresh,
              child: list,
            ),
    );
  }
}

class CqHero extends StatelessWidget {
  const CqHero({super.key, required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      Text(
        title,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: CqUiColors.ink,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        subtitle,
        style: const TextStyle(color: CqUiColors.secondary, height: 1.45),
      ),
    ],
  );
}

class CqPanel extends StatelessWidget {
  const CqPanel({super.key, required this.child, this.title, this.icon});
  final Widget child;
  final String? title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: CqUiColors.outline),
      borderRadius: BorderRadius.circular(18),
      boxShadow: const [
        BoxShadow(
          color: Color(0x100B2759),
          blurRadius: 14,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: CqUiColors.blue),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  title!,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: CqUiColors.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        child,
      ],
    ),
  );
}

enum CqNoticeTone { info, warning, error, success }

class CqNotice extends StatelessWidget {
  const CqNotice({
    super.key,
    required this.message,
    this.tone = CqNoticeTone.info,
    this.messageKey,
  });

  final String message;
  final CqNoticeTone tone;
  final Key? messageKey;

  @override
  Widget build(BuildContext context) {
    final (Color fill, Color foreground, IconData icon) = switch (tone) {
      CqNoticeTone.info => (
        CqUiColors.blueSoft,
        CqUiColors.navy,
        Icons.info_outline_rounded,
      ),
      CqNoticeTone.warning => (
        CqUiColors.warningSoft,
        CqUiColors.warning,
        Icons.warning_amber_rounded,
      ),
      CqNoticeTone.error => (
        CqUiColors.dangerSoft,
        CqUiColors.danger,
        Icons.error_outline,
      ),
      CqNoticeTone.success => (
        CqUiColors.successSoft,
        CqUiColors.success,
        Icons.check_circle_outline,
      ),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              key: messageKey,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CqFullWidthAction extends StatelessWidget {
  const CqFullWidthAction({
    super.key,
    required this.text,
    required this.onPressed,
    this.icon = Icons.arrow_forward_rounded,
    this.actionKey,
  });

  final String text;
  final VoidCallback? onPressed;
  final IconData icon;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 52,
    child: FilledButton.icon(
      key: actionKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(text),
      style: FilledButton.styleFrom(
        backgroundColor: CqUiColors.blue,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFB9C4D7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class CqMetaText extends StatelessWidget {
  const CqMetaText({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(color: CqUiColors.secondary, fontSize: 12),
  );
}
