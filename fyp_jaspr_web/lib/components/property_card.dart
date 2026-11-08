import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'ui.dart';

/// Vertical property card for desktop grids.
///
/// Migrated to the source design's card structure (`sitewise-entrepreneur/
/// assets/js/cards.js` + `app.css`):
///
///   article.pcard
///     a.pcard-media > .cover      placeholder media, never a photograph
///     div.body
///       h3 > a                    title
///       p.addr                    address
///       p.pcard-price > small     rent
///       ul.pcard-attrs > li       size, type, parking
///       div.badges                verification + 360 pills
///       div.actions               save / compare / 360
///
/// The previous markup used this file's own `p-card__*` vocabulary, which has no
/// counterpart in the source design and no CSS behind it in `styles.css`.
///
/// Navigation is a plain link ([href]), so the card works without JavaScript;
/// the save and compare controls are siblings of the link (never nested inside
/// it) and call back into the page, which owns the app-state notifier.
///
/// Explore additions, all opt-in so other pages are unaffected: [selected]
/// marks the card that a map interaction picked, [onLocate] asks the page to
/// bring this property up on the map, [anchorId] gives the card a DOM id so a
/// map click can scroll it into view, and a valid [CommercialProperty.sourceUrl]
/// renders an external "Original listing" link.
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

  /// Highlighted because a map marker / locate action chose this property.
  final bool selected;

  /// Ask the owning page to show this property on the map.
  final void Function()? onLocate;

  /// DOM id for the article, so map interactions can scroll to the card.
  final String? anchorId;

  const PropertyCard({
    super.key,
    required this.property,
    required this.href,
    this.saved = false,
    this.compared = false,
    this.onToggleSaved,
    this.onToggleCompared,
    this.rankBanner,
    this.selected = false,
    this.onLocate,
    this.anchorId,
  });

  @override
  Component build(BuildContext context) {
    // Attribute list, in the source's order: size, type, parking. A missing
    // value renders as an em dash with the `muted` class rather than being
    // omitted, so the row never reflows when data is absent.
    final firstTag = property.tags.isEmpty ? null : property.tags.first;
    final anchor = anchorId;
    final attrs = <(String, bool)>[
      ('#${property.id}', false),
      ('${property.sizeSqft.toStringAsFixed(0)} sq ft', false),
      (property.propertyType, false),
      (firstTag ?? '—', firstTag == null),
    ];

    return article(
      classes: selected ? 'pcard pcard--selected' : 'pcard',
      attributes: anchor != null ? {'id': anchor} : null,
      [
        if (rankBanner != null)
          div(classes: 'pcard-banner', [Component.text(rankBanner!)]),

        // Media. `aria-hidden` because the title link below is the real target -
        // this is a decorative duplicate of the same destination.
        AppLink(
          to: href,
          classes: 'pcard-media',
          attributes: {'tabindex': '-1', 'aria-hidden': 'true'},
          children: [
            if (property.imageUrl != null)
              Component.element(
                tag: 'img',
                attributes: {
                  'src': property.imageUrl!,
                  'alt': property.title,
                  'loading': 'lazy',
                  'referrerpolicy': 'no-referrer',
                  'style': 'width:100%;height:100%;object-fit:cover',
                },
              )
            else
              span(classes: 'cover', [
                Icon('storefront', size: 'lg', label: property.title),
              ]),
          ],
        ),

        div(classes: 'body', [
          h3([
            AppLink(to: href, children: [Component.text(property.title)]),
          ]),
          p(classes: 'addr', [
            Component.text(
              '${property.address}, ${property.city}, ${property.state}',
            ),
          ]),
          p(classes: 'pcard-price', [
            Component.text('RM${property.rentalRm.toStringAsFixed(0)}'),
            small([Component.text(' / month')]),
          ]),
          ul(classes: 'pcard-attrs', [
            for (final (text, muted) in attrs)
              li(classes: muted ? 'muted' : null, [Component.text(text)]),
          ]),
          div(classes: 'badges', [
            Pill(
              property.verification.label,
              tone: switch (property.verification) {
                VerificationStatus.draft => 'neutral',
                VerificationStatus.pending => 'warning',
                VerificationStatus.verified => 'success',
                VerificationStatus.rejected => 'danger',
              },
            ),
            if (property.hasTour) const Pill('360°', tone: 'action'),
          ]),

          div(classes: 'actions', [
            // The source card leads with the primary navigation action
            // (`<a class="btn sm primary">View details</a>`); the target card had
            // no primary action at all, only the two toggles.
            AppLink(
              to: href,
              classes: 'btn sm btn--primary',
              children: [Component.text('View details')],
            ),
            if (onLocate != null)
              button(
                classes: 'btn sm',
                attributes: {
                  'type': 'button',
                  'aria-label': 'Locate ${property.title} on the map',
                },
                events: events(onClick: onLocate!),
                [Component.text('Locate')],
              ),
            if (onToggleSaved != null)
              button(
                classes: saved ? 'btn sm icon-btn is-saved' : 'btn sm icon-btn',
                attributes: {
                  'type': 'button',
                  'aria-pressed': saved ? 'true' : 'false',
                  'aria-label': saved ? 'Remove from saved' : 'Save property',
                },
                events: events(onClick: onToggleSaved!),
                [Component.text(saved ? 'Saved' : 'Save')],
              ),
            if (onToggleCompared != null)
              button(
                classes: compared ? 'btn sm icon-btn is-on' : 'btn sm icon-btn',
                attributes: {
                  'type': 'button',
                  'aria-pressed': compared ? 'true' : 'false',
                },
                events: events(onClick: onToggleCompared!),
                [Component.text(compared ? 'In compare' : 'Compare')],
              ),
            if (property.hasTour)
              AppLink(
                to: '$href&tour=1',
                classes: 'btn sm',
                children: [Component.text('360°')],
              ),
            // Only when the dataset recorded a usable http(s) source link.
            if (_validSourceUrl(property) != null)
              Component.element(
                tag: 'a',
                classes: 'btn sm',
                attributes: {
                  'href': _validSourceUrl(property)!,
                  'target': '_blank',
                  'rel': 'noopener noreferrer',
                },
                children: [Component.text('Original listing')],
              ),
          ]),
        ]),
      ],
    );
  }

  /// The property's source link, but only if it is a real http(s) URL.
  /// Anything else (relative junk, mailto, empty) renders no link at all.
  static String? _validSourceUrl(CommercialProperty property) {
    final raw = property.sourceUrl;
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return (uri.scheme == 'http' || uri.scheme == 'https') ? raw : null;
  }
}
