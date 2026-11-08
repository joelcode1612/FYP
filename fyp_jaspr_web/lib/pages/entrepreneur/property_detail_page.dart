import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web property detail, laid out as the source's `property.html`.
///
/// ```text
/// .page-head        eyebrow · h1 · address · verification/suitability badges
/// .detail-grid
///   .analysis       Gallery · Listing information (.kv) · Description
///   .analysis       Actions · Map location · What is not shown
/// ```
///
/// The previous version stacked `.card`s inside a `row`/`w-35` split: no
/// definition list, no gallery, no provenance chips and no "what is not shown"
/// panel — the last of which is the page's honesty contract, not decoration.
///
/// Data honesty rules carried over from the source:
///  * a missing value is labelled, never printed as 0 or invented;
///  * provenance is shown next to each fact;
///  * the score is a relative indicator and always carries the disclaimer.
@client
class PropertyDetailPage extends StatefulComponent {
  /// The property id from the `?id=` query param.
  final String id;

  const PropertyDetailPage({super.key, required this.id});

  @override
  State<PropertyDetailPage> createState() => _PropertyDetailPageState();
}

class _PropertyDetailPageState extends State<PropertyDetailPage> {
  String? _saveMessage;
  bool _compareLinkShown = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(
        context.read(entrepreneurNotifierProvider.notifier).loadAnalysis(
          component.id,
        ),
      );
    });
  }

  @override
  Component build(BuildContext context) {
    final saved = context.watch(appNotifierProvider.select((app) => app.saved));
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );

    // The header carries the property's own title and address, so it is
    // rendered inside the future rather than by `AppLayout`.
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/property-detail',
      title: 'Property',
      eyebrow: 'Property',
      showPageHead: false,
      child: component.id.isEmpty
          ? const _NotFound()
          : FutureBuilder<CommercialProperty?>(
              future: AppLocator.properties.detail(component.id),
              builder: (c, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _Loading();
                }
                // `hasData` is false for both "pending" and "completed
                // with null", so the null case needs its own branch —
                // otherwise an unknown id spins forever.
                final p = snap.data;
                if (p == null) return const _NotFound();
                return _Detail(
                  property: p,
                  saved: saved.contains(p.id),
                  compared: compared.contains(p.id),
                  saveMessage: _saveMessage,
                  compareLinkShown: _compareLinkShown,
                  onToggleSaved: () {
                    context
                        .read(appNotifierProvider.notifier)
                        .toggleSaved(p.id);
                    final nowSaved = context
                        .read(appNotifierProvider)
                        .saved
                        .contains(p.id);
                    setState(() {
                      _saveMessage = nowSaved
                          ? 'Saved to your shortlist.'
                          : 'Removed from saved.';
                    });
                  },
                  onToggleCompared: () {
                    context
                        .read(appNotifierProvider.notifier)
                        .toggleCompared(p.id);
                    final nowCompared = context
                        .read(appNotifierProvider)
                        .compared
                        .contains(p.id);
                    setState(
                      () => _compareLinkShown = nowCompared,
                    );
                  },
                );
              },
            ),
    );
  }
}

class _Detail extends StatelessComponent {
  final CommercialProperty property;
  final bool saved;
  final bool compared;
  final String? saveMessage;
  final bool compareLinkShown;
  final void Function() onToggleSaved;
  final void Function() onToggleCompared;

  const _Detail({
    required this.property,
    required this.saved,
    required this.compared,
    required this.onToggleSaved,
    required this.onToggleCompared,
    this.saveMessage,
    this.compareLinkShown = false,
  });

  /// Provenance of a listing fact.
  ///
  /// The source tags each row `admin` or `owner`. The target carries one
  /// verifiable signal — [CommercialProperty.verification] — so an approved
  /// listing's rent/area/availability are labelled "Admin verified" and every
  /// owner-supplied attribute is labelled "Owner provided". Nothing is claimed
  /// as verified unless the listing actually is.
  bool get _adminVerified =>
      property.verification == VerificationStatus.verified;

  String get _addressLine =>
      '${property.address}, ${property.postcode} ${property.city}, '
      '${property.state}';

  @override
  Component build(BuildContext context) {
    return div([
      PageHead(
        eyebrow: 'Property',
        title: property.title,
        description: _addressLine,
        badges: [
          StatusBadge(
            'Verification: ${property.verification.label.toLowerCase()}',
            tone: toneForVerification(property.verification),
          ),
          StatusBadge(
            'Suitability: ${property.suitabilityScore.toStringAsFixed(0)}/100',
            tone: _scoreTone(property.suitabilityScore),
          ),
        ],
      ),
      div(classes: 'detail-grid', [
        // --- Left column ---------------------------------------------------
        div(classes: 'analysis', [
          _galleryPanel(),
          _listingPanel(),
          _descriptionPanel(),
        ]),

        // --- Right column --------------------------------------------------
        div(classes: 'analysis', [
          _actionsPanel(),
          _mapPanel(),
          _notShownPanel(),
        ]),
      ]),
    ]);
  }

  // ------------------------------------------------------------------ gallery

  Component _galleryPanel() {
    // The target ships no listing photographs — the source's `coverImage` has no
    // counterpart in `CommercialProperty`. Three styled placeholder tiles keep
    // the gallery's grid and box, and the caption says what they are.
    return section(classes: 'panel', [
      h2([Component.text('Gallery')]),
      div(classes: 'gallery', [
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
          span(classes: 'cover', [Icon('storefront', size: 'lg')]),
      ]),
      p(classes: 'disclaimer', [
        Component.text(
          property.imageUrl == null
              ? 'No image URL is available for this property.'
              : 'Source listing image from the imported workbook. Availability depends on the original image host.',
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------ listing facts

  Component _listingPanel() {
    final admin = StatusBadge('Admin verified', tone: 'success');
    final owner = StatusBadge('Owner provided', tone: 'neutral');

    return section(classes: 'panel', [
      h2([Component.text('Listing information')]),
      dl(classes: 'kv', [
        _row(
          'Monthly rent',
          property.rentalDisplay,
          _adminVerified ? admin : owner,
        ),
        _row(
          'Floor area',
          '${property.sizeSqft.toStringAsFixed(0)} sq ft',
          _adminVerified ? admin : owner,
        ),
        _row('Property type', property.propertyType, owner),
        _row(
          'Availability',
          _adminVerified ? 'Available' : 'Pending verification',
          _adminVerified ? admin : owner,
        ),
        _row(
          'Rental efficiency',
          'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
          owner,
        ),
        _row(
          'Coordinates',
          '${property.latitude.toStringAsFixed(4)}, '
              '${property.longitude.toStringAsFixed(4)}',
          owner,
        ),
        _row(
          '360° tour',
          property.hasTour ? 'Published' : 'Not available',
          property.hasTour ? admin : owner,
        ),
      ]),
    ]);
  }

  Component _row(String label, String value, Component prov) => div([
    dt([Component.text(label)]),
    dd([Component.text(value)]),
    span([prov]),
  ]);

  // -------------------------------------------------------------- description

  Component _descriptionPanel() {
    return section(classes: 'panel', [
      h2([Component.text('Description')]),
      p(classes: 'body', [
        Component.text(
          '${property.title} is a ${property.propertyType.toLowerCase()} of '
          '${property.sizeSqft.toStringAsFixed(0)} sq ft in ${property.city}, '
          '${property.state}, offered at ${property.rentalDisplay} per month. '
          'The listing record is owner-supplied; verification is performed by an '
          'administrator before it appears as available.',
        ),
      ]),
      if (property.requirements.isNotEmpty || property.tags.isNotEmpty)
        div(classes: 'chips', [
          for (final r in property.requirements)
            span(classes: 'tag ml', [Component.text(r)]),
          for (final t in property.tags)
            span(classes: 'tag det', [Component.text(t)]),
        ]),
      span(classes: 'prov prov-owner', [Component.text('Owner provided')]),
    ]);
  }

  // ------------------------------------------------------------------ actions

  Component _actionsPanel() {
    return section(classes: 'panel', [
      h2([Component.text('Actions')]),
      div(classes: 'actions-row', [
        ActionLink(
          'Explore location analysis',
          href: '/entrepreneur/map?id=${property.id}',
          icon: 'map',
        ),
        ActionLink(
          'Why this score',
          href: '/entrepreneur/explanation?property=${property.id}',
          variant: 'secondary',
        ),
        ActionButton(
          saved ? 'Saved ✓' : 'Save favourite',
          variant: 'secondary',
          icon: saved ? 'bookmark' : 'bookmark_border',
          onClick: onToggleSaved,
        ),
        ActionButton(
          compared ? 'In compare ✓' : 'Add to compare',
          variant: 'secondary',
          icon: 'compare_arrows',
          onClick: onToggleCompared,
        ),
        if (property.hasTour)
          ActionLink(
            'Open 360° tour',
            href: '/entrepreneur/tour?id=${property.id}',
            variant: 'secondary',
            icon: '360',
          ),
        ActionLink(
          'Location report',
          href: '/entrepreneur/report?id=${property.id}',
          variant: 'secondary',
          icon: 'description',
        ),
      ]),
      if (saveMessage != null)
        span(classes: 'small text-success', [Component.text(saveMessage!)]),
      if (compareLinkShown && compared)
        ActionLink(
          'Open compare',
          href: '/entrepreneur/compare',
          variant: 'ghost',
        ),
    ]);
  }

  // ---------------------------------------------------------------------- map

  Component _mapPanel() {
    // One pin, positioned by the same projection the explore map uses. The
    // surface is the stylised panel — no map SDK exists in either tree.
    final x = ((property.longitude - 100.3) / 3.5).clamp(-0.9, 0.9);
    final y = -((property.latitude - 1.5) / 4.0).clamp(-0.9, 0.9);
    final left = ((x + 1) / 2 * 100).toStringAsFixed(1);
    final top = ((1 - y) / 2 * 100).toStringAsFixed(1);

    return section(classes: 'panel', [
      h2([Component.text('Map location')]),
      div(classes: 'map-pane', [
        div(classes: 'map-canvas', [
          div(classes: 'visual__grid', []),
          span(
            classes: 'map-pin map-pin--active',
            attributes: {
              'style': 'left:$left%;top:$top%;',
              'title': property.title,
            },
            [
              Icon('place', size: 'sm'),
              span(classes: 'map-pin__price', [Component.text(property.city)]),
            ],
          ),
        ]),
        div(classes: 'map-legend', [
          span([
            span(classes: 'lg lg-prop', []),
            Component.text('This property'),
          ]),
          span([
            span(classes: 'lg lg-comp', []),
            Component.text('Competitors'),
          ]),
          span([span(classes: 'lg lg-transit', []), Component.text('Transit')]),
        ]),
      ]),
      p(classes: 'small', [
        Component.text(
          'Stylised Klang Valley projection. Interactive tiles require the '
          'mobile app; the pin marks the listing coordinates.',
        ),
      ]),
    ]);
  }

  // ----------------------------------------------------------- not shown list

  Component _notShownPanel() {
    // The source's honesty contract for this page: the things the system
    // deliberately does not claim.
    return section(classes: 'panel', [
      h2([Component.text('What is not shown')]),
      ul([
        li([
          Component.text(
            'Regulatory status (licensing, extraction, venting, grease trap) — '
            'not verified by this system.',
          ),
        ]),
        li([
          Component.text(
            'Revenue, footfall or customer-volume forecasts — this system does '
            'not produce them.',
          ),
        ]),
        li([
          Component.text(
            'Owner contact details and internal verification notes.',
          ),
        ]),
      ]),
      p(classes: 'disclaimer', [
        Component.text(
          'A suitability score is a relative decision-support indicator. It is '
          'not a probability of business success, a revenue forecast, regulatory '
          'approval, or a guarantee of any kind.',
        ),
      ]),
    ]);
  }

  static String _scoreTone(double score) {
    if (score >= 75) return 'success';
    if (score >= 55) return 'action';
    if (score >= 40) return 'warning';
    return 'danger';
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading property…'),
  ]);
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) => div([
    const PageHead(
      eyebrow: 'Property',
      title: 'Record not found',
      description: 'This property could not be loaded.',
    ),
    EmptyState(
      title: 'No property selected',
      body:
          'This property could not be loaded. It may have been removed, or the '
          'link is incomplete.',
      action: const ActionLink(
        'Browse properties',
        href: '/entrepreneur/explore',
        variant: 'primary',
      ),
    ),
  ]);
}
