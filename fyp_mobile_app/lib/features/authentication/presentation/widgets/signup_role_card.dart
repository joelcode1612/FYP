import 'package:flutter/material.dart';

import 'package:fyp/core/theme/sitewise_theme.dart';

/// One selectable account-purpose card from Step 1.
///
/// The selected state uses a blue border, a pale-blue wash and a filled radio;
/// the unselected state uses the shared light border on white with an empty
/// radio. Only the parent decides which card is selected — this widget never
/// holds selection state, so two cards can never both appear active.
class SignupRoleCard extends StatelessWidget {
  const SignupRoleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $description',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
            decoration: BoxDecoration(
              color: selected
                  ? SitewiseColors.infoWash
                  : SitewiseColors.surface,
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
              border: Border.all(
                color: selected
                    ? SitewiseColors.action
                    : SitewiseColors.border,
                width: selected ? 1.8 : 1.2,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _illustration(),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: SitewiseColors.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: SitewiseColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _radio(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _illustration() => Container(
    width: 62,
    height: 62,
    decoration: BoxDecoration(
      color: SitewiseColors.geoWash,
      borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
    ),
    alignment: Alignment.center,
    child: Icon(icon, size: 32, color: SitewiseColors.action),
  );

  Widget _radio() => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: selected ? SitewiseColors.action : SitewiseColors.borderStrong,
        width: 2,
      ),
    ),
    alignment: Alignment.center,
    child: selected
        ? Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: SitewiseColors.action,
            ),
          )
        : null,
  );
}

/// Compact informational note beneath the role cards.
class SignupInfoNote extends StatelessWidget {
  const SignupInfoNote({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    decoration: BoxDecoration(
      color: SitewiseColors.infoWash.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(
          Icons.info_outline_rounded,
          size: 17,
          color: SitewiseColors.action,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: SitewiseColors.text,
            ),
          ),
        ),
      ],
    ),
  );
}
