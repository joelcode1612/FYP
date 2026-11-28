import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/listing/presentation/pages/entrepreneur_property_detail_mobile_page.dart';
import 'package:fyp/features/property_management/presentation/widgets/provider_panorama_tour_section.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/features/property_management/presentation/widgets/provider_agent_inspection_panel.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';
import 'package:fyp/shared/presentation/components/provider_card_actions.dart';
import 'package:fyp/features/property_management/data/provider_workspace_service.dart';
import 'package:fyp/features/property_management/application/provider_listings_service.dart';

/// Existing provider detail route resolver. Agents see the shared listing
/// details presentation; Owners keep their management details page. The
/// inspection route bypasses this resolver and remains its own workflow.
class ProviderListingDetailRoute extends ConsumerWidget {
  const ProviderListingDetailRoute({super.key, required this.listingId});

  final int listingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authNotifierProvider.select((state) => state.user?.role)) ??
        ref.watch(appNotifierProvider.select((state) => state.role));
    if (role == AppRole.agent) {
      return EntrepreneurPropertyDetailMobilePage(
        propertyId: '$listingId',
        agentView: true,
      );
    }
    return ProviderPropertyDetailMobilePage(listingId: listingId);
  }
}

/// One provider listing: facts, status, media actions and the workflow step
/// that is legal for the signed-in role.
///
/// Owners edit the record they own and submit it for verification. Agents work
/// through the staff proposal endpoint, so their changes become a change
/// request an administrator reviews — never a direct mutation of someone
/// else's listing.
class ProviderPropertyDetailMobilePage extends ConsumerStatefulWidget {
  const ProviderPropertyDetailMobilePage({
    super.key,
    required this.listingId,
    this.inspectionFirst = false,
  });

  final int listingId;
  final bool inspectionFirst;

  @override
  ConsumerState<ProviderPropertyDetailMobilePage> createState() =>
      _ProviderPropertyDetailMobilePageState();
}

class _ProviderPropertyDetailMobilePageState
    extends ConsumerState<ProviderPropertyDetailMobilePage> {
  Future<_DetailData>? _future;
  Future<LocationAnalysis>? _locationFuture;
  bool _busy = false;
  int _selectedTab = 0;
  int _radiusMetres = 500;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final role = ref.read(authNotifierProvider).user?.role ?? AppRole.owner;
    final request = _loadDetail(role);
    _locationFuture = ServiceLocator.recommendations.analysis(
      '${widget.listingId}',
    );
    if (!mounted) return;
    // A block body is required: an arrow-bodied assignment returns the Future
    // itself, and Flutter's setState rejects that with a red error screen.
    setState(() {
      _future = request;
    });
    await settleRefresh(request);
  }

  Future<_DetailData> _loadDetail(AppRole role) async {
    final scope = await ProviderListingsService.load(role);
    ProviderListing? found;
    for (final row in scope.listings) {
      if (row.id == widget.listingId) {
        found = row;
        break;
      }
    }
    if (found == null) {
      throw StateError(
        'Listing ${widget.listingId} is not in the set this account may manage.',
      );
    }
    // Read the manager from the server on every open. The row appearing in this
    // account's list only says "you may reach it"; it does not say whether that
    // is because you own it or because you were assigned it, and the page must
    // not guess.
    final management = await ProviderWorkspaceService.management(
      widget.listingId,
    );
    if (role == AppRole.agent) {
      final detail = await ServiceLocator.agentListings.listingDetail(
        widget.listingId,
      );
      return _DetailData(listing: found, agent: detail, management: management);
    }
    final owner = await ServiceLocator.ownerListings.getListing(
      '${widget.listingId}',
    );
    return _DetailData(listing: found, owner: owner, management: management);
  }

  Future<void> _requestChange() async {
    final rentController = TextEditingController();
    final descriptionController = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request a change'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: rentController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Monthly rent (RM)',
                hintText: 'Leave blank to keep',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descriptionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'Leave blank to keep',
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Your proposal is sent to an administrator for review. The '
              'listing is not changed until it is approved.',
              style: TextStyle(fontSize: 12, color: providerMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send proposal'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    setState(() => _busy = true);
    try {
      final proposal = AgentProposal(
        rentalPrice: double.tryParse(rentController.text.trim()),
        description: descriptionController.text.trim().isEmpty
            ? null
            : descriptionController.text.trim(),
      );
      final result = await ServiceLocator.agentListings.saveProposal(
        widget.listingId,
        proposal,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // `updated` means the DRAFT change request was written — never that
          // the listing changed. Only an administrator's approval applies a
          // proposal, so saying "applied" here would contradict the dialog the
          // agent just confirmed.
          content: Text(
            result.updated
                ? 'Proposal saved. An administrator must approve it before the '
                      'listing changes.'
                : 'No differences from the current listing — nothing to '
                      'propose.',
          ),
        ),
      );
      _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send the proposal: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.inspectionFirst) {
      return FutureBuilder<_DetailData>(
        future: _future,
        builder: (context, snapshot) {
          final data = snapshot.data;
          final agent = data?.agent;
          if (agent != null && data != null) {
            return ProviderAgentInspectionPanel(
              propertyId: data.listing.id,
              listing: data.listing,
              inspectionDetail: agent,
              readOnly: data.listing.lockedForEditing,
            );
          }
          final error = snapshot.error;
          return Scaffold(
            appBar: const ProviderPageAppBar(
              title: 'Inspect Property',
              eyebrow: 'MANAGED LISTING',
            ),
            body: snapshot.connectionState != ConnectionState.done
                ? providerLoadingView()
                : error != null && isMfaRequired(error)
                ? ProviderMfaGate(onReload: _load)
                : ProviderMessage(
                    title: 'Inspection unavailable',
                    body:
                        error?.toString() ??
                        'Open an assigned property as its agent.',
                    onRetry: _load,
                  ),
          );
        },
      );
    }
    return Scaffold(
      backgroundColor: providerCanvas,
      appBar: ProviderPageAppBar(
        title: widget.inspectionFirst ? 'Inspect Property' : 'Manage Property',
        subtitle: widget.inspectionFirst
            ? 'Verify property information and complete the inspection.'
            : 'Manage property information, photographs and listing status.',
        eyebrow: 'MANAGED LISTING',
      ),
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _load,
        child: FutureBuilder<_DetailData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return providerLoadingView();
            }
            if (snapshot.hasError) {
              final error = snapshot.error!;
              return providerContent(
                children: [
                  if (isMfaRequired(error))
                    ProviderMfaGate(onReload: _load)
                  else
                    ProviderMessage(
                      title: 'This listing could not be opened',
                      body: '$error',
                      onRetry: _load,
                    ),
                ],
              );
            }
            final data = snapshot.data!;
            final listing = data.listing;
            final location = data.owner;
            return providerContent(
              children: [
                _propertyHero(listing),
                _photoGallery(data),
                if (data.agent != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _section('Property management', [
                      _factRow('Property status', _listingStatus(listing)),
                      _factRow('Photographs', listing.photoCount == null ? 'Count unavailable' : '${listing.photoCount} uploaded'),
                      _factRow('Rental availability', data.agent!.facts?.availability ?? 'Not provided'),
                      _factRow('Inspection', listing.inspectionProgressDisplay),
                      _factRow('Panorama', listing.panoramaConfirmed == true ? 'Confirmed' : 'Not confirmed'),
                      if (listing.lockedForEditing)
                        const Row(children: [Icon(Icons.lock_outline, size: 18), SizedBox(width: 8), Expanded(child: Text('This property is read-only while protected by its current review or approval status.'))]),
                    ]),
                  ),
                const SizedBox(height: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Basic')),
                    ButtonSegment(value: 1, label: Text('Extra')),
                  ],
                  selected: {_selectedTab},
                  onSelectionChanged: (value) =>
                      setState(() => _selectedTab = value.first),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(height: 12),
                if (_selectedTab == 0) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _metricTile(
                          'MONTHLY RENT',
                          listing.rentDisplay,
                          Icons.payments_outlined,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _metricTile(
                          'BUILT-UP AREA',
                          listing.sizeDisplay,
                          Icons.square_foot_outlined,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _section('Property information', [
                    _factRow(
                      'Property type',
                      listing.propertyType ?? 'Not provided',
                    ),
                    if (listing.psfDisplay.isNotEmpty)
                      _factRow('Rental rate', listing.psfDisplay),
                    _factRow(
                      'Publication',
                      listing.isPublished ? 'Published' : 'Not published',
                    ),
                    _factRow('Management', data.management.display),
                    if (data.agent?.owner != null)
                      _factRow(
                        'Property owner',
                        data.agent!.owner!.displayName.isEmpty
                            ? 'Not recorded'
                            : data.agent!.owner!.displayName,
                      ),
                    _factRow('Built-up area', listing.sizeDisplay),
                    _factRow(
                      'Floor level',
                      data.owner?.floorDescription ??
                          data.agent?.facts?.floorDescription ??
                          'Not provided',
                    ),
                    _factRow(
                      'Unit position',
                      data.owner?.unitPosition ??
                          data.agent?.facts?.unitPosition ??
                          'Not provided',
                    ),
                    _factRow(
                      'Shop frontage',
                      _feet(
                        data.owner?.frontageFt ?? data.agent?.facts?.frontageFt,
                      ),
                    ),
                    _factRow(
                      'Furnishing',
                      data.owner?.furnishing ??
                          data.agent?.facts?.furnishing ??
                          'Not provided',
                    ),
                    _factRow(
                      'Owner-declared parking',
                      _ownerParking(
                        data.owner?.hasParking ?? data.agent?.facts?.hasParking,
                      ),
                    ),
                    _factRow(
                      'Availability',
                      data.owner?.availability ??
                          data.agent?.facts?.availability ??
                          'Not provided',
                    ),
                    _factRow(
                      'Minimum rental period',
                      _lease(
                        data.owner?.leaseDurationMonths ??
                            data.agent?.facts?.leaseDurationMonths,
                        data.owner?.leaseDurationNegotiable ??
                            data.agent?.facts?.leaseDurationNegotiable,
                      ),
                    ),
                    _factRow(
                      'Available from',
                      data.owner?.availableFrom ??
                          data.agent?.facts?.availableFrom ??
                          'Not provided',
                    ),
                    _factRow(
                      'Rental deposit',
                      _money(
                        data.owner?.rentalDepositMyr ??
                            data.agent?.facts?.rentalDepositMyr,
                      ),
                    ),
                    _factRow(
                      'Land tenure',
                      data.owner?.tenure ??
                          data.agent?.facts?.tenure ??
                          'Not provided',
                    ),
                    _factRow(
                      'Property title type',
                      data.owner?.titleType ??
                          data.agent?.facts?.titleType ??
                          'Not provided',
                    ),
                    _factRow(
                      'Landlord F&B permission (owner-declared)',
                      data.owner?.landlordFnbPermission ??
                          data.agent?.facts?.landlordFnbPermission ??
                          'Not provided',
                    ),
                    if (data.agent?.photos.isNotEmpty ?? false)
                      _factRow(
                        'Photographs',
                        '${data.agent!.photos.length} available',
                      ),
                  ]),
                  if ((data.owner?.description ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _section('Description', [
                      Text(
                        data.owner!.description!,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 14,
                          height: 1.55,
                          color: SitewiseM3.ink,
                        ),
                      ),
                    ]),
                  ],
                  if (location?.latitude != null &&
                      location?.longitude != null) ...[
                    const SizedBox(height: 12),
                    _propertyMap(location!.latitude!, location.longitude!),
                  ],
                ] else ...[
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 500, label: Text('500 m')),
                      ButtonSegment(value: 1000, label: Text('1 km')),
                    ],
                    selected: {_radiusMetres},
                    onSelectionChanged: (value) =>
                        setState(() => _radiusMetres = value.first),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder<LocationAnalysis>(
                    future: _locationFuture,
                    builder: (context, result) => result.hasError
                        ? const ProviderCard(
                            title: 'Location intelligence',
                            child: Text(
                              'Location analysis is unavailable right now.',
                            ),
                          )
                        : result.connectionState != ConnectionState.done
                        ? const ProviderCard(
                            title: 'Location intelligence',
                            child: LinearProgressIndicator(),
                          )
                        : _locationDashboard(result.data!),
                  ),
                  const SizedBox(height: 12),
                  if (data.agent != null)
                    ProviderPanoramaTourSection(
                      key: ValueKey(listing.id),
                      propertyId: listing.id,
                      onStartCapture: null,
                      readOnly: true,
                    ),
                ],
                const SizedBox(height: 20),
                if (data.agent case final agent?)
                  ProviderCardActions(
                    actions: [
                      ProviderCardAction(
                        label: listing.lockedForEditing
                            ? 'View inspection'
                            : 'Inspect property',
                        icon: Icons.fact_check_outlined,
                        onPressed: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ProviderAgentInspectionPanel(
                                propertyId: listing.id,
                                listing: listing,
                                inspectionDetail: agent,
                                readOnly: listing.lockedForEditing,
                              ),
                            ),
                          );
                          if (mounted) await _load();
                        },
                        emphasis: ProviderCardActionEmphasis.primary,
                      ),
                      if (listing.canEdit)
                        ProviderCardAction(
                          label: 'Propose a change',
                          icon: Icons.edit_note_rounded,
                          onPressed: _busy ? null : _requestChange,
                        ),
                    ],
                  )
                else if (listing.canEdit)
                  ProviderCardActions(
                    actions: [
                      ProviderCardAction(
                        label: 'Edit listing',
                        icon: Icons.edit_outlined,
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context)
                                  .pushNamed(
                                    '/provider/add-property',
                                    arguments: '${widget.listingId}',
                                  )
                                  .then((_) {
                                    if (mounted) _load();
                                  }),
                        emphasis: ProviderCardActionEmphasis.primary,
                      ),
                    ],
                  ),
                if (listing.lockedForEditing) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 14,
                        color: SitewiseM3.muted,
                      ),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          listing.agentInspectionActive
                              ? 'Agent request active · Editing locked'
                              : 'Approved listing · Read-only',
                          style: TextStyle(
                            fontSize: 12,
                            color: SitewiseM3.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _propertyHero(ProviderListing listing) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: SitewiseM3.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: SitewiseM3.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'PROPERTY OVERVIEW',
          style: TextStyle(
            fontFamily: kFontFamily,
            color: SitewiseColors.action,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                listing.displayTitle,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  color: SitewiseM3.ink,
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                  height: 1.18,
                ),
              ),
            ),
            const SizedBox(width: 10),
            ProviderStatusPill(stage: listing.stage),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.location_on_outlined,
              size: 18,
              color: SitewiseM3.muted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                listing.address.isEmpty
                    ? 'Address not provided'
                    : listing.address,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  color: SitewiseM3.muted,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _metricTile(String label, String value, IconData icon) => Container(
    constraints: const BoxConstraints(minHeight: 132),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: SitewiseM3.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SitewiseM3.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21, color: SitewiseColors.action),
        const SizedBox(height: 12),
        Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 10,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w700,
            color: SitewiseM3.muted,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: SitewiseM3.ink,
          ),
        ),
      ],
    ),
  );

  Widget _propertyPhoto(String imageUrl) => ProviderCard(
    title: 'Property photo',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        imageUrl,
        width: double.infinity,
        height: 186,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          height: 140,
          alignment: Alignment.center,
          color: SitewiseM3.quiet,
          child: const Text(
            'Photo unavailable',
            style: TextStyle(color: SitewiseM3.muted),
          ),
        ),
      ),
    ),
  );

  Widget _photoGallery(_DetailData data) {
    final urls = <String>[
      if (data.owner != null) ...data.owner!.photos.map((photo) => photo.url),
      if (data.agent != null) ...data.agent!.photos.map((photo) => photo.url),
      if (data.listing.imageUrl?.trim().isNotEmpty == true)
        data.listing.imageUrl!,
    ].where((url) => url.trim().isNotEmpty).toSet().toList();
    if (urls.isEmpty) {
      return const ProviderCard(
        title: 'Property photographs',
        child: SizedBox(height: 120, child: Center(child: Text('No photographs are available yet.'))),
      );
    }
    return SizedBox(
      height: 210,
      child: PageView.builder(
        itemCount: urls.length,
        itemBuilder: (context, index) => ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.network(
            urls[index],
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                const Center(child: Text('Photo unavailable')),
          ),
        ),
      ),
    );
  }

  String _listingStatus(ProviderListing listing) {
    if (listing.isPublished && listing.stage == ProviderStage.approved) return 'Published';
    return switch (listing.stage) {
      ProviderStage.draft => 'Draft',
      ProviderStage.pending => 'Under Review',
      ProviderStage.rejected => 'Corrections Required',
      ProviderStage.approved => 'Approved · not published',
      ProviderStage.unknown => 'Status unavailable',
    };
  }

  Widget _propertyMap(double lat, double lon) => ProviderCard(
    title: 'Property location',
    child: SizedBox(
      height: 220,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          options: MapOptions(initialCenter: LatLng(lat, lon), initialZoom: 15),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.sitewise.app',
            ),
            CircleLayer(
              circles: [
                CircleMarker(
                  point: LatLng(lat, lon),
                  useRadiusInMeter: true,
                  radius: _radiusMetres.toDouble(),
                  color: SitewiseColors.action.withValues(alpha: .10),
                  borderColor: SitewiseColors.action,
                  borderStrokeWidth: 1,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: LatLng(lat, lon),
                  width: 48,
                  height: 48,
                  child: const Icon(
                    Icons.location_on,
                    color: SitewiseColors.action,
                    size: 40,
                  ),
                ),
              ],
            ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _locationDashboard(LocationAnalysis analysis) {
    final score = analysis.measuredScore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProviderCard(
          title: 'Location suitability',
          child: Row(
            children: [
              SizedBox(
                width: 92,
                height: 92,
                child: CircularProgressIndicator(
                  value: score == null
                      ? 0
                      : (score <= 1 ? score : score / 100).clamp(0, 1),
                  strokeWidth: 9,
                  backgroundColor: SitewiseM3.line,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      score == null
                          ? 'Score unavailable'
                          : '${(score <= 1 ? score * 100 : score).toStringAsFixed(1)} / 100',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Text(
                      'A relative location suitability measure, not a success probability.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        for (final group in analysis.measurementGroups)
          ProviderCard(
            title: group.title,
            child: Column(
              children: [
                for (final item in group.rows.where((row) => row.measured))
                  _visualMeasure(item.label, item.display, item.value!),
                if (!group.available)
                  const Text('Information is not available yet.'),
              ],
            ),
          ),
      ],
    );
  }

  Widget _visualMeasure(String label, String value, double amount) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(value),
          ],
        ),
        const SizedBox(height: 5),
        LinearProgressIndicator(
          value: (amount.abs() / (amount.abs() + 10)).clamp(0, 1),
          minHeight: 6,
        ),
      ],
    ),
  );

  Widget _section(String title, List<Widget> children) => ProviderCard(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );

  String _feet(double? value) =>
      value == null ? 'Not provided' : '${value.toStringAsFixed(1)} ft';
  String _money(double? value) =>
      value == null ? 'Not provided' : 'RM ${value.toStringAsFixed(2)}';
  String _ownerParking(bool? value) => value == null
      ? 'Not sure'
      : value
      ? 'Available (owner-declared)'
      : 'Not available (owner-declared)';
  String _lease(int? months, bool? negotiable) => negotiable == true
      ? 'Negotiable'
      : months == null
      ? 'Not provided'
      : '$months months';

  Widget _factRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 116,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              color: SitewiseM3.muted,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: SitewiseM3.ink,
            ),
          ),
        ),
      ],
    ),
  );
}

class _DetailData {
  final ProviderListing listing;
  final OwnerListing? owner;
  final AgentListingDetail? agent;

  /// Owner-managed or agent-managed, with the name the server supplies.
  final ProviderManagement management;

  const _DetailData({
    required this.listing,
    required this.management,
    this.owner,
    this.agent,
  });
}
