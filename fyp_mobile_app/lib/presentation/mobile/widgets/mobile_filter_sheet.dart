import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_bottom_sheet.dart';

/// Presentation-level refinement applied to the properties the ViewModel /
/// repository already returned. It does not fetch or invent data — it only
/// narrows the visible list using fields that exist on [CommercialProperty].

class MobilePropertyFilter {
  final String propertyType;
  final String city;
  final double? maxBudgetRm;
  final double? minSizeSqft;
  final bool verifiedOnly;

  /// Listing availability facet (`GET /explore/options`), applied server-side
  /// in live mode. Null = any. Demo mode matches the field locally.
  final String? availability;

  const MobilePropertyFilter({
    this.propertyType = allTypes,
    this.city = allAreas,
    this.maxBudgetRm,
    this.minSizeSqft,
    this.verifiedOnly = false,
    this.availability,
  });

  static const String allTypes = 'All';
  static const String allAreas = 'All areas';
  static const String anyAvailability = 'Any';

  static const MobilePropertyFilter empty = MobilePropertyFilter();

  bool get isActive =>
      propertyType != allTypes ||
      city != allAreas ||
      maxBudgetRm != null ||
      minSizeSqft != null ||
      verifiedOnly ||
      (availability != null && availability != anyAvailability);

  int get activeCount {
    var n = 0;
    if (propertyType != allTypes) n++;
    if (city != allAreas) n++;
    if (maxBudgetRm != null) n++;
    if (minSizeSqft != null) n++;
    if (verifiedOnly) n++;
    if (availability != null && availability != anyAvailability) n++;
    return n;
  }

  bool matches(CommercialProperty p) {
    if (propertyType != allTypes && p.propertyType != propertyType) {
      return false;
    }
    if (city != allAreas && p.city != city) return false;
    if (maxBudgetRm != null && p.rentalRm > maxBudgetRm!) return false;
    if (minSizeSqft != null && p.sizeSqft < minSizeSqft!) return false;
    if (availability != null &&
        availability != anyAvailability &&
        p.availability != availability) {
      return false;
    }
    if (verifiedOnly && p.verification != VerificationStatus.verified) {
      return false;
    }
    return true;
  }

  MobilePropertyFilter copyWith({
    String? propertyType,
    String? city,
    double? maxBudgetRm,
    bool clearMaxBudget = false,
    double? minSizeSqft,
    bool clearMinSize = false,
    bool? verifiedOnly,
    String? availability,
    bool clearAvailability = false,
  }) => MobilePropertyFilter(
    propertyType: propertyType ?? this.propertyType,
    city: city ?? this.city,
    maxBudgetRm: clearMaxBudget ? null : (maxBudgetRm ?? this.maxBudgetRm),
    minSizeSqft: clearMinSize ? null : (minSizeSqft ?? this.minSizeSqft),
    verifiedOnly: verifiedOnly ?? this.verifiedOnly,
    availability: clearAvailability
        ? null
        : (availability ?? this.availability),
  );
}

/// Opens the mobile filter bottom sheet.
///
/// Returns the applied filter, [MobilePropertyFilter.empty] when the user taps
/// Clear, or `null` when dismissed without applying.
///
/// [availability] supplies the server's availability facet; when null the
/// availability row is not shown (a chip whose rule cannot apply to the
/// dataset must not be offered). [showVerifiedToggle] hides the
/// "verified only" switch where every served row is already approved —
/// the live explore dataset — so the toggle can never pretend to filter.
Future<MobilePropertyFilter?> showMobilePropertyFilterSheet(
  BuildContext context, {
  required MobilePropertyFilter current,
  required List<String> propertyTypes,
  required List<String> cities,
  double budgetCeiling = 15000,
  double sizeCeiling = 3000,
  bool showVerifiedToggle = true,
  List<String>? availability,
}) {
  return showSitewiseBottomSheet<MobilePropertyFilter>(
    context,
    title: 'Filter properties',
    builder: (ctx) => _FilterSheetBody(
      initial: current,
      propertyTypes: propertyTypes,
      cities: cities,
      budgetCeiling: budgetCeiling,
      sizeCeiling: sizeCeiling,
      showVerifiedToggle: showVerifiedToggle,
      availability: availability,
    ),
  );
}

class _FilterSheetBody extends StatefulWidget {
  final MobilePropertyFilter initial;
  final List<String> propertyTypes;
  final List<String> cities;
  final double budgetCeiling;
  final double sizeCeiling;
  final bool showVerifiedToggle;
  final List<String>? availability;

  const _FilterSheetBody({
    required this.initial,
    required this.propertyTypes,
    required this.cities,
    required this.budgetCeiling,
    required this.sizeCeiling,
    this.showVerifiedToggle = true,
    this.availability,
  });

  @override
  State<_FilterSheetBody> createState() => _FilterSheetBodyState();
}

class _FilterSheetBodyState extends State<_FilterSheetBody> {
  late MobilePropertyFilter draft = widget.initial;
  late double _budget = widget.initial.maxBudgetRm ?? widget.budgetCeiling;
  late double _size = widget.initial.minSizeSqft ?? 200;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _groupLabel('Property type'),
        _chipWrap(
          options: [MobilePropertyFilter.allTypes, ...widget.propertyTypes],
          selected: draft.propertyType,
          onPick: (v) =>
              setState(() => draft = draft.copyWith(propertyType: v)),
        ),
        const SizedBox(height: 18),
        _groupLabel('Area'),
        _chipWrap(
          options: [MobilePropertyFilter.allAreas, ...widget.cities],
          selected: draft.city,
          onPick: (v) => setState(() => draft = draft.copyWith(city: v)),
        ),
        if (widget.availability != null &&
            widget.availability!.isNotEmpty) ...[
          const SizedBox(height: 18),
          _groupLabel('Availability'),
          _chipWrap(
            options: [
              MobilePropertyFilter.anyAvailability,
              ...widget.availability!,
            ],
            selected: draft.availability ?? MobilePropertyFilter.anyAvailability,
            onPick: (v) => setState(
              () => draft = draft.copyWith(
                availability: v == MobilePropertyFilter.anyAvailability
                    ? null
                    : v,
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        _sliderRow(
          label: 'Max monthly rent',
          value: draft.maxBudgetRm == null
              ? 'Any'
              : 'RM ${draft.maxBudgetRm!.toStringAsFixed(0)}',
          onAny: () => setState(() {
            draft = draft.copyWith(clearMaxBudget: true);
            _budget = widget.budgetCeiling;
          }),
        ),
        Slider(
          min: 2000,
          max: widget.budgetCeiling,
          divisions: 26,
          value: _budget.clamp(2000.0, widget.budgetCeiling).toDouble(),
          label: 'RM ${_budget.toStringAsFixed(0)}',
          onChanged: (v) => setState(() {
            _budget = v;
            draft = draft.copyWith(maxBudgetRm: v);
          }),
        ),
        _sliderRow(
          label: 'Min floor area',
          value: draft.minSizeSqft == null
              ? 'Any'
              : '${draft.minSizeSqft!.toStringAsFixed(0)} sq ft',
          onAny: () => setState(() {
            draft = draft.copyWith(clearMinSize: true);
            _size = 200;
          }),
        ),
        Slider(
          min: 200,
          max: widget.sizeCeiling,
          divisions: 14,
          value: _size.clamp(200.0, widget.sizeCeiling).toDouble(),
          label: '${_size.toStringAsFixed(0)} sq ft',
          onChanged: (v) => setState(() {
            _size = v;
            draft = draft.copyWith(minSizeSqft: v);
          }),
        ),
        if (widget.showVerifiedToggle)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: draft.verifiedOnly,
            title: const Text(
              'Verified properties only',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'Show only listings reviewed by Sitewise',
              style: TextStyle(fontSize: 11.5),
            ),
            onChanged: (v) =>
                setState(() => draft = draft.copyWith(verifiedOnly: v)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () =>
                    Navigator.of(context).pop(MobilePropertyFilter.empty),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  side: const BorderSide(color: SitewiseColors.border),
                  foregroundColor: SitewiseColors.ink,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Clear'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(draft),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  backgroundColor: SitewiseColors.action,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Apply filters'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _groupLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: SitewiseColors.ink,
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
          labelStyle: TextStyle(
            fontSize: 12.5,
            color: option == selected ? Colors.white : SitewiseColors.ink,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: option == selected
                  ? SitewiseColors.action
                  : SitewiseColors.border,
            ),
          ),
        ),
    ],
  );

  Widget _sliderRow({
    required String label,
    required String value,
    required VoidCallback onAny,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.ink,
          ),
        ),
      ),
      Text(
        value,
        style: const TextStyle(fontSize: 12, color: SitewiseColors.muted),
      ),
      TextButton(
        onPressed: onAny,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('Any', style: TextStyle(fontSize: 12)),
      ),
    ],
  );
}
