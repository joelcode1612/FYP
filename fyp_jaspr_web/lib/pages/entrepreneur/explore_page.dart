import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/filter_panel.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web explore — property panel beside the map.
///
/// Layout: a fixed-width panel on the left, the map filling the rest. The panel
/// is **one slot with two modes** — it shows the property list by default and
/// swaps to the filter inputs when Filters is pressed. Both modes share the same
/// head/body frame, so the panel never changes size or position when switching.
///
/// The selected-property detail and the zoom controls float *over the map*,
/// which is where they belong: they describe a point on the map, not the list.
///
/// Styling stays inside the existing system — the panel is `surface` + `1px
/// --border` + radius 16 at `elevation: 0`, and the map keeps the `--geo-wash`
/// treatment. No shadow is used anywhere (DESIGN.md §5).
///
/// Two honesty constraints:
///  * There is **no map SDK** in either tree. The surface is the same stylised
///    panel the mobile app uses; only its interaction is real.
///  * Zoom is **real** — it scales the lat/lng projection, so pins genuinely
///    move and clip. A decorative zoom button would be a lie.
class ExplorePage extends StatefulComponent {
  /// Open with the map focused (route passes `id == 'map'`).
  final bool startInMap;

  const ExplorePage({super.key, this.startInMap = false});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  late final EntrepreneurCubit vm;

  /// The structured filter, applied on top of the cubit's query results.
  PropertyFilter filter = PropertyFilter.empty;

  /// Property chosen from a pin, shown in the map's detail card.
  String? selectedId;

  /// Which mode the left panel is in. `false` = property list, `true` = filters.
  bool filtersOpen = false;

  /// Hides the whole left panel, giving the map the full width.
  late bool panelHidden = component.startInMap;

  /// Real zoom factor applied to the pin projection.
  int zoom = 1;

  static const _zoomLevels = [1, 2, 4];

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newEntrepreneurCubit();
    unawaited(vm.loadExplore());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  List<CommercialProperty> get _results => filter.apply(vm.explore);

  /// Listings that can actually be plotted. A listing with no coordinates would
  /// otherwise land at 0,0 in the projection.
  List<CommercialProperty> get _mappable =>
      _results.where((p) => p.latitude != 0 || p.longitude != 0).toList();

  CommercialProperty? get _selected {
    final id = selectedId;
    if (id == null) return null;
    for (final p in _results) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _setFilter(PropertyFilter next) => setState(() {
    filter = next;
    if (selectedId != null && !_results.any((p) => p.id == selectedId)) {
      selectedId = null;
    }
  });

  void _reset() => setState(() {
    filter = PropertyFilter.empty;
    selectedId = null;
  });

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
              currentRoute: '/entrepreneur/explore',
              title: 'Explore',
              subtitle:
                  'Search and filter every listing, then read the detail beside the map.',
              child: div(classes: 'explore', [
                _topBar(),
                if (vm.loading) const _Loading() else _body(appCubit),
              ]),
            );
          },
        );
      },
    );
  }

  // ----------------------------------------------------------------- top bar

  Component _topBar() => div(classes: 'explore__bar', [
    div(classes: 'grow', [
      input(
        classes: 'input',
        attributes: {
          'type': 'search',
          'placeholder': 'Search area, street or listing…',
          'aria-label': 'Search area, street or listing',
        },
        events: events<String>(onInput: vm.setQuery),
      ),
    ]),
    // Toggles the left panel between the list and the filter inputs. The label
    // says which way it will switch, so the button is never ambiguous.
    ActionButton(
      filtersOpen ? 'Show list' : 'Filters',
      variant: filtersOpen ? 'secondary' : 'primary',
      icon: filtersOpen ? 'list' : 'tune',
      onClick: () => setState(() {
        filtersOpen = !filtersOpen;
        panelHidden = false;
      }),
    ),
    if (!panelHidden)
      ActionButton(
        'Hide panel',
        variant: 'secondary',
        icon: 'chevron_left',
        onClick: () => setState(() => panelHidden = true),
      )
    else
      ActionButton(
        'Show panel',
        variant: 'secondary',
        icon: 'view_sidebar',
        onClick: () => setState(() => panelHidden = false),
      ),
  ]);

  // ------------------------------------------------------------------- body

  Component _body(AppCubit appCubit) => div(
    classes: panelHidden
        ? 'explore__body explore__body--full'
        : 'explore__body',
    [
      // LEFT — one slot, two modes. Swapping the children rather than moving
      // the panel keeps its width and position fixed.
      if (!panelHidden)
        div(classes: 'explore__panel', [
          if (filtersOpen) ..._filterMode() else ..._listMode(appCubit),
        ]),

      // RIGHT — the map. Detail card and zoom float over it.
      div(classes: 'explore__map-wrap', [
        _MapSurface(
          pins: [
            for (final p in _mappable)
              _MapPin(
                id: p.id,
                label: p.title,
                price: _compactRm(p.rentalRm),
                latitude: p.latitude,
                longitude: p.longitude,
                highlighted: p.id == selectedId,
                zoom: zoom,
              ),
          ],
          zoom: zoom,
        ),
        if (_selected != null) _detailCard(_selected!),
        _zoomControls(),
      ]),
    ],
  );

  // -------------------------------------------------------------- list mode

  List<Component> _listMode(AppCubit appCubit) {
    final results = _results;
    final avg = results.isEmpty
        ? null
        : results.map((p) => p.rentalRm).reduce((a, b) => a + b) /
              results.length;

    return [
      div(classes: 'explore__panel-head', [
        div(classes: 'grow stack', [
          span(classes: 'explore__count', [
            Component.text('${results.length} properties'),
          ]),
          span(classes: 'small', [
            Component.text(
              avg == null
                  ? 'No matches'
                  : 'Avg RM ${avg.toStringAsFixed(0)} / month',
            ),
          ]),
        ]),
      ]),
      div(classes: 'explore__panel-body', [
        if (results.isEmpty)
          const _NoMatches()
        else
          for (final p in results)
            div(classes: p.id == selectedId ? 'is-selected' : null, [
              PropertyCard(
                property: p,
                href: '/entrepreneur/property-detail?id=${p.id}',
                saved: appCubit.isSaved(p.id),
                compared: appCubit.isCompared(p.id),
                onToggleSaved: () => appCubit.toggleSaved(p.id),
                onToggleCompared: () => appCubit.toggleCompared(p.id),
              ),
            ]),
      ]),
    ];
  }

  // ------------------------------------------------------------ filter mode

  List<Component> _filterMode() => [
    div(classes: 'explore__panel-head', [
      div(classes: 'grow stack', [
        span(classes: 'explore__count', [Component.text('Filters')]),
        span(classes: 'small', [
          Component.text(
            filter.isEmpty
                ? 'Narrow the results'
                : '${filter.activeCount} applied',
          ),
        ]),
      ]),
      ActionButton(
        'Back to list',
        variant: 'ghost',
        icon: 'list',
        onClick: () => setState(() => filtersOpen = false),
      ),
    ]),
    div(classes: 'explore__panel-body', [
      FilterPanel(
        filter: filter,
        source: vm.explore,
        results: _results,
        onChanged: _setFilter,
        onReset: _reset,
      ),
    ]),
  ];

  // ----------------------------------------------------------- detail card

  Component _detailCard(CommercialProperty property) {
    final score = property.suitabilityScore;
    return div(classes: 'explore__detail', [
      div(classes: 'explore__detail-head', [
        span(classes: 'overline', [Component.text('Selected')]),
        ActionButton(
          'Close',
          variant: 'ghost',
          icon: 'close',
          onClick: () => setState(() => selectedId = null),
        ),
      ]),
      span(classes: 'title', [Component.text(property.title)]),
      p(classes: 'small', [
        Component.text(
          '${property.address}, ${property.city}, ${property.state}',
        ),
      ]),
      div(classes: 'explore__facts', [
        _fact('Rent', property.rentalDisplay),
        _fact('Floor area', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
        _fact('Type', property.propertyType),
        _fact(
          'Efficiency',
          'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
        ),
      ]),
      div(classes: 'explore__score-row', [
        span(classes: 'small grow', [Component.text('Suitability')]),
        span(
          classes: 'explore__score-value',
          attributes: {'style': 'color:${_scoreColor(score)}'},
          [Component.text('${score.toStringAsFixed(0)} / 100')],
        ),
      ]),
      ActionLink(
        'View full property',
        href: '/entrepreneur/property-detail?id=${property.id}',
        variant: 'secondary',
      ),
    ]);
  }

  Component _fact(String fieldLabel, String value) =>
      div(classes: 'explore__fact', [
        span(classes: 'tiny', [Component.text(fieldLabel)]),
        span(classes: 'small', [Component.text(value)]),
      ]);

  // -------------------------------------------------------------------- zoom

  Component _zoomControls() {
    final canZoomIn = zoom < _zoomLevels.last;
    final canZoomOut = zoom > _zoomLevels.first;
    return div(classes: 'explore__zoom', [
      button(
        classes: canZoomIn
            ? 'explore__zoom-btn'
            : 'explore__zoom-btn is-disabled',
        attributes: {'type': 'button', 'aria-label': 'Zoom in'},
        events: events(
          onClick: canZoomIn
              ? () => setState(
                  () => zoom = _zoomLevels[_zoomLevels.indexOf(zoom) + 1],
                )
              : null,
        ),
        [Icon('add')],
      ),
      button(
        classes: canZoomOut
            ? 'explore__zoom-btn'
            : 'explore__zoom-btn is-disabled',
        attributes: {'type': 'button', 'aria-label': 'Zoom out'},
        events: events(
          onClick: canZoomOut
              ? () => setState(
                  () => zoom = _zoomLevels[_zoomLevels.indexOf(zoom) - 1],
                )
              : null,
        ),
        [Icon('remove')],
      ),
    ]);
  }

  /// Same bands as every other score display. CSS custom-property references
  /// rather than hex literals, so values still come from `styles.css`
  /// (DESIGN.md §8, Don't #1).
  static String _scoreColor(double score) {
    if (score >= 75) return 'var(--success-text)';
    if (score >= 55) return 'var(--action)';
    if (score >= 40) return 'var(--warning)';
    return 'var(--danger)';
  }

  /// `7000` -> `RM 7k`. Compact enough for a map label.
  static String _compactRm(double v) {
    if (v >= 1000) {
      final k = v / 1000;
      final text = k == k.roundToDouble()
          ? k.toStringAsFixed(0)
          : k.toStringAsFixed(1);
      return 'RM ${text}k';
    }
    return 'RM ${v.toStringAsFixed(0)}';
  }
}

// ===========================================================================
// Supporting components
// ===========================================================================

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'card', [
    p(classes: 'body muted', [Component.text('Loading…')]),
  ]);
}

class _NoMatches extends StatelessComponent {
  const _NoMatches();

  @override
  Component build(BuildContext context) => div(classes: 'card stack', [
    span(classes: 'overline', [Component.text('No matches')]),
    h2(classes: 'title-lg', [
      Component.text('No properties match these filters'),
    ]),
    p(classes: 'body', [
      Component.text(
        'Widen the rent range or clear a location to see more listings.',
      ),
    ]),
  ]);
}

/// One price-labelled pin.
class _MapPin {
  final String id;
  final String label;
  final String price;
  final double latitude;
  final double longitude;
  final bool highlighted;
  final int zoom;

  const _MapPin({
    required this.id,
    required this.label,
    required this.price,
    required this.latitude,
    required this.longitude,
    required this.zoom,
    this.highlighted = false,
  });

  // Same projection as the Flutter `SitewiseMapPanel`. Zoom divides the span,
  // so a higher zoom spreads the same coordinates further apart; pins that fall
  // outside are clipped by the map's overflow rather than clamped to the edge,
  // which would pile unrelated properties on top of each other.
  double get _x => (longitude - 100.3) / (3.5 / zoom);

  double get _y => -((latitude - 1.5) / (4.0 / zoom));

  String get position =>
      'left:${((_x + 1) / 2 * 100).toStringAsFixed(2)}%;'
      'top:${((1 - _y) / 2 * 100).toStringAsFixed(2)}%;';
}

class _MapSurface extends StatelessComponent {
  final List<_MapPin> pins;
  final int zoom;

  const _MapSurface({required this.pins, required this.zoom});

  @override
  Component build(BuildContext context) => div(classes: 'explore__map', [
    div(classes: 'visual__grid', []),
    if (pins.isEmpty)
      span(classes: 'visual__chip', [Component.text('No properties to plot')]),
    for (final pin in pins)
      button(
        classes: pin.highlighted ? 'map-pin map-pin--active' : 'map-pin',
        attributes: {
          'type': 'button',
          'style': pin.position,
          'title': pin.label,
          'aria-label': '${pin.label}, ${pin.price}',
        },
        [
          Icon('place', size: 'sm'),
          span(classes: 'map-pin__price', [Component.text(pin.price)]),
        ],
      ),
    if (zoom > 1)
      span(classes: 'explore__map-zoom', [Component.text('${zoom}×')]),
  ]);
}
