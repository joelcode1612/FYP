import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_evidence_score.dart';
import '../../../shared/widgets/sitewise_factor_row.dart';
import '../../../shared/widgets/sitewise_map_panel.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../../shared/widgets/sitewise_status_badge.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';
import '../../widgets/mobile_property_image.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';
import '../../widgets/mobile_suitability_badge.dart';

/// Mobile property detail — Option A layout over the existing evaluation flow.
///
/// Imagery → identity → price → key facts (with explicit Unknown/Unverified
/// markers) → property information → location insights → 360° tour → actions.
/// **Assess This Property** is the primary action: it carries this
/// `property.id` into the assessment setup route as arguments, so the user
/// never selects the same property twice. Every other action maps to an
/// existing route/state.

class EntrepreneurPropertyDetailMobilePage extends ConsumerStatefulWidget {
  final String propertyId;
  const EntrepreneurPropertyDetailMobilePage({
    super.key,
    required this.propertyId,
  });

  @override
  ConsumerState<EntrepreneurPropertyDetailMobilePage> createState() =>
      _EntrepreneurPropertyDetailMobilePageState();
}

class _EntrepreneurPropertyDetailMobilePageState
    extends ConsumerState<EntrepreneurPropertyDetailMobilePage> {
  /// Resolved once per route (a FutureBuilder created inside `build` would
  /// refetch on every rebuild).
  late Future<CommercialProperty?> _propertyFuture = _loadProperty();

  @override
  void initState() {
    super.initState();
    // The load publishes synchronously; a kick from initState would modify
    // the provider while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(entrepreneurNotifierProvider.notifier)
          .loadAnalysis(widget.propertyId);
    });
  }

  /// Resolves the listing against the SAME authoritative dataset the Explore
  /// list used: the live `/explore/properties/{id}` repository in live mode
  /// (numeric `fyp.rental_properties` ids), the demo store in demo mode. A
  /// 404 from the backend means "not published" and surfaces as the
  /// unavailable state; other failures surface as a retryable error instead
  /// of pretending the property is gone.
  Future<CommercialProperty?> _loadProperty() async {
    final repo = ref.read(exploreRepositoryProvider);
    if (repo != null) {
      try {
        final detail = await repo.detail(widget.propertyId);
        return detail.property;
      } on NotFoundShape {
        return null;
      }
    }
    return ServiceLocator.properties.detail(widget.propertyId);
  }

  void _reload() {
    setState(() => _propertyFuture = _loadProperty());
    // The location insights are a second, independent request — refreshing the
    // listing alone would leave stale analysis next to fresh facts.
    ref.read(entrepreneurNotifierProvider.notifier).loadAnalysis(
      widget.propertyId,
    );
  }

  /// Saves/unsaves against the server first, so the shortlist the Saved tab
  /// reads is the authoritative one. The old `toggleSaved` only moved the
  /// in-memory set: the bookmark looked saved, then disappeared on restart.
  Future<void> _toggleSaved(String id, bool wantSaved) async {
    final messenger = ScaffoldMessenger.of(context);
    final failure = await ref
        .read(appNotifierProvider.notifier)
        .persistSaved(id, wantSaved: wantSaved);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failure ??
              (wantSaved
                  ? 'Saved to your shortlist.'
                  : 'Removed from saved.'),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _open(String route, {Object? arguments}) =>
      Navigator.of(context).pushNamed(route, arguments: arguments);

  @override
  Widget build(BuildContext context) {
    // Two slices, two rebuilds: the entrepreneur state repaints the location
    // insights, the app-wide saved/compare sets repaint the toggles. Watching
    // both here also keeps the page-scoped entrepreneur provider alive for
    // the route's lifetime.
    final appState = ref.watch(appNotifierProvider);
    final model = ref.watch(entrepreneurNotifierProvider);
    return MobileAppShell(
            title: 'Property',
            currentRoute: '/entrepreneur/recommendations',
            actions: [
              IconButton(
                tooltip: 'Refresh property',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _reload,
              ),
            ],
            body: RefreshIndicator(
              color: SitewiseColors.action,
              onRefresh: () async => _reload(),
              child: FutureBuilder<CommercialProperty?>(
              future: _propertyFuture,
              builder: (c, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const MobilePropertyListSkeleton(
                    padding: EdgeInsets.all(16),
                  );
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            readableFailure(
                              snap.error!,
                              fallback:
                                  'We could not load this property. '
                                  'Please try again.',
                            ),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: SitewiseColors.muted,
                            ),
                          ),
                          const SizedBox(height: 14),
                          SitewiseSecondaryButton(
                            label: 'Try again',
                            icon: Icons.refresh_rounded,
                            onPressed: _reload,
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final p = snap.data;
                if (p == null) {
                  return const Center(
                    child: Text('This property is no longer available.'),
                  );
                }
                final saved = appState.saved.contains(p.id);
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 122),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    _hero(p, saved),
                    const SizedBox(height: 16),
                    _identity(p),
                    const SizedBox(height: 18),
                    _keyFacts(p),
                    const SizedBox(height: 22),
                    const MobileSectionHeader(
                      title: 'Location insights',
                      subtitle: 'What surrounds this property.',
                    ),
                    const SizedBox(height: 12),
                    _insights(p, model),
                    if (p.hasTour) ...[
                      const SizedBox(height: 18),
                      SitewiseSecondaryButton(
                        label: 'View 360° tour',
                        icon: Icons.threesixty_rounded,
                        onPressed: () =>
                            _open('/entrepreneur/tour', arguments: p.id),
                      ),
                    ],
                    const SizedBox(height: 22),
                    const M3Banner(
                      text:
                          'Evaluate this property for your own business. '
                          'Survey and location analysis are linked separately '
                          'when available.',
                    ),
                    const SizedBox(height: 18),
                    M3PrimaryButton(
                      label: 'Assess this property',
                      onTap: () => _open(
                        '/entrepreneur/assessment-setup',
                        arguments: p.id,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _actions(p, saved),
                    const SizedBox(height: 8),
                    SitewiseSecondaryButton(
                      label: 'Back to listings',
                      icon: Icons.arrow_back_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                );
              },
              ),
            ),
    );
  }

  Widget _hero(CommercialProperty p, bool saved) => Stack(
    children: [
      MobilePropertyImage(
        property: p,
        height: 210,
        width: double.infinity,
        borderRadius: BorderRadius.circular(18),
        badge: p.hasTour ? '360° tour' : null,
      ),
      Positioned(
        top: 10,
        right: 10,
        child: Material(
          color: SitewiseColors.surface.withValues(alpha: 0.94),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _toggleSaved(p.id, !saved),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                size: 20,
                color: saved ? SitewiseColors.action : SitewiseColors.ink,
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _identity(CommercialProperty p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              p.title,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
                height: 1.2,
                letterSpacing: -0.4,
              ),
            ),
          ),
          if (p.verification == VerificationStatus.verified)
            SitewiseStatusBadge.forVerification(p.verification),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          const Icon(
            Icons.place_outlined,
            size: 14,
            color: SitewiseColors.muted,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${p.address}, ${p.postcode} ${p.city}, ${p.state}',
              style: const TextStyle(
                fontSize: 12.5,
                color: SitewiseColors.muted,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              // SQL NULL rent arrives as 0; a real listing is never RM 0,
              // so the zero renders as "not listed" rather than a price.
              p.rentalRm > 0 ? p.rentalDisplay : 'Rent on request',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.action,
                height: 1.1,
              ),
            ),
          ),
          if (p.rentalRm > 0)
            const Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Text(
                '/ month',
                style: TextStyle(fontSize: 12.5, color: SitewiseColors.muted),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      if (p.hasSuitabilityScore) ...[
        MobileSuitabilityBadge(score: p.suitabilityScore),
        const SizedBox(height: 4),
        const Text(
          'Location suitability for your business.',
          style: TextStyle(fontSize: 11, color: SitewiseColors.muted),
        ),
      ] else ...[
        const Text(
          'Suitability: not scored yet',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.muted,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'This listing has no research suitability index yet.',
          style: TextStyle(fontSize: 11, color: SitewiseColors.muted),
        ),
      ],
    ],
  );

  Widget _keyFacts(CommercialProperty p) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SitewiseColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SitewiseColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Property information',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _Fact(
                label: 'Floor area',
                value: p.sizeSqft > 0
                    ? '${p.sizeSqft.toStringAsFixed(0)} sq ft'
                    : 'Not listed',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Fact(label: 'Unit type', value: p.propertyType),
            ),
            const SizedBox(width: 12),
            // The repository carries no F&B licensing data — the Option A
            // marker stays honestly "Unknown" rather than guessed.
            const Expanded(
              child: _Fact(label: 'F&B approval', value: 'Unknown'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _Fact(
                label: 'Rental efficiency',
                // Dividing a placeholder 0 rent or 0 size would print
                // "RM 0.00 / sq ft" — the honest marker is "Not computable".
                value: p.rentalRm > 0 && p.sizeSqft > 0
                    ? 'RM${p.rentalPerSqft.toStringAsFixed(2)} / sq ft'
                    : 'Not computable',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Fact(
                label: 'Verification',
                value: p.verification == VerificationStatus.verified
                    ? 'Verified'
                    : 'Unverified',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Fact(
                label: '360° tour',
                value: p.hasTour ? 'Available' : 'Not yet',
              ),
            ),
          ],
        ),
        if (p.requirements.isNotEmpty) ...[
          const Divider(height: 26),
          const Text(
            'Meets your requirements',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final r in p.requirements) _Tag(r, positive: true)],
          ),
        ],
        if (p.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final t in p.tags) _Tag(t)],
          ),
        ],
        const SizedBox(height: 12),
        Text(
          AppConfig.usesDemoData
              ? 'Floor area and price are sample data in this build and '
                    'require verification.'
              : 'Floor area and price are provided per listing and require '
                    'verification.',
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 10.5,
            height: 1.5,
            color: SitewiseColors.muted,
          ),
        ),
      ],
    ),
  );

  Widget _insights(CommercialProperty p, EntrepreneurState model) {
    // The state owner keeps the last analysis it loaded. If the user opened a
    // different property, that analysis belongs to the OTHER listing — showing
    // it here would attribute one unit's research figures to another.
    final a = model.analysisPropertyId == p.id ? model.analysis : null;
    final error = model.analysisPropertyId == p.id ? model.analysisError : null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SitewiseMapPanel(
            height: 190,
            pins: [
              MapPin(
                id: p.id,
                label: p.title,
                latitude: p.latitude,
                longitude: p.longitude,
                highlighted: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (model.analysisLoading && a == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: MobileSkeletonBox(height: 14, width: 180),
            )
          else if (a != null) ...[
            SitewiseEvidenceScore(score: a.suitabilityScore),
            const Divider(height: 26),
            Text(
              a.demandSummary,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: SitewiseColors.muted,
              ),
            ),
            const Divider(height: 26),
            const Text(
              'Why this location scores this way',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            for (final f in a.factors) SitewiseFactorRow(factor: f),
          ] else if (error != null)
            // A failed analysis read is a failure, not "no analysis exists":
            // say so and offer the real retry.
            Row(
              children: [
                Expanded(
                  child: Text(
                    error,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: SitewiseColors.danger,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => ref
                      .read(entrepreneurNotifierProvider.notifier)
                      .loadAnalysis(p.id),
                  child: const Text('Retry', style: TextStyle(fontSize: 12)),
                ),
              ],
            )
          else
            const Text(
              'Location analysis is unavailable for this property.',
              style: TextStyle(fontSize: 12.5, color: SitewiseColors.muted),
            ),
        ],
      ),
    );
  }

  Widget _actions(CommercialProperty p, bool saved) {
    final compared = ref
        .read(appNotifierProvider)
        .compared
        .contains(p.id);
    return Column(
      children: [
        SitewiseButton(
          label: saved ? 'Saved ✓' : 'Save property',
          icon: saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          onPressed: () => _toggleSaved(p.id, !saved),
        ),
        const SizedBox(height: 8),
        SitewiseSecondaryButton(
          label: compared ? 'In comparison ✓' : 'Add to compare',
          icon: Icons.compare_arrows,
          onPressed: () {
            ref.read(appNotifierProvider.notifier).toggleCompared(p.id);
            _open('/entrepreneur/compare');
          },
        ),
        const SizedBox(height: 8),
        SitewiseSecondaryButton(
          label: 'Generate evaluation report',
          icon: Icons.description_outlined,
          onPressed: () => _open('/entrepreneur/report', arguments: p.id),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 10.5, color: SitewiseColors.muted),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: SitewiseColors.ink,
          height: 1.25,
        ),
      ),
    ],
  );
}

class _Tag extends StatelessWidget {
  final String label;
  final bool positive;

  const _Tag(this.label, {this.positive = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: positive ? const Color(0xFFD3F8DF) : SitewiseColors.geoWash,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (positive) ...[
          const Icon(
            Icons.check_rounded,
            size: 12,
            color: SitewiseColors.success,
          ),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: positive ? SitewiseColors.success : SitewiseColors.accent,
          ),
        ),
      ],
    ),
  );
}
