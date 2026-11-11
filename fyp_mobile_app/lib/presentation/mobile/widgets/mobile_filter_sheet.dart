import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../core/theme/sitewise_m3.dart';
import '../../../core/theme/sitewise_theme.dart';

/// The filter tiles on the Listing screen, plus the "All filters" entry.
///
/// Each value names one *section* of the advanced sheet, so tapping a tile
/// opens the same sheet scrolled to the criteria that tile stands for. There is
/// exactly one filter editor in the mobile tree — the tiles are shortcuts into
/// it, never a second, divergent copy of the rules.
enum MobileFilterSection {
  rent('Monthly rent'),
  area('Floor area'),
  location('Location'),
  propertyType('Property type'),
  verification('Verification and tours'),
  nearby('Nearby activity');

  final String title;
  const MobileFilterSection(this.title);
}

/// What the advanced sheet returns: the shared [PropertyFilter] plus the one
/// criterion that is a *server-side spatial query* rather than a listing
/// attribute, so it cannot live on [PropertyFilter] without pretending to be a
/// local predicate.
class MobileFilterResult {
  final PropertyFilter filter;

  /// `true` sends `min_nearby_properties` to `/explore/properties`.
  final bool nearbyOnly;

  const MobileFilterResult({required this.filter, required this.nearbyOnly});
}

/// Opens the advanced filter sheet.
///
/// Returns `null` when dismissed, otherwise the applied criteria. The caller
/// owns persistence — the sheet never mutates page state directly, so
/// "dismissed" and "applied" stay distinguishable.
///
/// [states] / [cities] / [propertyTypes] / [availability] must be the values the
/// backend actually serves (`GET /explore/options`). An option that matches no
/// row is never offered, because a filter that silently returns nothing reads
/// as a data outage to the user.
Future<MobileFilterResult?> showMobileFilterSheet(
  BuildContext context, {
  required PropertyFilter current,
  required bool nearbyOnly,
  required List<String> states,
  required List<String> cities,
  required List<String> propertyTypes,
  MobileFilterSection? initialSection,

  /// Whether the current result set contains listings that are NOT
  /// admin-verified. When false the "Verified only" switch is shown as already
  /// satisfied instead of pretending to filter.
  bool verificationCanNarrow = true,

  /// Whether the current result set contains at least one published tour.
  /// When false the tour switch is disabled with the reason stated inline.
  bool toursAvailable = false,

  /// Highest asking rent / floor area in the loaded set, used as field hints so
  /// the user is never invited to type a ceiling above the data.
  double? rentCeiling,
  double? sizeCeiling,
}) {
  return showModalBottomSheet<MobileFilterResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: SitewiseColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => _FilterSheet(
      initial: current,
      initialNearby: nearbyOnly,
      states: states,
      cities: cities,
      propertyTypes: propertyTypes,
      initialSection: initialSection,
      verificationCanNarrow: verificationCanNarrow,
      toursAvailable: toursAvailable,
      rentCeiling: rentCeiling,
      sizeCeiling: sizeCeiling,
    ),
  );
}

class _FilterSheet extends StatefulWidget {
  final PropertyFilter initial;
  final bool initialNearby;
  final List<String> states;
  final List<String> cities;
  final List<String> propertyTypes;
  final MobileFilterSection? initialSection;
  final bool verificationCanNarrow;
  final bool toursAvailable;
  final double? rentCeiling;
  final double? sizeCeiling;

  const _FilterSheet({
    required this.initial,
    required this.initialNearby,
    required this.states,
    required this.cities,
    required this.propertyTypes,
    required this.initialSection,
    required this.verificationCanNarrow,
    required this.toursAvailable,
    required this.rentCeiling,
    required this.sizeCeiling,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late PropertyFilter _draft = widget.initial;
  late bool _nearby = widget.initialNearby;

  late final TextEditingController _minRent = _controller(
    widget.initial.minRentalRm,
  );
  late final TextEditingController _maxRent = _controller(
    widget.initial.maxRentalRm,
  );
  late final TextEditingController _minSize = _controller(
    widget.initial.minSizeSqft,
  );
  late final TextEditingController _maxSize = _controller(
    widget.initial.maxSizeSqft,
  );

  final Map<MobileFilterSection, GlobalKey> _sectionKeys = {
    for (final section in MobileFilterSection.values) section: GlobalKey(),
  };

  String? _error;

  static TextEditingController _controller(double? value) =>
      TextEditingController(text: value == null ? '' : _format(value));

  static String _format(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void initState() {
    super.initState();
    final target = widget.initialSection;
    if (target != null) {
      // One frame for the sheet to lay out, then bring the tapped tile's
      // section into view. Scrolling a sheet the user just opened is expected
      // behaviour; silently opening at the top is not.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _sectionKeys[target]?.currentContext;
        if (ctx == null) return;
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.02,
        );
      });
    }
  }

  @override
  void dispose() {
    _minRent.dispose();
    _maxRent.dispose();
    _minSize.dispose();
    _maxSize.dispose();
    super.dispose();
  }

  /// Text → value. An empty field is "no bound", never zero.
  static double? _value(TextEditingController c) {
    final text = c.text.trim();
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text.replaceAll(',', ''));
    if (parsed == null || parsed < 0) return null;
    return parsed;
  }

  void _recompute() {
    final minRent = _value(_minRent);
    final maxRent = _value(_maxRent);
    final minSize = _value(_minSize);
    final maxSize = _value(_maxSize);

    _draft = PropertyFilter(
      minRentalRm: minRent,
      maxRentalRm: maxRent,
      minSizeSqft: minSize,
      maxSizeSqft: maxSize,
      propertyType: _draft.propertyType,
      city: _draft.city,
      state: _draft.state,
      verifiedOnly: _draft.verifiedOnly,
      hasTourOnly: _draft.hasTourOnly,
    );
    setState(() => _error = _draft.validate());
  }

  void _clearAll() {
    _minRent.clear();
    _maxRent.clear();
    _minSize.clear();
    _maxSize.clear();
    setState(() {
      _draft = PropertyFilter.empty;
      _nearby = false;
      _error = null;
    });
  }

  int get _activeCount => _draft.activeCount + (_nearby ? 1 : 0);

  /// Cities offered for the currently selected state.
  ///
  /// The facet list is global (one `GET /explore/options` call), so it cannot
  /// be narrowed per state without a second request. Instead the two criteria
  /// are ANDed server-side, and picking a new state clears the city so the user
  /// can never hold a state+city pair that matches nothing.
  List<String> get _cityOptions => widget.cities;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.92;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SitewiseColors.borderStrong,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Filter properties',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                  if (_activeCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: SitewiseM3.quiet,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '$_activeCount active',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: SitewiseM3.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: SitewiseColors.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _locationSection(),
                    _rentSection(),
                    _areaSection(),
                    _typeSection(),
                    _verificationSection(),
                    _nearbySection(),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  // --- sections ------------------------------------------------------------

  Widget _locationSection() => _section(
    MobileFilterSection.location,
    title: 'Location',
    subtitle: 'State and city as recorded on the listing.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _miniLabel('State'),
        _chipWrap(
          options: [PropertyFilter.anyState, ...widget.states],
          selected: _draft.state,
          onPick: (v) => setState(() {
            // A city chosen under a different state would AND to zero rows, so
            // changing the state resets the city to "any".
            _draft = _draft.copyWith(state: v, city: PropertyFilter.anyArea);
          }),
        ),
        const SizedBox(height: 12),
        _miniLabel('City'),
        _chipWrap(
          options: [PropertyFilter.anyArea, ..._cityOptions],
          selected: _draft.city,
          onPick: (v) => setState(() => _draft = _draft.copyWith(city: v)),
        ),
      ],
    ),
  );

  Widget _rentSection() => _section(
    MobileFilterSection.rent,
    title: 'Monthly rent',
    subtitle: widget.rentCeiling == null
        ? 'Exact ringgit range per month.'
        : 'Highest asking rent in this set is '
              'RM ${_format(widget.rentCeiling!)} per month.',
    child: _rangeFields(
      minController: _minRent,
      maxController: _maxRent,
      minLabel: 'Minimum',
      maxLabel: 'Maximum',
      prefix: 'RM ',
      suffix: '/mo',
    ),
  );

  Widget _areaSection() => _section(
    MobileFilterSection.area,
    title: 'Floor area',
    subtitle: widget.sizeCeiling == null
        ? 'Built-up area in square feet.'
        : 'Largest built-up area in this set is '
              '${_format(widget.sizeCeiling!)} sq ft.',
    child: _rangeFields(
      minController: _minSize,
      maxController: _maxSize,
      minLabel: 'Minimum',
      maxLabel: 'Maximum',
      suffix: 'sq ft',
    ),
  );

  Widget _typeSection() => _section(
    MobileFilterSection.propertyType,
    title: 'Property type',
    subtitle: 'Types returned by the property service.',
    child: _chipWrap(
      options: [PropertyFilter.anyType, ...widget.propertyTypes],
      selected: _draft.propertyType,
      onPick: (v) => setState(() => _draft = _draft.copyWith(propertyType: v)),
    ),
  );

  Widget _verificationSection() {
    // A switch that is already on must stay operable: availability is only a
    // reason to refuse *turning it on*, never to trap the user in a filter
    // they cannot turn off.
    final canOfferVerified =
        _draft.verifiedOnly || widget.verificationCanNarrow;
    final canOfferTour = _draft.hasTourOnly || widget.toursAvailable;
    return _section(
      MobileFilterSection.verification,
      title: 'Verification and tours',
      subtitle: 'Admin review is separate from imported-data quality checks.',
      child: Column(
        children: [
          _switchRow(
            value: _draft.verifiedOnly,
            label: 'Verified properties only',
            helper: canOfferVerified
                ? 'Only listings reviewed and approved by a SiteWise admin.'
                : 'Every listing currently shown is already admin-verified.',
            enabled: canOfferVerified,
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(verifiedOnly: v)),
          ),
          const SizedBox(height: 6),
          _switchRow(
            value: _draft.hasTourOnly,
            label: '360° tour available',
            helper: canOfferTour
                ? 'Only listings with a published virtual tour.'
                : 'No published 360° tours exist yet, so this cannot narrow '
                      'the list.',
            enabled: canOfferTour,
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(hasTourOnly: v)),
          ),
        ],
      ),
    );
  }

  Widget _nearbySection() => _section(
    MobileFilterSection.nearby,
    title: 'Nearby activity',
    subtitle: 'Counts other published commercial listings, not F&B outlets.',
    child: _switchRow(
      value: _nearby,
      label: 'Only busy clusters (3+ within 500 m)',
      helper:
          'Keeps listings with at least three other published commercial '
          'properties within 500 m. Turn off to see every property.',
      enabled: true,
      onChanged: (v) => setState(() => _nearby = v),
    ),
  );

  // --- building blocks -----------------------------------------------------

  Widget _section(
    MobileFilterSection section, {
    required String title,
    required String subtitle,
    required Widget child,
  }) => Container(
    key: _sectionKeys[section],
    margin: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );

  Widget _miniLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
        color: SitewiseColors.overline,
      ),
    ),
  );

  Widget _chipWrap({
    required List<String> options,
    required String selected,
    required ValueChanged<String> onPick,
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final option in options)
        ChoiceChip(
          label: Text(option),
          selected: option == selected,
          onSelected: (_) => onPick(option),
          selectedColor: SitewiseColors.action,
          backgroundColor: SitewiseColors.surface,
          side: BorderSide(
            color: option == selected
                ? SitewiseColors.action
                : SitewiseColors.border,
          ),
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: option == selected ? Colors.white : SitewiseColors.ink,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          showCheckmark: false,
        ),
    ],
  );

  Widget _rangeFields({
    required TextEditingController minController,
    required TextEditingController maxController,
    required String minLabel,
    required String maxLabel,
    String prefix = '',
    String suffix = '',
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: _numberField(
          controller: minController,
          label: minLabel,
          prefix: prefix,
          suffix: suffix,
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Text('–', style: TextStyle(color: SitewiseColors.muted)),
      ),
      Expanded(
        child: _numberField(
          controller: maxController,
          label: maxLabel,
          prefix: prefix,
          suffix: suffix,
        ),
      ),
    ],
  );

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    String prefix = '',
    String suffix = '',
  }) => TextField(
    controller: controller,
    onChanged: (_) => _recompute(),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      LengthLimitingTextInputFormatter(9),
    ],
    style: const TextStyle(fontSize: 14, color: SitewiseColors.ink),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 12, color: SitewiseColors.muted),
      prefixText: prefix.isEmpty ? null : prefix,
      suffixText: suffix.isEmpty ? null : suffix,
      suffixStyle: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
      isDense: true,
      filled: true,
      fillColor: SitewiseColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: _fieldBorder(SitewiseColors.border),
      enabledBorder: _fieldBorder(SitewiseColors.border),
      focusedBorder: _fieldBorder(SitewiseColors.action, width: 1.4),
    ),
  );

  OutlineInputBorder _fieldBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  Widget _switchRow({
    required bool value,
    required String label,
    required String helper,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) => Semantics(
    label: label,
    hint: helper,
    child: SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: value && enabled,
      onChanged: enabled ? onChanged : null,
      title: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: enabled ? SitewiseColors.ink : SitewiseColors.muted,
        ),
      ),
      subtitle: Text(
        helper,
        style: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
      ),
    ),
  );

  Widget _footer() => Container(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: SitewiseColors.border)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 15,
                  color: SitewiseColors.danger,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: SitewiseColors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _clearAll,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  side: const BorderSide(color: SitewiseColors.border),
                  foregroundColor: SitewiseColors.ink,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Clear filters'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                // Disabled while the range is impossible: applying it would
                // return nothing and look like a data failure.
                onPressed: _error != null
                    ? null
                    : () => Navigator.of(context).pop(
                        MobileFilterResult(filter: _draft, nearbyOnly: _nearby),
                      ),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  backgroundColor: SitewiseColors.action,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  disabledBackgroundColor: SitewiseColors.borderStrong,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  _activeCount == 0 ? 'Apply filters' : 'Apply · $_activeCount',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
