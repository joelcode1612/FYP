import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/capture_360/presentation/pages/ar_capture_mobile_page.dart';
import 'package:fyp/shared/presentation/components/m3_kit.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
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
  const ProviderPropertyDetailMobilePage({super.key, required this.listingId});

  final int listingId;

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

  Future<void> _capture() async {
    await Navigator.of(context).pushNamed(
      '/owner/capture',
      arguments: ArCaptureRequest(
        propertyId: '${widget.listingId}',
        title: (_future == null) ? null : null,
      ),
    );
    if (mounted) _load();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final result = await ServiceLocator.propertyVerification.submit(
        '${widget.listingId}',
      );
      ServiceLocator.listingsRevision.value++;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Submitted for verification. Current state: '
            '${result.listingStatus.wire}.',
          ),
        ),
      );
      _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not submit: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    return Scaffold(
      backgroundColor: providerCanvas,
      appBar: const ProviderPageAppBar(
        title: 'Property',
        eyebrow: 'LISTING DETAIL',
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
              const M3ScreenHeading(
                eyebrow: 'Managed listing',
                title: 'Property details.',
                lead:
                    'Facts and workflow steps for one record in your '
                    'authorized scope.',
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      listing.displayTitle,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                  ProviderStatusPill(stage: listing.stage),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                listing.address.isEmpty ? 'Address not set' : listing.address,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  color: SitewiseM3.muted,
                ),
              ),
              const SizedBox(height: 18),
              _section('Listing facts', [
                // Management first: it answers "whose listing is this", which
                // is the question an owner/agent screen has to settle before
                // any other fact.
                _factRow('Managed by', data.management.display),
                _factRow('Monthly rent', listing.rentDisplay),
                _factRow('Built-up area', listing.sizeDisplay),
                if (listing.psfDisplay.isNotEmpty)
                  _factRow('Rate', listing.psfDisplay),
                _factRow('Type', listing.propertyType ?? 'Not provided'),
                _factRow(
                  'Publication',
                  listing.isPublished ? 'Published' : 'Not published',
                ),
                if (data.agent?.owner != null)
                  _factRow(
                    'Instructing party',
                    data.agent!.owner!.displayName.isEmpty
                        ? 'Not recorded'
                        : data.agent!.owner!.displayName,
                  ),
                if (data.agent?.openRequest != null)
                  _factRow(
                    'Open change request',
                    data.agent!.openRequest!.status,
                  ),
              ]),
              if (data.owner != null &&
                  (data.owner!.description ?? '').isNotEmpty) ...[
                const SizedBox(height: 16),
                _section('Description', [
                  Text(
                    data.owner!.description!,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12.5,
                      height: 1.55,
                      color: SitewiseM3.ink,
                    ),
                  ),
                ]),
              ],
              if (data.agent != null) ...[
                const SizedBox(height: 16),
                _section('Activity', [
                  if (data.agent!.photos.isNotEmpty)
                    Text(
                      '${data.agent!.photos.length} photograph(s) on the listing',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12.5,
                        color: SitewiseM3.ink,
                      ),
                    )
                  else
                    const Text(
                      'No photographs stored for this listing yet.',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12.5,
                        color: SitewiseM3.muted,
                      ),
                    ),
                ]),
              ],
              const SizedBox(height: 18),
              ProviderCard(
                title: data.agent != null
                    ? 'On-site physical verification'
                    : 'Owner preparation',
                child: Text(
                  data.agent != null
                      ? 'Compare the recorded floor area, condition, parking '
                            'and access with what you observe on site. Use '
                            'Propose a change for discrepancies; this does '
                            'not overwrite the Owner record. Capture the '
                            '360° tour below.'
                      : 'Keep your ownership evidence, property details and '
                            'photos ready. You can capture a 360° tour yourself. '
                            'The Administrator makes the publication decision.',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 14,
                    height: 1.5,
                    color: SitewiseM3.muted,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _capture,
                icon: const Icon(Icons.threesixty_rounded),
                label: const Text('Capture 360° panorama'),
                style: FilledButton.styleFrom(
                  backgroundColor: SitewiseColors.action,
                  foregroundColor: SitewiseM3.surface,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (data.agent != null)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _requestChange,
                  icon: const Icon(Icons.edit_note_rounded),
                  label: const Text('Propose a change'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                )
              else ...[
                OutlinedButton.icon(
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
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit listing'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy || listing.stage == ProviderStage.pending
                      ? null
                      : _submit,
                  icon: const Icon(Icons.verified_outlined),
                  label: Text(
                    listing.stage == ProviderStage.pending
                        ? 'Awaiting administrator review'
                        : 'Submit for verification',
                  ),
                style: FilledButton.styleFrom(
                  backgroundColor: SitewiseColors.action,
                  foregroundColor: SitewiseM3.surface,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                  ),
                ),
                ),
              ],
            ],
          );
        },
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => ProviderCard(
    title: title,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );

  Widget _factRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 125,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: SitewiseM3.muted,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12.5,
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
