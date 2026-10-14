import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web property detail: two-column evaluation workspace — listing and map on
/// the left, shortlist actions and location intelligence on the right.
///
/// Ported from `entrepreneur_property_detail_web_page.dart` in the Flutter web
/// tree. The property id travels as `?id=` instead of `settings.arguments`,
/// the page cubit loads the same `loadAnalysis(id)` the Flutter page did, and
/// the SnackBar confirmations become inline success lines. "Add to compare"
/// toggles in place and reveals a link to `/entrepreneur/compare` rather than
/// auto-navigating (links work without JavaScript).
class PropertyDetailPage extends StatefulComponent {
  /// The property id from the `?id=` query param.
  final String id;

  const PropertyDetailPage({super.key, required this.id});

  @override
  State<PropertyDetailPage> createState() => _PropertyDetailPageState();
}

class _PropertyDetailPageState extends State<PropertyDetailPage> {
  late final EntrepreneurCubit vm;
  String? _saveMessage;
  bool _compareLinkShown = false;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newEntrepreneurCubit();
    unawaited(vm.loadAnalysis(component.id));
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AppCubit, AppState>(
      cubit: AppLocator.appCubit,
      builder: (context, _) {
        final appCubit = AppLocator.appCubit;
        return CubitBuilder<EntrepreneurCubit, EntrepreneurState>(
          cubit: vm,
          builder: (context, _) {
            return AppLayout(
              role: AppRole.entrepreneur,
              currentRoute: '/entrepreneur/property-detail',
              title: 'Property detail',
              subtitle:
                  'Rental, floor area, facilities and the location intelligence for this site.',
              child: component.id.isEmpty
                  ? const _NotFound()
                  : FutureBuilder<CommercialProperty?>(
                      future: AppLocator.properties.detail(component.id),
                      builder: (c, snap) {
                        if (!snap.hasData) return const _Loading();
                        final p = snap.data!;
                        final saved = appCubit.isSaved(p.id);
                        return div(classes: 'row row--top row--md', [
                          div(classes: 'grow', [_Header(property: p)]),
                          div(classes: 'w-35 stack', [
                            _actions(appCubit, p.id, saved),
                            _Analysis(vm: vm),
                          ]),
                        ]);
                      },
                    ),
            );
          },
        );
      },
    );
  }

  Component _actions(AppCubit appCubit, String id, bool saved) {
    final compared = appCubit.isCompared(id);
    return div(classes: 'card stack', [
      ActionButton(
        saved ? 'Saved ✓' : 'Save property',
        icon: saved ? 'bookmark' : 'bookmark_border',
        onClick: () {
          appCubit.toggleSaved(id);
          setState(() {
            _saveMessage = saved
                ? 'Removed from saved.'
                : 'Saved to your shortlist.';
          });
        },
      ),
      if (_saveMessage != null)
        span(classes: 'small text-success', [Component.text(_saveMessage!)]),
      ActionButton(
        compared ? 'Added to compare ✓' : 'Add to compare',
        variant: 'secondary',
        icon: 'compare_arrows',
        onClick: () {
          appCubit.toggleCompared(id);
          setState(() => _compareLinkShown = appCubit.isCompared(id));
        },
      ),
      if (_compareLinkShown && compared)
        span(classes: 'small text-success', [
          Component.text('Added to your comparison set.'),
        ]),
      if (_compareLinkShown && compared)
        const ActionLink(
          'Open compare',
          href: '/entrepreneur/compare',
          variant: 'ghost',
        ),
      ActionLink(
        'Generate evaluation report',
        href: '/entrepreneur/report?id=$id',
        variant: 'secondary',
        icon: 'description',
      ),
    ]);
  }
}

class _Header extends StatelessComponent {
  final CommercialProperty property;
  const _Header({required this.property});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      div(classes: 'row row--sm', [
        h1(classes: 'title grow', [Component.text(property.title)]),
        Pill(
          property.verification.label,
          tone: toneForVerification(property.verification),
        ),
      ]),
      p(classes: 'body', [
        Component.text(
          '${property.address}, ${property.postcode} ${property.city}',
        ),
      ]),
      div(classes: 'title', [
        Component.text(
          'RM${property.rentalRm.toStringAsFixed(0)} / '
          '${property.sizeSqft.toStringAsFixed(0)} sq ft · '
          '${property.propertyType}',
        ),
      ]),
      _MapPanel(
        pins: [
          _MapPin(
            id: property.id,
            label: property.title,
            latitude: property.latitude,
            longitude: property.longitude,
            highlighted: true,
          ),
        ],
      ),
      if (property.hasTour)
        ActionLink(
          'Open 360° tour',
          href: '/entrepreneur/tour?id=${property.id}',
          variant: 'secondary',
          icon: 'threesixty',
        ),
    ]);
  }
}

class _Analysis extends StatelessComponent {
  final EntrepreneurCubit vm;
  const _Analysis({required this.vm});

  @override
  Component build(BuildContext context) {
    if (vm.loading) return const _Loading();
    final a = vm.analysis;
    if (a == null) return div(classes: 'stack', []);
    return div(classes: 'card stack', [
      h2(classes: 'title', [Component.text('Location intelligence')]),
      _EvidenceScore(score: a.suitabilityScore),
      div(classes: 'divider', []),
      p(classes: 'body', [Component.text(a.demandSummary)]),
      div(classes: 'divider', []),
      for (final f in a.factors) _FactorRow(factor: f),
    ]);
  }
}

class _EvidenceScore extends StatelessComponent {
  final double score;
  const _EvidenceScore({required this.score});

  String get _toneClass => score >= 75
      ? 'text-success'
      : score >= 55
      ? 'text-action'
      : score >= 40
      ? 'text-warning'
      : 'text-danger';

  @override
  Component build(BuildContext context) {
    return div(classes: 'row row--top row--sm', [
      div(classes: 'metric $_toneClass', [
        Component.text(score.toStringAsFixed(0)),
      ]),
      div(classes: 'grow stack', [
        span(classes: 'title', [Component.text('Suitability')]),
        p(classes: 'small', [
          Component.text(
            'Evidence-weighted score from foot traffic, competition, '
            'accessibility and rental efficiency.',
          ),
        ]),
      ]),
    ]);
  }
}

class _FactorRow extends StatelessComponent {
  final LocationFactor factor;
  const _FactorRow({required this.factor});

  @override
  Component build(BuildContext context) {
    final tone = switch (factor.impact) {
      'Positive' => 'success',
      'Risk' => 'warning',
      _ => 'neutral',
    };
    final bucket = (((factor.score / 5).round()).clamp(1, 20)) * 5;
    return div(classes: 'stack', [
      div(classes: 'row row--sm', [
        span(classes: 'small grow', [Component.text(factor.name)]),
        Pill(factor.impact, tone: tone),
      ]),
      span(classes: 'weights__track', [
        span(classes: 'weights__fill w-$bucket', []),
      ]),
      p(classes: 'small', [Component.text(factor.evidence)]),
    ]);
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Property')]),
      h2(classes: 'title-lg', [Component.text('Record not found')]),
      p(classes: 'body', [
        Component.text(
          'This property could not be loaded. It may have been removed or '
          'the link is incomplete.',
        ),
      ]),
      const ActionLink(
        'Back to explore',
        href: '/entrepreneur/explore',
        variant: 'secondary',
      ),
    ]);
  }
}

/// One pin on the stylised map panel, positioned with the same lat/lng
/// proportions as the Flutter `SitewiseMapPanel`.
class _MapPin {
  final String id;
  final String label;
  final double latitude;
  final double longitude;
  final bool highlighted;

  const _MapPin({
    required this.id,
    required this.label,
    required this.latitude,
    required this.longitude,
    this.highlighted = false,
  });

  double get _x => ((longitude - 100.3) / 3.5).clamp(-0.9, 0.9).toDouble();

  double get _y => -((latitude - 1.5) / 4.0).clamp(-0.9, 0.9).toDouble();

  String get position =>
      'position:absolute;left:${((_x + 1) / 2 * 100).toStringAsFixed(1)}%;'
      'top:${((1 - _y) / 2 * 100).toStringAsFixed(1)}%;';
}

/// Stylised Klang Valley map placeholder. Interactive map tiles are not
/// available in the web prototype, so each pin is a link to its property and
/// the same pins are listed underneath as text links.
class _MapPanel extends StatelessComponent {
  final List<_MapPin> pins;
  const _MapPanel({required this.pins});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      div(classes: 'visual visual--map', [
        div(classes: 'visual__grid', []),
        for (final pin in pins)
          a(
            href: '/entrepreneur/property-detail?id=${pin.id}',
            attributes: {'style': pin.position, 'title': pin.label},
            [
              Icon(
                pin.highlighted ? 'location_on' : 'place',
                size: pin.highlighted ? 'lg' : null,
                label: pin.label,
              ),
            ],
          ),
      ]),
      p(classes: 'small', [
        Component.text(
          'Stylised Klang Valley map — interactive map tiles require the '
          'mobile app. Each pin links to its property page.',
        ),
      ]),
      ul(classes: 'stack', [
        for (final pin in pins)
          li([
            a(
              href: '/entrepreneur/property-detail?id=${pin.id}',
              classes: 'text-action',
              [Component.text(pin.label)],
            ),
          ]),
      ]),
    ]);
  }
}
