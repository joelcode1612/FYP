import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/dashboard/application/provider_dashboard_controller.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';

/// Owner-only: create an Agent request from a real owned property.
/// The server validates the Owner, Agent identity and property lifecycle.
class ProviderOwnerRequestsMobilePage extends ConsumerStatefulWidget {
  const ProviderOwnerRequestsMobilePage({super.key});
  @override
  ConsumerState<ProviderOwnerRequestsMobilePage> createState() =>
      _OwnerRequestsState();
}

class _OwnerRequestsState
    extends ConsumerState<ProviderOwnerRequestsMobilePage> {
  bool busy = false;
  String? error;
  String? uploadError;
  String? requestError;
  final proofStatuses = <int, String>{};
  final ownershipReviewStatuses = <int, String>{};
  final Map<int, String> statuses = {};
  final Map<int, String> agentNames = {};
  final Map<int, List<String>> missingDetails = {};
  int _refreshRevision = 0;

  @override
  void initState() {
    super.initState();
    ServiceLocator.listingsRevision.addListener(_reloadListings);
    refresh();
  }

  @override
  void dispose() {
    ServiceLocator.listingsRevision.removeListener(_reloadListings);
    super.dispose();
  }

  void _reloadListings() {
    ref.invalidate(providerDashboardProvider);
    refresh();
  }

  Future<void> refresh() async {
    final revision = ++_refreshRevision;
    if (mounted) setState(() => error = null);
    try {
      final rows = await ref.read(providerDashboardProvider.future);
      for (final property in rows.listings) {
        if (!mounted || revision != _refreshRevision) return;
        final r = await ServiceLocator.apiClient.get(
          '/api/v1/provider-flow/properties/${property.id}/assignment',
        );
        if (!mounted || revision != _refreshRevision) return;
        final data = r['data'];
        if (r.containsKey('ownership_proof_status')) {
          final proof = r['ownership_proof_status'];
          if (proof is String) {
            proofStatuses[property.id] = proof;
          } else {
            proofStatuses.remove(property.id);
          }
        }
        final ownershipStatus = r['ownership_review_status'];
        if (ownershipStatus is String) {
          ownershipReviewStatuses[property.id] = ownershipStatus;
        }
        final missing = r['missing_required_fields'];
        missingDetails[property.id] = missing is List
            ? missing.whereType<String>().toList()
            : [];
        if (data is Map) {
          statuses[property.id] = '${data['workflow_status'] ?? ''}';
          agentNames[property.id] = '${data['agent_name'] ?? 'Assigned Agent'}';
        } else {
          statuses.remove(property.id);
          agentNames.remove(property.id);
        }
      }
      if (mounted && revision == _refreshRevision) setState(() {});
    } catch (e) {
      if (mounted && revision == _refreshRevision) setState(() => error = '$e');
    }
  }

  // Load fresh eligibility when the sheet opens; never infer an Agent locally.
  Future<List<Map<String, dynamic>>> _loadAuthorizedAgents() async {
    final response = await ServiceLocator.apiClient.get(
      '/api/v1/provider-flow/agents',
    );
    final available = response['data'];
    if (available is! List) {
      throw StateError('Agent directory is unavailable.');
    }
    final unique = <String, Map<String, dynamic>>{};
    for (final row in available) {
      if (row is! Map) continue;
      final id = row['user_id']?.toString().trim() ?? '';
      final name = row['name']?.toString().trim() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      unique[id] = {'user_id': id, 'name': name};
    }
    final result = unique.values.toList();
    result.sort(
      (a, b) => (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      ),
    );
    return result;
  }

  Future<void> requestAgent(ProviderListing property) async {
    if (busy) return; // SITEWISE_AGENT_DETAILS_COMPLETION_V1
    if (proofStatuses[property.id] != 'active' ||
        !const {'pending', 'under_review', 'verified'}.contains(
          ownershipReviewStatuses[property.id],
        )) {
      setState(() => requestError = 'Upload and submit ownership proof before requesting an Agent.');
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: SitewiseColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _AgentSelectionSheet(
        property: property,
        loadAgents: _loadAuthorizedAgents,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      busy = true;
      requestError = null;
    });
    try {
      await ServiceLocator.apiClient.post(
        '/api/v1/provider-flow/properties/${property.id}/request-agent',
        {'agent_user_id': selected},
      );
      ref.invalidate(providerDashboardProvider);
      await refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Agent request sent. The Agent must accept it first.',
            ),
          ),
        );
      }
    } catch (e) {
      await refresh();
      if (mounted) {
        setState(
          () => requestError = readableFailure(
            e,
            fallback: 'The Agent request could not be sent.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> uploadOwnershipProof(ProviderListing property) async {
    if (busy) return;
    XFile? selected;
    try {
      selected = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Ownership documents',
            extensions: ['pdf', 'jpg', 'jpeg', 'png'],
            mimeTypes: ['application/pdf', 'image/jpeg', 'image/png'],
          ),
        ],
      );
    } catch (e) {
      if (mounted) {
        setState(() => uploadError = 'Unable to select a document: $e');
      }
      return;
    }

    if (selected == null || !mounted) return;
    final filename = selected.name;
    final name = filename.toLowerCase();
    if (!name.endsWith('.pdf') &&
        !name.endsWith('.jpg') &&
        !name.endsWith('.jpeg') &&
        !name.endsWith('.png')) {
      setState(() => uploadError = 'Choose a PDF, JPG, JPEG or PNG document.');
      return;
    }
    final contentType = name.endsWith('.pdf')
        ? 'application/pdf'
        : name.endsWith('.png')
        ? 'image/png'
        : 'image/jpeg';

    setState(() {
      busy = true;
      uploadError = null;
    });
    try {
      final bytes = await selected.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('The selected document is empty.');
      }
      final document = await ServiceLocator.propertyVerification.uploadDocument(
        propertyId: '${property.id}',
        upload: VerificationDocumentUpload(
          dimension: VerificationDimension.ownership,
          documentType: 'ownership_proof',
          filename: filename,
          bytes: bytes,
          contentType: contentType,
        ),
      );
      if (mounted) {
        setState(() => proofStatuses[property.id] = document.status);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ownership proof uploaded successfully'),
          ),
        );
      }
      if (!mounted) return;
      try {
        final view = await ServiceLocator.propertyVerification
            .statusForProperty('${property.id}');
        final stored = view.documents
            .where((item) => item.documentId == document.documentId)
            .firstOrNull;
        if (mounted && stored != null) {
          setState(() => proofStatuses[property.id] = stored.status);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                readableFailure(
                  e,
                  fallback: 'Could not refresh verification status.',
                ),
              ),
            ),
          );
        }
      }
    } catch (e) {
      // SITEWISE_READINESS_V1: preserve the FastAPI validation/authorization
      // error. A failed document upload is not a successful submission.
      if (mounted) {
        setState(
          () => uploadError = readableFailure(
            e,
            fallback:
                'Ownership proof could not be uploaded. Check the file, '
                'connection and server document-storage configuration.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // SITEWISE_OWNER_REQUESTS_COMPACT_V2
  // Compact presentation only. The backend still owns property/Agent statuses.
  int _selectedFilter = 0;

  bool _matchesStatus(ProviderListing property) => switch (_selectedFilter) {
    1 => property.stage == ProviderStage.draft,
    2 => property.stage == ProviderStage.pending,
    3 => property.isActive,
    _ => true,
  };

  Widget _statusFilters(List<ProviderListing> listings) {
    final options = <(String, int)>[
      ('All', listings.length),
      ('Draft', listings.where((p) => p.stage == ProviderStage.draft).length),
      (
        'In review',
        listings.where((p) => p.stage == ProviderStage.pending).length,
      ),
      ('Completed', listings.where((p) => p.isActive).length),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < options.length; index++) ...[
            if (index > 0) const SizedBox(width: 7),
            ChoiceChip(
              label: Text('${options[index].$1} (${options[index].$2})'),
              selected: _selectedFilter == index,
              showCheckmark: false,
              onSelected: (_) => setState(() => _selectedFilter = index),
              selectedColor: SitewiseColors.infoWash,
              backgroundColor: SitewiseColors.surface,
              side: BorderSide(
                color: _selectedFilter == index
                    ? SitewiseColors.action
                    : SitewiseColors.border,
              ),
              labelStyle: TextStyle(
                fontFamily: kFontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: _selectedFilter == index
                    ? SitewiseColors.action
                    : SitewiseColors.text,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.padded,
            ),
          ],
        ],
      ),
    );
  }

  Widget _thumbnailFallback() => Container(
    color: SitewiseColors.infoWash,
    alignment: Alignment.center,
    child: const Icon(
      Icons.storefront_outlined,
      size: 28,
      color: SitewiseColors.action,
    ),
  );

  Widget _propertyThumbnail(ProviderListing property) {
    final url = property.imageUrl?.trim() ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
      child: SizedBox(
        width: 74,
        height: 74,
        child: url.isEmpty
            ? _thumbnailFallback()
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _thumbnailFallback(),
              ),
      ),
    );
  }

  Widget _propertyOverview(ProviderListing property) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _propertyThumbnail(property),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '#${property.id}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      color: SitewiseColors.action,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ProviderStatusPill(stage: property.stage, compact: true),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              property.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: kFontFamily,
                color: SitewiseColors.ink,
                fontSize: 16,
                height: 1.18,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (property.address.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                property.address,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  height: 1.35,
                  color: SitewiseColors.muted,
                ),
              ),
            ],
            if (property.propertyType?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 3),
              Text(
                property.propertyType!.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  color: SitewiseColors.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );

  Widget _assignmentStatus(ProviderListing property) {
    final raw = statuses[property.id]?.trim().toLowerCase() ?? '';
    final agent = agentNames[property.id]?.trim();
    final (String label, Color foreground, Color background) = switch (raw) {
      'accepted' => (
        'Accepted',
        SitewiseColors.success,
        SitewiseColors.successWash,
      ),
      'submitted' => (
        'Submitted',
        SitewiseColors.success,
        SitewiseColors.successWash,
      ),
      'requested' => (
        'Awaiting Agent',
        SitewiseColors.warning,
        SitewiseColors.warningWash,
      ),
      '' => ('Not requested', SitewiseColors.muted, SitewiseColors.infoWash),
      _ => (
        raw.replaceAll('_', ' '),
        SitewiseColors.muted,
        SitewiseColors.infoWash,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.assignment_ind_outlined,
              color: SitewiseColors.action,
              size: 19,
            ),
            const SizedBox(width: 7),
            const Expanded(
              child: Text(
                'Agent request',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: SitewiseColors.ink,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(SitewiseSpacing.radiusXl),
              ),
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
            ),
          ],
        ),
        if (agent != null && agent.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Assigned Agent: $agent',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.35,
              color: SitewiseColors.muted,
            ),
          ),
        ],
      ],
    );
  }

  String? _nextStep(ProviderListing property) {
    if (property.isActive) return null;
    if (property.stage == ProviderStage.pending) {
      return 'Administrator review is in progress.';
    }
    final missing = missingDetails[property.id];
    if (missing != null && missing.isNotEmpty) {
      return 'The Agent can collect these missing details: ${missing.join(', ')}.';
    }
    final raw = statuses[property.id]?.trim().toLowerCase() ?? '';
    if (raw == 'accepted' || raw == 'submitted') return null;
    if (raw == 'requested') {
      return 'Your Agent must accept the request first.';
    }
    if (property.stage == ProviderStage.rejected) {
      return 'Review the feedback and update ownership proof if needed.';
    }
    return 'Upload and submit ownership proof, then request an inspection.';
  }

  Widget _nextStepHint(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    decoration: BoxDecoration(
      color: SitewiseColors.infoWash.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: SitewiseColors.action,
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.35,
              color: SitewiseColors.text,
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _submitOwnership(ProviderListing property) async {
    if (busy) return;
    setState(() {
      busy = true;
      uploadError = null;
    });
    try {
      await ServiceLocator.propertyVerification.submit(
        '${property.id}',
        scope: 'ownership',
      );
      if (mounted) {
        setState(() => ownershipReviewStatuses[property.id] = 'pending');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ownership proof submitted for review')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => uploadError = readableFailure(
          error,
          fallback: 'Ownership proof could not be submitted.',
        ));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _requestButtons(ProviderListing property) {
    final raw = statuses[property.id]?.trim().toLowerCase() ?? '';
    final outstanding = const <String>{
      'requested',
      'accepted',
      'submitted',
    }.contains(raw);
    final uploadButton = OutlinedButton.icon(
      onPressed: busy ? null : () => uploadOwnershipProof(property),
      icon: const Icon(Icons.upload_file_outlined, size: 18),
      label: const Text('Upload proof', maxLines: 1),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        foregroundColor: SitewiseColors.action,
        side: const BorderSide(color: SitewiseColors.action),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
    );
    final missing = missingDetails[property.id];
    final ownershipStatus = ownershipReviewStatuses[property.id] ?? 'not_submitted';
    final proofActions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        uploadButton,
        if (ownershipStatus != 'not_submitted')
          Text('Ownership review: ${ownershipStatus.replaceAll('_', ' ')}'),
        if (proofStatuses[property.id] == 'active' &&
            const {'not_submitted', 'rejected', 'information_requested'}.contains(ownershipStatus))
          OutlinedButton(
            onPressed: busy ? null : () => _submitOwnership(property),
            child: const Text('Submit ownership verification'),
          ),
      ],
    );
    if (outstanding) return proofActions;
    final proofReady = proofStatuses[property.id] == 'active' &&
        const {'pending', 'under_review', 'verified'}.contains(ownershipStatus);
    final requestButton = FilledButton.icon(
      onPressed: busy || missing == null || !proofReady
          ? null
          : () => requestAgent(property),
      icon: const Icon(Icons.assignment_ind_outlined, size: 18),
      label: const Text('Request Agent', maxLines: 1),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        backgroundColor: SitewiseColors.action,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 325) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [proofActions, const SizedBox(height: 8), requestButton],
          );
        }
        return Row(
          children: [
            Expanded(child: proofActions),
            const SizedBox(width: 8),
            Expanded(child: requestButton),
          ],
        );
      },
    );
  }

  Widget _requestCard(ProviderListing property) {
    final editable =
        property.stage == ProviderStage.draft ||
        property.stage == ProviderStage.rejected;
    final next = _nextStep(property);
    return ProviderCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _propertyOverview(property),
          if (proofStatuses[property.id] case final status?)
            Text('Ownership proof: $status'),
          const SizedBox(height: 12),
          const Divider(height: 1, color: SitewiseColors.border),
          const SizedBox(height: 11),
          _assignmentStatus(property),
          if (next != null) ...[
            const SizedBox(height: 10),
            _nextStepHint(next),
          ],
          if (editable) ...[
            const SizedBox(height: 12),
            _requestButtons(property),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(providerDashboardProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(providerDashboardProvider);
        await refresh();
      },
      child: data.when(
        loading: providerLoadingView,
        error: (e, _) => providerContent(
          children: [
            ProviderMessage(
              title: 'Owned properties unavailable',
              body: '$e',
              onRetry: () => ref.invalidate(providerDashboardProvider),
            ),
          ],
        ),
        data: (workspace) {
          final visible = workspace.listings.where(_matchesStatus).toList();
          return providerContent(
            children: [
              const Text('Agent requests', style: SitewiseM3Type.h1),
              const SizedBox(height: 5),
              const Text(
                'Manage Agent assignments and inspection progress.',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  height: 1.4,
                  color: SitewiseColors.muted,
                ),
              ),
              const SizedBox(height: 12),
              _statusFilters(workspace.listings),
              if (uploadError != null)
                ProviderMessage(
                  title: 'Ownership proof upload failed',
                  body: uploadError!,
                ),
              if (requestError != null)
                ProviderMessage(
                  title: 'Agent request failed',
                  body: requestError!,
                ),
              if (error != null) ...[
                const SizedBox(height: 10),
                ProviderMessage(
                  title: 'Agent request status unavailable',
                  body: error!,
                  onRetry: refresh,
                  icon: Icons.warning_amber_rounded,
                ),
              ],
              const SizedBox(height: 12),
              if (workspace.listings.isEmpty)
                const ProviderMessage(
                  title: 'No registered properties',
                  body:
                      'Register a commercial property before requesting an Agent.',
                )
              else if (visible.isEmpty)
                const ProviderMessage(
                  title: 'No matching properties',
                  body: 'Choose a different filter to see your properties.',
                  icon: Icons.filter_list_off_rounded,
                )
              else
                for (final property in visible) ...[
                  _requestCard(property),
                  const SizedBox(height: 10),
                ],
            ],
          );
        },
      ),
    );
  }
}

// SITEWISE_AGENT_SELECTION_SHEET_V1
class _AgentSelectionSheet extends StatefulWidget {
  const _AgentSelectionSheet({
    required this.property,
    required this.loadAgents,
  });

  final ProviderListing property;
  final Future<List<Map<String, dynamic>>> Function() loadAgents;

  @override
  State<_AgentSelectionSheet> createState() => _AgentSelectionSheetState();
}

class _AgentSelectionSheetState extends State<_AgentSelectionSheet> {
  late Future<List<Map<String, dynamic>>> _directory;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _directory = widget.loadAgents();
  }

  void _retry() {
    setState(() {
      _selected = null;
      _directory = widget.loadAgents();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .78,
          ),
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _directory,
            builder: (context, snapshot) {
              final loading = snapshot.connectionState != ConnectionState.done;
              final directory = snapshot.data ?? const <Map<String, dynamic>>[];
              final canSend =
                  !loading &&
                  !snapshot.hasError &&
                  _selected != null &&
                  directory.any((a) => a['user_id'] == _selected);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Select an agent',
                                style: SitewiseM3Type.h1,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close agent selection',
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                        const Text(
                          'Choose an authorized agent to inspect your property.',
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.45,
                            color: SitewiseColors.muted,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: SitewiseColors.action.withValues(alpha: .06),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.storefront_outlined,
                                color: SitewiseColors.action,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.property.displayTitle,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: SitewiseColors.ink,
                                      ),
                                    ),
                                    if (widget.property.address
                                        .trim()
                                        .isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        widget.property.address,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          height: 1.4,
                                          color: SitewiseColors.muted,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Available agents',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: SitewiseColors.ink,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (loading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (snapshot.hasError || directory.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              border: Border.all(color: SitewiseColors.border),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  snapshot.hasError
                                      ? Icons.cloud_off_outlined
                                      : Icons.person_search_outlined,
                                  size: 32,
                                  color: SitewiseColors.muted,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  snapshot.hasError
                                      ? 'Unable to load agents'
                                      : 'No authorized agents available',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: SitewiseColors.ink,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  snapshot.hasError
                                      ? 'Check your connection and try again.'
                                      : 'Try again later or contact the administrator.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.4,
                                    color: SitewiseColors.muted,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: _retry,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('Retry'),
                                ),
                              ],
                            ),
                          )
                        else
                          for (final agent in directory) ...[
                            _agentRow(agent),
                            const SizedBox(height: 8),
                          ],
                        const SizedBox(height: 14),
                        const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 19,
                              color: SitewiseColors.muted,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Your selected agent must accept the request before proceeding with the inspection.',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  color: SitewiseColors.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: canSend
                        ? () => Navigator.of(context).pop(_selected)
                        : null,
                    child: const Text('Send request'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _agentRow(Map<String, dynamic> agent) {
    final id = agent['user_id'] as String;
    final name = agent['name'] as String;
    final active = _selected == id;
    return Semantics(
      button: true,
      selected: active,
      child: Material(
        color: active
            ? SitewiseColors.action.withValues(alpha: .07)
            : SitewiseColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: active ? SitewiseColors.action : SitewiseColors.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _selected = id),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: SitewiseColors.infoWash,
                  foregroundColor: SitewiseColors.action,
                  child: Icon(Icons.person_outline_rounded),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: SitewiseColors.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Authorized property agent',
                        style: TextStyle(
                          fontSize: 14,
                          color: SitewiseColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  active
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: active ? SitewiseColors.action : SitewiseColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
