import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/features/property_management/presentation/widgets/provider_agent_inspection_panel.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';
import 'package:fyp/features/property_management/data/provider_workspace_service.dart';
import 'package:fyp/features/property_management/application/provider_listings_service.dart';

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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final role = ref.read(authNotifierProvider).user?.role ?? AppRole.owner;
    final request = _loadDetail(role);
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
            );
          }
          final error = snapshot.error;
          return Scaffold(
            appBar: const ProviderPageAppBar(
              title: 'Property inspection',
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
      appBar: const ProviderPageAppBar(
        title: 'Property details',
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
            return providerContent(
              children: [
                // SiteWise property-details-first design (2026-11-21).
                _propertyHero(listing),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _metricTile(
                        'MONTHLY RENT',
                        listing.rentDisplay,
                        Icons.payments_outlined,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _metricTile(
                        'BUILT-UP AREA',
                        listing.sizeDisplay,
                        Icons.square_foot_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
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
                if ((listing.imageUrl ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _propertyPhoto(listing.imageUrl!),
                ],
                const SizedBox(height: 20),
                if (data.agent case final agent?) ...[
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ProviderAgentInspectionPanel(
                            propertyId: listing.id,
                            listing: listing,
                            inspectionDetail: agent,
                          ),
                        ),
                      );
                      if (mounted) await _load();
                    },
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Inspect property'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _requestChange,
                    icon: const Icon(Icons.edit_note_rounded),
                    label: const Text('Propose a change'),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: _busy || !listing.canEdit || listing.isPublished
                        ? null
                        : () => Navigator.of(context)
                              .pushNamed(
                                '/provider/add-property',
                                arguments: '${widget.listingId}',
                              )
                              .then((_) {
                                if (mounted) _load();
                              }),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit listing'),
                    style: FilledButton.styleFrom(
                      backgroundColor: SitewiseColors.action,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                  ),
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

  Widget _section(String title, List<Widget> children) => ProviderCard(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );

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
