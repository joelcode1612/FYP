// SiteWise mobile property-detail focused UI patch (joel branch)
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_evidence_score.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_factor_row.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_map_panel.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_secondary_button.dart';
import 'package:fyp/shared/presentation/components/mobile_property_gallery.dart';
import 'package:fyp/features/assessment/presentation/widgets/mobile_insights_panel.dart';
import 'package:fyp/shared/presentation/components/mobile_skeleton.dart';

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

  int _detailTab = 0;

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appNotifierProvider);
    final model = ref.watch(entrepreneurNotifierProvider);

    // A pushed property-detail route is NOT a primary tab destination.
    // Its only app-bar actions are Back and Save, and it has its own
    // contextual Compare / Assess actions instead of the global bottom dock.
    return Scaffold(
      backgroundColor: SitewiseColors.background,
      appBar: AppBar(
        toolbarHeight: 58,
        automaticallyImplyLeading: false,
        backgroundColor: SitewiseColors.surface,
        foregroundColor: SitewiseColors.ink,
        surfaceTintColor: SitewiseColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        shape: const Border(
          bottom: BorderSide(color: SitewiseColors.border),
        ),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          'Property details',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.ink,
          ),
        ),
        actions: [
          FutureBuilder<_PropertyRecord?>(
            future: _propertyFuture,
            builder: (context, snapshot) {
              final property = snapshot.data?.property;
              if (property == null) return const SizedBox(width: 48);
              final saved = appState.saved.contains(property.id);
              return IconButton(
                tooltip: saved ? 'Remove from favourites' : 'Save property',
                icon: Icon(
                  saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                  color: saved ? SitewiseColors.action : SitewiseColors.ink,
                ),
                onPressed: () => _toggleSaved(property.id, !saved),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: FutureBuilder<_PropertyRecord?>(
        future: _propertyFuture,
        builder: (context, snapshot) {
          final property = snapshot.data?.property;
          if (property == null) return const SizedBox.shrink();
          return _bottomActions(property);
        },
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
              return const MobilePropertyListSkeleton(
                padding: EdgeInsets.all(16),
              );
            }
            if (snap.hasError) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(
                          readableFailure(
                            snap.error!,
                            fallback: 'We could not load this property. Please try again.',
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: SitewiseColors.muted,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SitewiseSecondaryButton(
                          label: 'Try again',
                          icon: Icons.refresh_rounded,
                          onPressed: _reload,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }
            final record = snap.data;
            if (record == null) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('This property is no longer available.'),
                  ),
                ],
              );
            }
            final p = record.property;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              children: [
                _heroWithPanorama(p, record.photos),
                const SizedBox(height: 22),
                _identity(p),
                const SizedBox(height: 20),
                _keyFacts(p),
                const SizedBox(height: 24),
                _detailTabs(),
                const SizedBox(height: 20),
                if (_detailTab == 0) _overviewTab(p),
                if (_detailTab == 1) _locationTab(p),
                if (_detailTab == 2) _nearbyTab(),
                if (_detailTab == 3) _analysisTab(p, model),
              ],
            );
          },
        ),
      ),
    );
  }

  // Preserve current live data and existing routes. The tabs are presentation
  // state only; they do not fetch or manufacture additional property facts.
  Widget _detailTabs() {
    const titles = ['Overview', 'Location', 'Nearby', 'Analysis'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < titles.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: InkWell(
                onTap: () => setState(() => _detailTab = i),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 11),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: _detailTab == i ? 3 : 1,
                        color: _detailTab == i
                            ? SitewiseColors.action
                            : SitewiseColors.border,
                      ),
                    ),
                  ),
                  child: Text(
                    titles[i],
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: _detailTab == i ? FontWeight.w700 : FontWeight.w500,
                      color: _detailTab == i
                          ? SitewiseColors.action
                          : SitewiseColors.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _overviewTab(CommercialProperty p) {
    final verified = p.verification == VerificationStatus.verified;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: SitewiseColors.infoWash,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline_rounded, color: SitewiseColors.action),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'What to check before visiting',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      verified
                          ? 'F&B approval information is not available. Confirm permitted use with the owner or authority.'
                          : 'F&B approval is unknown and this property has not been verified. Confirm details before making a decision.',
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: SitewiseColors.text,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (p.hasTour) ...[
          const SizedBox(height: 16),
          SitewiseSecondaryButton(
            label: 'View 360° tour',
            icon: Icons.threesixty_rounded,
            onPressed: () => _open('/entrepreneur/tour', arguments: p.id),
          ),
        ],
      ],
    );
  }

  Widget _locationTab(CommercialProperty p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Property location',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: SitewiseColors.ink),
      ),
      const SizedBox(height: 6),
      Text(
        _displayAddress(p),
        style: const TextStyle(fontSize: 14, color: SitewiseColors.muted),
      ),
      const SizedBox(height: 14),
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SitewiseMapPanel(
          height: 260,
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
      ),
    ],
  );

  Widget _nearbyTab() => FutureBuilder<PropertyInsightsModel?>(
    future: _insightsFuture,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const MobileSkeletonBox(height: 80);
      }
      final layers = snapshot.data?.mapLayers
              .where((layer) =>
                  layer.count500m != null || layer.count1000m != null || layer.nearestM != null)
              .toList() ??
          const <MapLayerModel>[];
      if (layers.isEmpty) {
        return const Text(
          'Nearby facility measurements are not available for this property.',
          style: TextStyle(fontSize: 14, color: SitewiseColors.muted, height: 1.5),
        );
      }
      return Container(
        decoration: BoxDecoration(
          color: SitewiseColors.surface,
          border: Border.all(color: SitewiseColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            for (var i = 0; i < layers.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: SitewiseColors.border),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    const Icon(Icons.place_outlined, color: SitewiseColors.action, size: 21),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        layers[i].label,
                        style: const TextStyle(fontSize: 15, color: SitewiseColors.ink, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        layers[i].count500m != null
                            ? layers[i].countLabel()
                            : layers[i].count1000m != null
                                ? layers[i].countLabel(radiusMeters: 1000)
                                : 'Nearest ${layers[i].nearestM!.toStringAsFixed(0)} m',
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 13, color: SitewiseColors.muted),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _analysisTab(CommercialProperty p, EntrepreneurState model) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Location analysis',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: SitewiseColors.ink),
      ),
      const SizedBox(height: 10),
      _insights(p, model),
      const SizedBox(height: 14),
      SitewiseSecondaryButton(
        label: 'Generate evaluation report',
        icon: Icons.description_outlined,
        onPressed: () => _open('/entrepreneur/report', arguments: p.id),
      ),
    ],
  );

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

  Widget _identity(CommercialProperty p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        p.title,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
          height: 1.2,
          color: SitewiseColors.ink,
        ),
      ),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.place_outlined, size: 19, color: SitewiseColors.muted),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              _displayAddress(p),
              style: const TextStyle(
                fontSize: 15,
                height: 1.45,
                color: SitewiseColors.muted,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 22),
      LayoutBuilder(
        builder: (context, constraints) {
          final price = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                p.rentalRm > 0 ? p.rentalDisplay : 'Rent on request',
                maxLines: 2,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.action,
                  height: 1.15,
                ),
              ),
              if (p.rentalRm > 0)
                const Text(
                  'per month',
                  style: TextStyle(fontSize: 14, color: SitewiseColors.muted),
                ),
              if (p.rentalRm > 0 && p.sizeSqft > 0) ...[
                const SizedBox(height: 5),
                Text(
                  'RM ${p.rentalPerSqft.toStringAsFixed(2)} / sq ft',
                  style: const TextStyle(fontSize: 13, color: SitewiseColors.muted),
                ),
              ],
            ],
          );
          final suitability = p.hasSuitabilityScore
              ? Row(
                  children: [
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: (p.suitabilityScore / 100).clamp(0.0, 1.0).toDouble(),
                            strokeWidth: 5,
                            backgroundColor: SitewiseColors.border,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              SitewiseScoreRamp.colorFor(p.suitabilityScore),
                            ),
                          ),
                          Text(
                            p.suitabilityScore.toStringAsFixed(0),
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: SitewiseColors.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 9),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Location suitability',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: SitewiseColors.ink),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Research index, not a success probability',
                            style: TextStyle(fontSize: 11, height: 1.35, color: SitewiseColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : const Text(
                  'Location suitability not scored yet',
                  style: TextStyle(fontSize: 14, color: SitewiseColors.muted),
                );
          if (constraints.maxWidth < 320) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                price,
                const SizedBox(height: 16),
                const Divider(height: 1, color: SitewiseColors.border),
                const SizedBox(height: 16),
                suitability,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 9, child: price),
              const SizedBox(width: 12),
              Container(height: 92, width: 1, color: SitewiseColors.border),
              const SizedBox(width: 12),
              Expanded(flex: 11, child: suitability),
            ],
          );
        },
      ),
    ],
  );

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
            const Expanded(
              child: _Fact(
                icon: Icons.restaurant_outlined,
                label: 'F&B approval',
                value: 'Unknown',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Fact(
                icon: Icons.verified_user_outlined,
                label: 'Verification',
                value: p.verification == VerificationStatus.verified
                    ? 'Verified'
                    : 'Unverified',
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
        if (p.requirements.isNotEmpty || p.tags.isNotEmpty) ...[
          const Divider(height: 28, color: SitewiseColors.border),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final item in p.requirements) _Tag(item, positive: true),
              for (final item in p.tags) _Tag(item),
            ],
          ),
        ],
        const Divider(height: 28, color: SitewiseColors.border),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline_rounded, color: SitewiseColors.muted, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppConfig.usesDemoData
                    ? 'Sample research data. Floor area and rent require verification.'
                    : 'Imported listing data. Floor area and rent require verification.',
                style: const TextStyle(fontSize: 12, height: 1.45, color: SitewiseColors.muted),
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

class _Tag extends StatelessWidget {
  final String label;
  final bool positive;

  const _Tag(this.label, {this.positive = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: positive ? SitewiseColors.successWash : SitewiseColors.geoWash,
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
