import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_button.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_evidence_score.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_factor_row.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_map_panel.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_secondary_button.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_status_badge.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'package:fyp/shared/presentation/components/m3_kit.dart';
import 'package:fyp/shared/presentation/components/mobile_property_gallery.dart';
import 'package:fyp/features/assessment/presentation/widgets/mobile_insights_panel.dart';
import 'package:fyp/shared/presentation/components/mobile_section_header.dart';
import 'package:fyp/shared/presentation/components/mobile_skeleton.dart';
import 'package:fyp/shared/presentation/components/mobile_suitability_badge.dart';
import 'package:fyp/core/routing/app_routes.dart';

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
  final String? resultId;
  const EntrepreneurPropertyDetailMobilePage({
    super.key,
    required this.propertyId,
    this.resultId,
  });

  @override
  ConsumerState<EntrepreneurPropertyDetailMobilePage> createState() =>
      _EntrepreneurPropertyDetailMobilePageState();
}

class _EntrepreneurPropertyDetailMobilePageState
    extends ConsumerState<EntrepreneurPropertyDetailMobilePage> {
  /// Resolved once per route (a FutureBuilder created inside `build` would
  /// refetch on every rebuild).
  late Future<_PropertyRecord?> _propertyFuture = _loadProperty();

  /// Real location insights for this catalogue property: the deployed model's
  /// score and its SHAP decomposition. `null` when the backend cannot score the
  /// listing, in which case the older assessment-derived block is shown instead
  /// — the two scoring systems are never merged into one number.
  late final Future<PropertyInsightsModel?> _insightsFuture =
      ApiPropertyInsightsRepository(ServiceLocator.apiClient).fetch(widget.propertyId);

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

  /// Resolves the listing in whichever id space the entry point carried, and
  /// brings back the whole photo set with it.
  ///
  /// Two id universes reach this route. The ranked recommendations and the AI
  /// workspace carry the canonical research id (`EP-`/`MD-`), which only
  /// `/catalog/properties/{id}` can address; Explore, Spaces and Saved carry
  /// the numeric `fyp.rental_properties` id, which only
  /// `/explore/properties/{id}` can address and which FastAPI refuses outright
  /// on the catalogue route's shape. The catalogue is therefore read first:
  /// a numeric id simply is not a catalogue row, and
  /// `ApiPropertyRepository.getPropertyById` maps that 404 to `null` while a
  /// genuine service failure still throws — so an outage stays a retryable
  /// error instead of degrading into "no longer available".
  ///
  /// Photos ride back with the record rather than a second request:
  /// `/explore/...` returns them as `detail.photos`, the catalogue mapper as
  /// `property.imageUrls`, each already ordered primary-first server-side.
  Future<_PropertyRecord?> _loadProperty() async {
    final id = widget.propertyId;
    if (id.isEmpty) return null;
    // Read before the first await: the route may pop while the catalogue
    // request is in flight, and `ref` is dead afterwards.
    final explore = ref.read(exploreRepositoryProvider);
    final catalog = await ServiceLocator.properties.detail(id);
    if (catalog != null) {
      return _PropertyRecord(property: catalog, photos: catalog.imageUrls);
    }
    if (explore == null || int.tryParse(id) == null) return null;
    try {
      final detail = await explore.detail(id);
      return _PropertyRecord(
        property: detail.property,
        photos: [for (final photo in detail.photos) photo.url],
      );
    } on NotFoundShape {
      // 404 here means "exists but not approved+published", which is
      // indistinguishable from absent for an entrepreneur by design.
      return null;
    }
  }

  void _reload() {
    setState(() => _propertyFuture = _loadProperty());
    // The location insights are a second, independent request — refreshing the
    // listing alone would leave stale analysis next to fresh facts.
    ref.read(entrepreneurNotifierProvider.notifier).loadAnalysis(
      widget.propertyId,
    );
  }

  /// Saves/unsaves against the server first, so the list the Favourites tab
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
                  ? 'Added to favourites.'
                  : 'Removed from favourites.'),
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
              child: FutureBuilder<_PropertyRecord?>(
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
                final record = snap.data;
                if (record == null) {
                  return const Center(
                    child: Text('This property is no longer available.'),
                  );
                }
                final p = record.property;
                final saved = appState.saved.contains(p.id);
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 122),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    _heroWithPanorama(p, record.photos, saved),
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
                      // The feature questionnaire owns Start/Resume; a
                      // property id is not an assessment draft id.
                      onTap: () => _open(AppRoutes.assessmentHome),
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

  /// Media block over the house gallery: every photograph the record returned,
  /// primary first, with the fullscreen viewer behind the counter and the
  /// saved toggle on top.
  ///
  /// [panoramaUrl] only ever arrives as the backend's `ready` panorama, so the
  /// chip is the single 360° entry and it always routes to the spherical
  /// viewer — the gallery never paints an equirectangular frame as a flat
  /// photo. A listing with no panorama gets no chip rather than a dead
  /// control, and the owner-captured device tour keeps its own button below,
  /// because that is a different record read from device storage.
  Widget _hero(
    CommercialProperty p,
    List<String> photos,
    bool saved,
    String? panoramaUrl,
  ) =>
      MobilePropertyGallery(
        property: p,
        urls: photos,
        borderRadius: BorderRadius.circular(18),
        bookmarkButton: Semantics(
          button: true,
          label: saved ? 'Remove from favourites' : 'Save property',
          child: Material(
            color: SitewiseColors.surface.withValues(alpha: 0.94),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _toggleSaved(p.id, !saved),
              // 44x44: the accessibility floor for a touch target.
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  saved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 20,
                  color: saved ? SitewiseColors.action : SitewiseColors.ink,
                ),
              ),
            ),
          ),
        ),
        tourAction: panoramaUrl == null
            ? null
            : _PanoramaChip(
                label: p.title,
                onTap: () => _open(
                  '/entrepreneur/panorama',
                  arguments: {'url': panoramaUrl, 'title': p.title},
                ),
              ),
      );

  /// The hero waits on the insights read for one reason: the 360° chip.
  ///
  /// It shares `_insightsFuture` with the location card and the 360° fact cell
  /// — the future memoizes, so three readers cost one request and the chip and
  /// the fact cell cannot disagree about whether a panorama exists.
  Widget _heroWithPanorama(
    CommercialProperty p,
    List<String> photos,
    bool saved,
  ) => FutureBuilder<PropertyInsightsModel?>(
    future: _insightsFuture,
    builder: (context, snap) =>
        _hero(p, photos, saved, snap.data?.panorama.readyUrl),
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
            // The same promise as the 360° chip on the media above, so the
            // same evidence: a stitched research panorama and a
            // device-captured tour are two sources of one 360° view, and
            // reading `hasTour` alone printed "Not yet" while the chip
            // below it opened a working viewer.
            Expanded(
              child: FutureBuilder<PropertyInsightsModel?>(
                future: _insightsFuture,
                builder: (context, snap) => _Fact(
                  label: '360° view',
                  value: _tourState(p, snap),
                ),
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
          FutureBuilder<PropertyInsightsModel?>(
            future: _insightsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: MobileSkeletonBox(height: 14, width: 180),
                );
              }
              final insights = snapshot.data;
              // A scored property always uses the model's own explanation. The
              // assessment block below is a DIFFERENT scoring system, so it is
              // only shown when Location Fit itself is unavailable — the two
              // are never blended into one number.
              if (insights != null) return MobileInsightsPanel(insights: insights);
              return _assessmentBlock(p, model, a, error);
            },
          ),
        ],
      ),
    );
  }

  /// Wording for the 360° fact cell, across every state the insights read can
  /// land in.
  ///
  /// A settled `null` means the request FAILED, not that no panorama exists —
  /// so it earns the same honest marker F&B approval uses, and only a
  /// completed read that actually said "no panorama" says "Not yet". The
  /// device tour still answers on its own when insights are unavailable.
  String _tourState(
    CommercialProperty p,
    AsyncSnapshot<PropertyInsightsModel?> snap,
  ) {
    if (snap.connectionState != ConnectionState.done) return 'Checking…';
    if (p.hasTour || snap.data?.panorama.readyUrl != null) return 'Available';
    return snap.data == null ? 'Unknown' : 'Not yet';
  }

  /// Fallback when the insights endpoint returns nothing.
  ///
  /// This is the assessment-derived block that predates the Location Fit
  /// index. It is kept so a listing without a verified model link still shows
  /// what the system knows, but it is never mixed with the model's score.
  Widget _assessmentBlock(
    CommercialProperty p,
    EntrepreneurState model,
    LocationAnalysis? a,
    String? error,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
    );
  }

  /// Compare entry point from Property Details.
  ///
  /// * already selected → Compare opens and the property stays selected;
  /// * not selected with room → it is added first, then Compare opens;
  /// * shortlist full → an understandable message, nothing changes.
  void _compareAction(String id) {
    final app = ref.read(appNotifierProvider.notifier);
    if (app.compared.contains(id)) {
      _open('/entrepreneur/compare');
      return;
    }
    if (!app.addCompared(id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'You can compare up to three properties. Remove one from the '
            'comparison first.',
          ),
        ),
      );
      return;
    }
    _open('/entrepreneur/compare');
  }

  Widget _actions(CommercialProperty p, bool saved) {
    // Watched (not read once): adding/removing here repaints this button too.
    final compared = ref
        .watch(appNotifierProvider.select((app) => app.compared))
        .contains(p.id);
    return Column(
      children: [
        SitewiseButton(
          label: saved ? 'Remove from favourites' : 'Save property',
          icon: saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          onPressed: () => _toggleSaved(p.id, !saved),
        ),
        const SizedBox(height: 8),
        // Opening Compare NEVER removes the selection. Already selected →
        // open directly; not selected → add then open; a full shortlist is
        // explained instead of silently doing nothing.
        SitewiseSecondaryButton(
          label: compared ? 'Open comparison ✓' : 'Add to compare',
          icon: Icons.compare_arrows,
          onPressed: () => _compareAction(p.id),
        ),
      ],
    );
  }
}

/// The 360° overlay on the media block, matching the chip the ranked cards
/// supply to the same gallery.
///
/// Private to this page for the same reason `_IconToggle` and `_RankBadge` are
/// private to theirs: it is four lines of chrome whose meaning is fixed by the
/// backend's `ready` panorama state, not a component with independent
/// callers. Only the verified URL gets one; a pending or failed stitching job
/// must not offer a view that cannot paint.
class _PanoramaChip extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const _PanoramaChip({required this.onTap, required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open 360° panorama view of $label',
      child: Material(
        color: SitewiseColors.ink.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: const SizedBox(
            height: 44,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.threesixty_rounded,
                    size: 19,
                    color: Colors.white,
                  ),
                  SizedBox(width: 6),
                  Text(
                    '360° View',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One resolved listing plus the photographs the backend sent with it.
///
/// The photo set arrives differently per source — `ExplorePropertyDetail
/// .photos` for a numeric listing, `CommercialProperty.imageUrls` for a
/// catalogue row — and only the record that answered knows which. Carrying it
/// beside the entity keeps the gallery from guessing.
class _PropertyRecord {
  final CommercialProperty property;
  final List<String> photos;

  const _PropertyRecord({required this.property, required this.photos});
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
