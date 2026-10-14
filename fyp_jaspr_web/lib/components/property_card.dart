import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'ui.dart';

/// Verification → pill tone, matching the Flutter
/// `SitewiseStatusBadge.forVerification` mapping.
String toneForVerification(VerificationStatus status) => switch (status) {
  VerificationStatus.draft => 'neutral',
  VerificationStatus.pending => 'warning',
  VerificationStatus.verified => 'success',
  VerificationStatus.rejected => 'danger',
};

/// Vertical property card for desktop grids — the Jaspr counterpart to
/// `web_property_card.dart` in the Flutter web tree. Same data contract,
/// desktop composition.
///
/// Navigation is a plain link ([href]), so the card works without JavaScript;
/// the bookmark and compare controls are siblings of the link (never nested
/// inside it) and call back into the page, which owns the `AppCubit`.
class PropertyCard extends StatelessComponent {
  final CommercialProperty property;

  /// Detail route for this property, including the `?id=` query param.
  final String href;

  final bool saved;
  final bool compared;
  final void Function()? onToggleSaved;
  final void Function()? onToggleCompared;

  /// Optional banner above the media area (recommendation rank, etc.).
  final String? rankBanner;

  const PropertyCard({
    super.key,
    required this.property,
    required this.href,
    this.saved = false,
    this.compared = false,
    this.onToggleSaved,
    this.onToggleCompared,
    this.rankBanner,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'p-card', [
      if (rankBanner != null)
        div(classes: 'p-card__banner', [Component.text(rankBanner!)]),
      div(classes: 'p-card__media', [
        a(href: href, classes: 'p-card__media-link', [
          Icon('storefront', size: 'lg', label: property.title),
        ]),
        span(classes: 'p-card__badge', [
          Pill(
            property.verification.label,
            tone: toneForVerification(property.verification),
          ),
        ]),
        if (onToggleSaved != null)
          button(
            classes: saved ? 'p-card__save p-card__save--on' : 'p-card__save',
            attributes: {
              'type': 'button',
              'aria-label': saved ? 'Remove from saved' : 'Save property',
            },
            events: events(onClick: onToggleSaved!),
            [Icon(saved ? 'bookmark' : 'bookmark_border')],
          ),
      ]),
      div(classes: 'p-card__body', [
        a(href: href, classes: 'p-card__title', [
          Component.text(property.title),
        ]),
        div(classes: 'p-card__meta', [
          Component.text('${property.city}, ${property.state}'),
        ]),
        div(classes: 'p-card__price-row', [
          span(classes: 'p-card__price', [
            Component.text('RM${property.rentalRm.toStringAsFixed(0)}'),
          ]),
          span(classes: 'p-card__size', [
            Component.text(' / ${property.sizeSqft.toStringAsFixed(0)} sq ft'),
          ]),
          span(classes: 'grow', []),
          span(classes: 'p-card__score', [
            Component.text(property.suitabilityScore.toStringAsFixed(0)),
          ]),
        ]),
        if (onToggleCompared != null)
          button(
            classes: compared
                ? 'p-card__compare p-card__compare--on'
                : 'p-card__compare',
            attributes: {'type': 'button'},
            events: events(onClick: onToggleCompared!),
            [
              Icon(
                compared ? 'check_box' : 'check_box_outline_blank',
                size: 'sm',
              ),
              Component.text(compared ? 'Added to compare' : 'Compare'),
            ],
          ),
      ]),
    ]);
  }
}
