// SiteWise mobile property-detail focused UI patch (joel branch)
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fyp/features/recommendations/application/personalised_recommendations_providers.dart';
import 'package:fyp/core/di/property_evidence_providers.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_evidence_score.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_factor_row.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_secondary_button.dart';
import 'package:fyp/shared/presentation/components/mobile_property_gallery.dart';
import 'package:fyp/features/assessment/presentation/widgets/mobile_insights_panel.dart';
import 'package:fyp/shared/presentation/components/mobile_skeleton.dart';
import 'package:fyp/features/listing/presentation/widgets/business_concept_panel.dart';

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
  late Future<PropertyInsightsModel?> _insightsFuture = _loadInsights();

  Future<PropertyInsightsModel?> _loadInsights() =>
      ApiPropertyInsightsRepository(ServiceLocator.apiClient).fetch(widget.propertyId);


  /// The approved/public-schema tour is independent of the research insights.
  /// The backend resolves EP-/MD- IDs via verified subject links.


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
    setState(() {
      _propertyFuture = _loadProperty();
      _insightsFuture = _loadInsights();
    });
    ref.read(entrepreneurNotifierProvider.notifier).loadAnalysis(widget.propertyId);
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

  // Tabs follow Jaspr property_detail_page.dart. Only tab content is
  // switched: the surrounding-area section stays visible across tabs.
  int _webTab = 0;

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appNotifierProvider);
    final model = ref.watch(entrepreneurNotifierProvider);
    return Scaffold(
      backgroundColor: SitewiseColors.background,
      appBar: AppBar(
        backgroundColor: SitewiseColors.surface,
        foregroundColor: SitewiseColors.ink,
        surfaceTintColor: SitewiseColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Property details', style: TextStyle(
          fontFamily: kFontFamily, fontWeight: FontWeight.w700, fontSize: 18,
          color: SitewiseColors.ink,
        )),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        actions: [
          FutureBuilder<_PropertyRecord?>(
            future: _propertyFuture,
            builder: (context, snap) {
              final p = snap.data?.property;
              if (p == null) return const SizedBox(width: 48);
              final saved = appState.saved.contains(p.id);
              return IconButton(
                tooltip: saved ? 'Remove from favourites' : 'Save property',
                onPressed: () => _toggleSaved(p.id, !saved),
                icon: Icon(saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                  color: saved ? SitewiseColors.action : SitewiseColors.ink),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: FutureBuilder<_PropertyRecord?>(
        future: _propertyFuture,
        builder: (context, snap) => snap.data == null
            ? const SizedBox.shrink()
            : _bottomActions(snap.data!.property),
      ),
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: () async {
          _reload();
          await _propertyFuture;
        },
        child: FutureBuilder<_PropertyRecord?>(
          future: _propertyFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const MobilePropertyListSkeleton(padding: EdgeInsets.all(16));
            }
            if (snap.hasError) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(children: [
                    Text(readableFailure(snap.error!, fallback: 'Could not load this property.'),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    SitewiseSecondaryButton(label: 'Try again', icon: Icons.refresh,
                        onPressed: _reload),
                  ]),
                )],
              );
            }
            final record = snap.data;
            if (record == null) {
              return ListView(children: const [Padding(
                padding: EdgeInsets.all(24),
                child: Text('This property is no longer available.'),
              )]);
            }
            final p = record.property;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              children: [
                // The web's title, combined gallery, summary and listing facts.
                _webTitle(p),
                const SizedBox(height: 16),
                _heroWithPanorama(p, record.photos),
                const SizedBox(height: 18),
                _webPriceAndScore(p),
                const SizedBox(height: 16),
                _keyFacts(p),
                const SizedBox(height: 14),
                _webManagement(p),
                const SizedBox(height: 14),
                _webDetails(p),
                const SizedBox(height: 24),
                // Always visible: switching tabs must not reset map context.
                _webSurroundings(p),
                const SizedBox(height: 20),
                BusinessConceptPanel(propertyId: p.id),
                const SizedBox(height: 28),
                const Text('Explore this property', style: TextStyle(
                  color: SitewiseColors.action, fontWeight: FontWeight.w700,
                  fontSize: 13,
                )),
                const SizedBox(height: 5),
                const Text('Understand why this property fits your needs',
                  style: TextStyle(color: SitewiseColors.ink,
                    fontWeight: FontWeight.w800, fontSize: 21, height: 1.25)),
                const SizedBox(height: 8),
                const Text('Review your business match, the area score and nearby services.',
                  style: TextStyle(color: SitewiseColors.muted, height: 1.45, fontSize: 14)),
                const SizedBox(height: 14),
                _webTabs(),
                const SizedBox(height: 16),
                if (_webTab == 0) _webBusinessMatch(p),
                if (_webTab == 1) _webScore(p, model),
                if (_webTab == 2) _webNearby(p),
                const SizedBox(height: 24),
                _webBeforeYouDecide(p),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
      ),
    );
  }

  // Web parity: title and availability before the combined photo gallery.
  Widget _webTitle(CommercialProperty p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('COMMERCIAL PROPERTY', style: TextStyle(
        color: SitewiseColors.action, fontSize: 12,
        fontWeight: FontWeight.w700, letterSpacing: 0.7)),
      const SizedBox(height: 6),
      Text(p.title, style: const TextStyle(fontFamily: kFontFamily,
        color: SitewiseColors.ink, fontSize: 22, height: 1.2,
        fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.place_outlined, color: SitewiseColors.muted, size: 18),
        const SizedBox(width: 6),
        Expanded(child: Text(_displayAddress(p), style: const TextStyle(
          color: SitewiseColors.muted, fontSize: 14, height: 1.5))),
      ]),
    ],
  );

  // Keep the listing asking rent separate from model-specific suitability.
  // The live PU score and SHAP appear ONLY in "Why this area score?" below.
  Widget _webPriceAndScore(CommercialProperty p) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SitewiseColors.surface,
      border: Border.all(color: SitewiseColors.border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('MONTHLY RENT', style: TextStyle(fontSize: 12,
        color: SitewiseColors.muted, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
        Text(p.rentalRm > 0 ? p.rentalDisplay : 'Rent on request',
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800,
            color: SitewiseColors.action)),
        if (p.rentalRm > 0) const Text('/ month', style: TextStyle(
          fontSize: 14, color: SitewiseColors.muted)),
      ]),
    ]),
  );

  Widget _webManagement(CommercialProperty p) {
    final management = p.managerName == null || p.managerName!.trim().isEmpty
        ? p.managementLabel : '${p.managementLabel} — ${p.managerName}';
    final features = <String>[
      if (p.hasParking == true) 'Parking',
      if (p.isFnbSuitable == true) 'Recorded as F&B suitable',
      if (p.isCornerLot == true) 'Corner lot',
      if (p.isFreehold == true) 'Freehold',
      if (p.furnishing?.trim().isNotEmpty == true) p.furnishing!.trim(),
      if (p.tenure?.trim().isNotEmpty == true) p.tenure!.trim(),
    ];
    final desc = p.description?.trim() ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Property management', style: TextStyle(
          color: SitewiseColors.muted, fontSize: 13)),
        const SizedBox(height: 4),
        Text(management.trim().isEmpty ? 'Not provided' : management,
          style: const TextStyle(color: SitewiseColors.ink, fontWeight: FontWeight.w700,
            fontSize: 15)),
        if (features.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Property features', style: TextStyle(
            color: SitewiseColors.ink, fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final value in features) Chip(label: Text(value),
              backgroundColor: SitewiseColors.infoWash,
              side: const BorderSide(color: SitewiseColors.border)),
          ]),
        ],
        if (desc.isNotEmpty) ...[
          const Divider(height: 24, color: SitewiseColors.border),
          Text(desc, style: const TextStyle(
            color: SitewiseColors.text, fontSize: 14, height: 1.5)),
        ],
        const SizedBox(height: 10),
        TextButton.icon(
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('Copy summary'),
          onPressed: () async {
            final text = '${p.title}\n${_displayAddress(p)}\n'
                '${p.rentalRm > 0 ? p.rentalDisplay : 'Rent on request'} / month';
            await Clipboard.setData(ClipboardData(text: text));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Property summary copied.')));
          },
        ),
      ]),
    );
  }

  Widget _webDetails(CommercialProperty p) {
    String? recorded(String? s) => s?.trim().isNotEmpty == true ? s!.trim() : null;
    String? sqft(double? n) => n == null ? null : '${n.toStringAsFixed(0)} sq ft';
    String? feet(double? n) => n == null ? null : '${n.toStringAsFixed(0)} ft';
    final data = <(String, String?)>[
      if (p.sizeSqft > 0) ('Space size', sqft(p.sizeSqft)),
      ('Built-up area', sqft(p.builtUpSqft)),
      ('Land area', sqft(p.landAreaSqft)),
      ('Frontage', feet(p.frontageFt)),
      ('Depth', feet(p.depthFt)),
      ('Floor level', recorded(p.floorLevel)),
      ('Unit position', recorded(p.unitPosition)),
      ('Facing direction', recorded(p.facingDirection)),
      ('Toilets / bathrooms', p.bathrooms?.toString()),
      ('Furnishing', recorded(p.furnishing)),
      ('Tenure', recorded(p.tenure)),
      ('Parking', p.hasParking == null ? null : p.hasParking! ? 'Onsite parking' : 'No onsite parking'),
      ('Suitable for a food business', p.isFnbSuitable == null ? null : p.isFnbSuitable! ? 'Yes' : 'No'),
      ('Corner lot', p.isCornerLot == null ? null : p.isCornerLot! ? 'Yes' : 'No'),
      ('Freehold', p.isFreehold == null ? null : p.isFreehold! ? 'Yes' : 'No'),
      ('Availability', recorded(p.availability)),
      ('Availability verified', recorded(p.availabilityVerifiedAt)?.split('T').first),
    ].where((entry) => entry.$2 != null).toList();
    return Container(
      decoration: BoxDecoration(color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border)),
      child: ExpansionTile(
        title: const Text('Show listing details', style: TextStyle(
          fontWeight: FontWeight.w700, fontSize: 16, color: SitewiseColors.ink)),
        subtitle: Text('${data.length} recorded details', style: const TextStyle(
          color: SitewiseColors.muted, fontSize: 12)),
        initiallyExpanded: false,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          for (final entry in data) Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(entry.$1, style: const TextStyle(
                color: SitewiseColors.muted, fontSize: 13))),
              const SizedBox(width: 12),
              Expanded(child: Text(entry.$2!, textAlign: TextAlign.end,
                style: const TextStyle(color: SitewiseColors.ink,
                  fontSize: 13, fontWeight: FontWeight.w600))),
            ]),
          ),
          if (p.listingDataNotice?.trim().isNotEmpty == true) ...[
            const Divider(color: SitewiseColors.border),
            Text(p.listingDataNotice!, style: const TextStyle(
              color: SitewiseColors.muted, fontSize: 12, height: 1.4)),
          ],
          if (data.isEmpty && p.listingDataNotice?.trim().isNotEmpty != true)
            const Text('No additional listing facts were recorded.', style: TextStyle(
              color: SitewiseColors.muted, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _webSurroundings(CommercialProperty p) {
    final lat = p.latitude;
    final lon = p.longitude;
    final valid = lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 &&
        lat.isFinite && lon.isFinite && !(lat == 0 && lon == 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Explore the surrounding area', style: TextStyle(
        color: SitewiseColors.ink, fontWeight: FontWeight.w800, fontSize: 20)),
      const SizedBox(height: 6),
      const Text('See what is recorded around this property.', style: TextStyle(
        color: SitewiseColors.muted, fontSize: 14)),
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: SitewiseColors.surface,
          border: Border.all(color: SitewiseColors.border),
          borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.map_outlined, size: 24, color: SitewiseColors.action),
            const SizedBox(width: 10),
            Expanded(child: Text(_displayAddress(p), style: const TextStyle(
              color: SitewiseColors.ink, fontSize: 14, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 12),
          Text(valid
              ? 'Map location: ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
              : 'Map coordinates have not been verified.',
            style: const TextStyle(color: SitewiseColors.muted, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('View actual map and directions'),
            onPressed: !valid ? null : () async {
              final url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lon');
              final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
              if (!opened && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Could not open the map application.')));
              }
            },
          )),
          const SizedBox(height: 8),
          const Text('Open the actual map for nearby streets and route planning. '
              'Recorded 500 m / 1 km counts are shown below; these are straight-line '
              'catchments, not travel times.', style: TextStyle(
                color: SitewiseColors.muted, fontSize: 12, height: 1.5)),
        ]),
      ),
    ]);
  }

  Widget _webTabs() {
    const labels = ['Your business match', 'Why this area score?', "What's nearby"];
    return SingleChildScrollView(scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (var i = 0; i < labels.length; i++)
          Padding(padding: const EdgeInsets.only(right: 10), child: ChoiceChip(
            label: Text(labels[i], style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: i == _webTab ? SitewiseColors.action : SitewiseColors.muted)),
            selected: i == _webTab,
            selectedColor: SitewiseColors.infoWash,
            backgroundColor: SitewiseColors.surface,
            side: BorderSide(color: i == _webTab
              ? SitewiseColors.action : SitewiseColors.border),
            onSelected: (_) => setState(() => _webTab = i),
          )),
      ]),
    );
  }

  Widget _webBusinessMatch(CommercialProperty p) {
    final resultId = widget.resultId;
    if (resultId == null || resultId.isEmpty) {
      return _webSection('Your preferences vs this property', [
        const Text('A personalised match is available when you open a property '
          'from a generated recommendation. The area suitability score does '
          'not measure your saved preference match.', style: TextStyle(
          color: SitewiseColors.muted, height: 1.5, fontSize: 14)),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: () => _open('/entrepreneur/recommendations'),
          icon: const Icon(Icons.tune_rounded),
          label: const Text('View recommendations')),
      ]);
    }
    final value = ref.watch(explanationProvider(resultId));
    return value.when(
      loading: () => const MobileSkeletonBox(height: 110),
      error: (error, stack) => _webSection('Your preferences vs this property', [
        const Text('The saved recommendation explanation is unavailable.',
          style: TextStyle(color: SitewiseColors.muted, fontSize: 14)),
        TextButton(onPressed: () => ref.invalidate(explanationProvider(resultId)),
          child: const Text('Try again')),
      ]),
      data: (explanation) {
        if (explanation.propertyId != p.id) {
          return _webSection('Your preferences vs this property', [
            const Text('Recommendation context does not match this property.',
              style: TextStyle(color: SitewiseColors.muted)),
          ]);
        }
        final components = explanation.components.entries.toList();
        return _webSection('Your preferences vs this property', [
          if (explanation.selectedBusinessCategory != null)
            Text('Business: ${explanation.selectedBusinessCategory}', style: const TextStyle(
              fontSize: 14, color: SitewiseColors.ink, fontWeight: FontWeight.w700)),
          if (explanation.preferenceMatchScore != null) ...[
            const SizedBox(height: 6),
            Text('Preference match: ${(explanation.preferenceMatchScore! * 100).toStringAsFixed(0)}% ',
              style: const TextStyle(color: SitewiseColors.action,
                fontSize: 16, fontWeight: FontWeight.w800)),
          ],
          const SizedBox(height: 10),
          if (components.isEmpty) const Text('No saved preferences were scored for this property.',
            style: TextStyle(color: SitewiseColors.muted)),
          for (final entry in components) ...[
            const Divider(height: 24, color: SitewiseColors.border),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(entry.key.replaceAll('_', ' '), style: const TextStyle(
                  color: SitewiseColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
                if (entry.value.reason.trim().isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(entry.value.reason, style: const TextStyle(
                    color: SitewiseColors.muted, fontSize: 12, height: 1.4)),
                ],
              ])),
              const SizedBox(width: 8),
              Text(entry.value.status != 'scored' || entry.value.value == null
                  ? 'Not enough data'
                  : entry.value.value! >= 0.65 ? 'Matched' : 'Needs review',
                style: TextStyle(color: entry.value.value != null &&
                    entry.value.status == 'scored' && entry.value.value! >= 0.65
                    ? SitewiseColors.success : SitewiseColors.muted,
                  fontSize: 11, fontWeight: FontWeight.w700)),
            ]),
          ],
          if (explanation.cautions.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Points to consider', style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700, color: SitewiseColors.ink)),
            for (final caution in explanation.cautions.take(4)) Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('• $caution', style: const TextStyle(
                fontSize: 13, height: 1.4, color: SitewiseColors.text))),
          ],
        ]);
      },
    );
  }

  Widget _webScore(CommercialProperty p, EntrepreneurState model) =>
    _webSection('How suitable is this area for a food business?', [
      _insights(p, model),
      const SizedBox(height: 12),
      const Text('This research score does not predict sales, customers or '
        'business success.', style: TextStyle(
        fontSize: 12, height: 1.4, color: SitewiseColors.muted)),
    ]);

  // Web-parity presentation for the existing What's nearby tab only.
  // Data still comes from propertyEvidenceProvider and the already loaded
  // property; a missing metric is never replaced with an assumed zero.
  Widget _webNearby(CommercialProperty p) {
    final evidence = ref.watch(propertyEvidenceProvider(p.id));
    return evidence.when(
      loading: () => _webSection("What's nearby", [
        const MobileSkeletonBox(height: 140),
      ]),
      error: (error, stack) => _webSection("What's nearby", [
        const Text(
          'Nearby measurements could not be loaded.',
          style: TextStyle(color: SitewiseColors.muted, fontSize: 14),
        ),
        TextButton(
          onPressed: () => ref.invalidate(propertyEvidenceProvider(p.id)),
          child: const Text('Try again'),
        ),
        _webNearbyFromListing(),
      ]),
      data: (data) {
        String number(num? value) {
          if (value == null) return 'Not measured';
          return value.round().toString().replaceAllMapped(
            RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
            (match) => '${match[1]},',
          );
        }

        String reading(String key, {String? alternate}) {
          final found = data.metric(key) ??
              (alternate == null ? null : data.metric(alternate));
          if (found != null) return found.display;
          return switch (key) {
            'pop_500m' => number(p.population500m),
            'pop_1000m' => number(p.population1km),
            'competitor_count_500m' => number(p.competitorCount500m),
            'competitor_count_1000m' => number(p.competitorCount1km),
            _ => 'Not measured',
          };
        }

        final district = data.districtName;
        return _webSection("What's nearby", [
          const Text(
            'Location overview',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Compare what is around this property at 500 m and 1 km.',
            style: TextStyle(fontSize: 14, color: SitewiseColors.muted),
          ),
          const SizedBox(height: 14),
          _nearbyRadiusPanel(
            radius: '500 m',
            subtitle: 'The immediate area around this property',
            tiles: [
              _nearbyTile(
                Icons.groups_outlined, 'Estimated residents',
                reading('pop_500m'), 'Residential population estimate',
              ),
              _nearbyTile(
                Icons.storefront_outlined, 'F&B competition',
                reading('competitor_count_500m',
                    alternate: 'fnb_competitors_500m'),
                'Other mapped F&B businesses',
              ),
              _nearbyTile(
                Icons.local_parking_outlined, 'Parking facilities',
                reading('parking_facilities_500m'),
                'Mapped facilities, not free spaces',
              ),
              _nearbyTile(
                Icons.shopping_bag_outlined, 'Retail shops',
                reading('retail_pois_500m'), 'Mapped retail businesses',
              ),
            ],
            footnote: 'Within a 500 m radius, not a 500 m walking route.',
          ),
          const SizedBox(height: 12),
          _nearbyRadiusPanel(
            radius: '1 km',
            subtitle: 'The wider surrounding area',
            tiles: [
              _nearbyTile(
                Icons.groups_outlined, 'Estimated residents',
                reading('pop_1000m'), 'Residential population estimate',
              ),
              _nearbyTile(
                Icons.storefront_outlined, 'F&B competition',
                reading('competitor_count_1000m',
                    alternate: 'fnb_competitors_1000m'),
                'Other mapped F&B businesses',
              ),
              _nearbyTile(
                Icons.local_parking_outlined, 'Parking facilities',
                reading('parking_facilities_1km',
                    alternate: 'parking_facilities_1000m'),
                'Mapped facilities, not free spaces',
              ),
              _nearbyTile(
                Icons.shopping_bag_outlined, 'Retail shops',
                reading('retail_pois_1000m'), 'Mapped retail businesses',
              ),
            ],
            footnote: 'Offices: ${reading('office_pois_1000m')}. '
                'Counts use a 1 km radius, not walking distance.',
          ),
          const SizedBox(height: 14),
          _nearbyPanel(
            title: 'Access & walkability',
            description: 'Walking distances and reach are separate from '
                'the circular 500 m and 1 km counts.',
            children: [
              _nearbyAccessRow(
                Icons.directions_bus_outlined,
                'Nearest public transport',
                reading('nearest_transit_walk_m'),
                '${reading('bus_stops_500m_walk')} bus stops within a 500 m walk · '
                    '${reading('rail_stations_1km_walk')} rail stations '
                    'within a 1 km walk',
              ),
              _nearbyAccessRow(
                Icons.local_parking_outlined,
                'Nearest parking facility',
                reading('nearest_parking_distance_m'),
                'Distance to the nearest mapped parking location',
              ),
              _nearbyAccessRow(
                Icons.directions_walk_outlined,
                '10-minute walking reach',
                reading('walk_isochrone_area_10min_km2'),
                'Area reachable on foot; not a population estimate',
              ),
            ],
          ),
          const SizedBox(height: 14),
          _nearbyPanel(
            title: 'Who lives in the wider district?',
            description: 'Official DOSM district statistics, separate '
                'from the nearby population estimates.',
            children: [
              if (data.districtAvailable) ...[
                if (district != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      district,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.ink,
                      ),
                    ),
                  ),
                _nearbyAccessRow(
                  Icons.groups_outlined,
                  'Residents in the whole district',
                  data.districtPopulation == null
                      ? 'Not available'
                      : '${data.districtPopulation}',
                  'DOSM district population'
                      '${data.populationAsOf == null ? '' : ' · ${data.populationAsOf}'}',
                ),
                _nearbyAccessRow(
                  Icons.account_balance_wallet_outlined,
                  'Median monthly household income',
                  data.householdMedian == null
                      ? 'Not available'
                      : 'RM ${data.householdMedian}',
                  'DOSM district income'
                      '${data.incomeAsOf == null ? '' : ' · ${data.incomeAsOf}'}',
                ),
              ] else
                Text(
                  data.districtReason ??
                      'No verified district statistics available.',
                  style: const TextStyle(
                    color: SitewiseColors.muted,
                    fontSize: 14,
                  ),
                ),
              const SizedBox(height: 10),
              const Text(
                'District data describes the whole administrative district, '
                'not people within 500 m or 1 km of the property.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: SitewiseColors.muted,
                ),
              ),
            ],
          ),
          // Keep the existing property-insights fallback when the evidence
          // endpoint has no individual measurements for this listing.
          if (data.measurements.isEmpty) ...[
            const SizedBox(height: 12),
            _webNearbyFromListing(),
          ],
          const SizedBox(height: 12),
          const Text(
            'Distances are straight-line radii unless labelled as walking '
            'distances. Missing measurements are not zeros.',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: SitewiseColors.muted,
            ),
          ),
        ]);
      },
    );
  }

  Widget _nearbyRadiusPanel({
    required String radius,
    required String subtitle,
    required List<Widget> tiles,
    required String footnote,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SitewiseColors.surface,
      border: Border.all(color: SitewiseColors.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Within $radius',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(
          color: SitewiseColors.muted, fontSize: 13,
        )),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 290 ? 1 : 2;
            final width =
                (constraints.maxWidth - (columns == 2 ? 10 : 0)) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final tile in tiles)
                  SizedBox(width: width, child: tile),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          footnote,
          style: const TextStyle(
            fontSize: 12, height: 1.45, color: SitewiseColors.muted,
          ),
        ),
      ],
    ),
  );

  Widget _nearbyTile(
    IconData icon,
    String label,
    String value,
    String note,
  ) => Container(
    constraints: const BoxConstraints(minHeight: 126),
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: SitewiseColors.background,
      border: Border.all(color: SitewiseColors.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: SitewiseColors.action, size: 19),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(
          color: SitewiseColors.muted, fontSize: 12, height: 1.3,
        )),
        const SizedBox(height: 5),
        Text(value, style: const TextStyle(
          color: SitewiseColors.ink,
          fontSize: 16,
          height: 1.25,
          fontWeight: FontWeight.w800,
        )),
        const SizedBox(height: 5),
        Text(note, style: const TextStyle(
          color: SitewiseColors.muted,
          fontSize: 11.5,
          height: 1.3,
        )),
      ],
    ),
  );

  Widget _nearbyPanel({
    required String title,
    required String description,
    required List<Widget> children,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SitewiseColors.surface,
      border: Border.all(color: SitewiseColors.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(
          color: SitewiseColors.ink,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        )),
        const SizedBox(height: 5),
        Text(description, style: const TextStyle(
          color: SitewiseColors.muted,
          fontSize: 13,
          height: 1.4,
        )),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );

  Widget _nearbyAccessRow(
    IconData icon,
    String title,
    String value,
    String explanation,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: SitewiseColors.action, size: 21),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(
                color: SitewiseColors.muted,
                fontSize: 13,
                height: 1.3,
              )),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(
                color: SitewiseColors.ink,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              )),
              const SizedBox(height: 4),
              Text(explanation, style: const TextStyle(
                color: SitewiseColors.muted,
                fontSize: 12,
                height: 1.45,
              )),
            ],
          ),
        ),
      ],
    ),
  );

  /// Counts-only fallback from the already fetched property insights. The
  /// source may report more layers than the main location-evidence endpoint.
  Widget _webNearbyFromListing() => FutureBuilder<PropertyInsightsModel?>(
    future: _insightsFuture,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done || snap.data == null) {
        return const SizedBox.shrink();
      }
      final layers = snap.data!.mapLayers.where((layer) =>
          layer.count500m != null || layer.count1000m != null).toList();
      if (layers.isEmpty) return const SizedBox.shrink();
      return _nearbyPanel(
        title: 'Other recorded nearby measurements',
        description: 'Additional location counts available for this listing.',
        children: [
          for (final layer in layers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(layer.label, style: const TextStyle(
                      color: SitewiseColors.ink,
                      fontSize: 13,
                    )),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '500 m: ${layer.count500m?.toString() ?? 'Not measured'}\n'
                      '1 km: ${layer.count1000m?.toString() ?? 'Not measured'}',
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: SitewiseColors.text,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );

  Widget _webSection(String title, List<Widget> children) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: SitewiseColors.surface,
      border: Border.all(color: SitewiseColors.border),
      borderRadius: BorderRadius.circular(16)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 17,
        color: SitewiseColors.ink, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      ...children,
    ]),
  );

  Widget _webBeforeYouDecide(CommercialProperty p) =>
    _webSection('Before you decide', [
      const Text('Confirm licensing, kitchen ventilation and grease-trap '
        'requirements with the relevant local authority.', style: TextStyle(
          color: SitewiseColors.text, fontSize: 13, height: 1.45)),
      const SizedBox(height: 8),
      Text(p.verification == VerificationStatus.verified
        ? 'This listing is verified, but F&B licensing is not confirmed.'
        : 'This listing is not verified. Confirm rent, floor area and availability.',
        style: const TextStyle(color: SitewiseColors.text, fontSize: 13, height: 1.45)),
      const SizedBox(height: 8),
      const Text('Location scores do not predict revenue, customer numbers or '
        'commercial success.', style: TextStyle(
          color: SitewiseColors.muted, fontSize: 12, height: 1.4)),
    ]);

  Widget _bottomActions(CommercialProperty p) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: const BoxDecoration(
        color: SitewiseColors.surface,
        border: Border(top: BorderSide(color: SitewiseColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _compareAction(p.id),
              icon: const Icon(Icons.compare_arrows_rounded, size: 20),
              label: const Text('Compare'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 52),
                foregroundColor: SitewiseColors.action,
                side: const BorderSide(color: SitewiseColors.action),
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: () => _open(
                '/entrepreneur/assessment-setup',
                arguments: p.id,
              ),
              icon: const Icon(Icons.assessment_outlined, size: 20),
              label: const Text('Assess property'),
              style: ElevatedButton.styleFrom(
                backgroundColor: SitewiseColors.action,
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 52),
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    ),
  );

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
    String? panoramaUrl,
  ) => MobilePropertyGallery(
    property: p,
    urls: photos,
    borderRadius: BorderRadius.circular(18),
    // Save is in the detail header; do not obscure the photo with a second
    // bookmark button.
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

  Widget _heroWithPanorama(
    CommercialProperty p,
    List<String> photos,
  ) => FutureBuilder<PropertyInsightsModel?>(
    future: _insightsFuture,
    builder: (context, snapshot) =>
        _hero(p, photos, snapshot.data?.panorama.readyUrl),
  );

  String _displayAddress(CommercialProperty p) {
    var address = p.address.trim().replaceAll(RegExp(r'\s+'), ' ');
    // Imported research records sometimes prefix the local address with an
    // administrative area separated by ';'. Avoid repeating city/state.
    if (address.contains(';')) {
      final detail = address.split(';').last.trim();
      if (detail.isNotEmpty) address = detail;
    }
    final components = <String>[
      if (address.isNotEmpty) address,
      if (p.postcode.trim().isNotEmpty && !address.contains(p.postcode.trim()))
        p.postcode.trim(),
      if (p.city.trim().isNotEmpty &&
          !address.toLowerCase().contains(p.city.trim().toLowerCase()))
        p.city.trim(),
      if (p.state.trim().isNotEmpty &&
          !address.toLowerCase().contains(p.state.trim().toLowerCase()))
        p.state.trim(),
    ];
    return components.join(', ');
  }

  Widget _keyFacts(CommercialProperty p) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SitewiseColors.surface,
      border: Border.all(color: SitewiseColors.border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Property information',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: SitewiseColors.ink),
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Fact(
                icon: Icons.aspect_ratio_outlined,
                label: 'Floor area',
                value: p.sizeSqft > 0
                    ? '${p.sizeSqft.toStringAsFixed(0)} sq ft'
                    : 'Not listed',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Fact(
                icon: Icons.storefront_outlined,
                label: 'Unit type',
                value: p.propertyType.isNotEmpty ? p.propertyType : 'Not listed',
              ),
            ),
          ],
        ),
        const SizedBox(height: 19),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Fact(
                icon: Icons.calculate_outlined,
                label: 'Rental efficiency',
                value: p.rentalRm > 0 && p.sizeSqft > 0
                    ? 'RM ${p.rentalPerSqft.toStringAsFixed(2)} / sq ft'
                    : 'Not computable',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FutureBuilder<PropertyInsightsModel?>(
                future: _insightsFuture,
                builder: (context, snap) => _Fact(
                  icon: Icons.threesixty_rounded,
                  label: '360° view',
                  value: _tourState(p, snap),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _insights(CommercialProperty p, EntrepreneurState model) {
    // Do not show the previously opened property's analysis while this one
    // loads. Keep the same existing backend contract and fallback rules.
    final analysis = model.analysisPropertyId == p.id ? model.analysis : null;
    final error = model.analysisPropertyId == p.id ? model.analysisError : null;
    return FutureBuilder<PropertyInsightsModel?>(
      future: _insightsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MobileSkeletonBox(height: 100);
        }
        final insights = snapshot.data;
        if (insights != null) return MobileInsightsPanel(insights: insights);
        return _assessmentBlock(p, model, analysis, error);
      },
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
  final IconData icon;
  final String label;
  final String value;

  const _Fact({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 37,
        height: 37,
        decoration: BoxDecoration(
          color: SitewiseColors.infoWash,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 20, color: SitewiseColors.action),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, height: 1.35, color: SitewiseColors.muted),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              softWrap: true,
              style: const TextStyle(
                fontSize: 14,
                height: 1.3,
                fontWeight: FontWeight.w700,
                color: SitewiseColors.ink,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
