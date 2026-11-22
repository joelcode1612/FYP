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
  ConsumerState<ProviderOwnerRequestsMobilePage> createState() => _OwnerRequestsState();
}

class _OwnerRequestsState extends ConsumerState<ProviderOwnerRequestsMobilePage> {
  bool busy = false;
  String? error;
  final Map<int, String> statuses = {};
  final Map<int, String> agentNames = {};

  @override
  void initState() { super.initState(); refresh(); }

  Future<void> refresh() async {
    if (mounted) setState(() => error = null);
    try {
      final rows = await ref.read(providerDashboardProvider.future);
      for (final property in rows.listings) {
        final r = await ServiceLocator.apiClient.get(
          '/api/v1/provider-flow/properties/${property.id}/assignment');
        if (!mounted) return;
        final data = r['data'];
        if (data is Map) {
          statuses[property.id] = '${data['workflow_status'] ?? ''}';
          agentNames[property.id] = '${data['agent_name'] ?? 'Assigned Agent'}';
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  // Load fresh eligibility when the sheet opens; never infer an Agent locally.
  Future<List<Map<String, dynamic>>> _loadAuthorizedAgents() async {
    final response = await ServiceLocator.apiClient.get('/api/v1/provider-flow/agents');
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
    result.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    return result;
  }

  Future<void> requestAgent(ProviderListing property) async {
    if (busy) return;
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
    setState(() { busy = true; error = null; });
    try {
      await ServiceLocator.apiClient.post(
        '/api/v1/provider-flow/properties/${property.id}/request-agent',
        {'agent_user_id': selected},
      );
      ref.invalidate(providerDashboardProvider);
      await refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Agent request sent. The Agent must accept it first.'),
        ));
      }
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
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
        setState(() => error = 'Unable to select a document: $e');
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
      setState(() => error = 'Choose a PDF, JPG, JPEG or PNG document.');
      return;
    }
    final contentType = name.endsWith('.pdf')
        ? 'application/pdf'
        : name.endsWith('.png')
            ? 'image/png'
            : 'image/jpeg';

    setState(() {
      busy = true;
      error = null;
    });
    try {
      final bytes = await selected.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('The selected document is empty.');
      }
      await ServiceLocator.propertyVerification.uploadDocument(
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ownership proof uploaded securely for Admin review.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(providerDashboardProvider);
    return RefreshIndicator(
      onRefresh: () async { ref.invalidate(providerDashboardProvider); await refresh(); },
      child: data.when(
        loading: providerLoadingView,
        error: (e, _) => providerContent(children: [
          ProviderMessage(title: 'Owned properties unavailable', body: '$e',
              onRetry: () => ref.invalidate(providerDashboardProvider)),
        ]),
        data: (workspace) => providerContent(children: [
          const Text('Agent requests', style: SitewiseM3Type.h1),
          const SizedBox(height: 8),
          const Text('Upload ownership proof, choose an authorized Agent and follow the verification progress.',
            style: TextStyle(fontSize: 14, height: 1.5, color: SitewiseColors.muted)),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: const TextStyle(color: SitewiseColors.danger)),
            TextButton(onPressed: refresh, child: const Text('Retry')),
          ],
          const SizedBox(height: 18),
          if (workspace.listings.isEmpty) const ProviderMessage(
            title: 'No registered properties',
            body: 'Register a commercial property before requesting an Agent.',
          ),
          for (final property in workspace.listings) ...[
            ProviderCard(title: property.displayTitle, child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(property.address.isEmpty ? 'Address not set' : property.address,
                  style: const TextStyle(fontSize: 14, color: SitewiseColors.muted)),
                const SizedBox(height: 6),
                ProviderStatusPill(stage: property.stage),
                const SizedBox(height: 8),
                Text('Agent request: ${statuses[property.id]?.replaceAll('_', ' ') ?? 'Not requested'}',
                  style: const TextStyle(fontSize: 14, color: SitewiseM3.ink)),
                if (agentNames[property.id] != null)
                  Text('Assigned Agent: ${agentNames[property.id]}',
                    style: const TextStyle(fontSize: 13, color: SitewiseColors.muted)),
                if (property.stage == ProviderStage.draft ||
                    property.stage == ProviderStage.rejected) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => uploadOwnershipProof(property),
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('Upload ownership proof')),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: busy ||
                        ['requested','accepted','submitted'].contains(statuses[property.id])
                        ? null : () => requestAgent(property),
                    icon: const Icon(Icons.assignment_ind_outlined),
                    label: const Text('Request Agent inspection')),
                ],
                if (property.isActive)
                  const Text('Published: property and approved 360° tour are read-only.'),
                if (property.stage == ProviderStage.pending)
                  const Text('Submitted by Agent; awaiting Admin decision.'),
              ],
            )),
            const SizedBox(height: 12),
          ],
        ]),
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
              final canSend = !loading && !snapshot.hasError &&
                  _selected != null && directory.any((a) => a['user_id'] == _selected);
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
                              child: Text('Select an agent', style: SitewiseM3Type.h1),
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
                          style: TextStyle(fontSize: 16, height: 1.45, color: SitewiseColors.muted),
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
                              const Icon(Icons.storefront_outlined, color: SitewiseColors.action),
                              const SizedBox(width: 12),
                              Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(widget.property.displayTitle,
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: SitewiseColors.ink)),
                                  if (widget.property.address.trim().isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(widget.property.address,
                                      style: const TextStyle(fontSize: 14, height: 1.4, color: SitewiseColors.muted)),
                                  ],
                                ],
                              )),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text('Available agents', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: SitewiseColors.ink)),
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
                            child: Column(children: [
                              Icon(snapshot.hasError ? Icons.cloud_off_outlined : Icons.person_search_outlined,
                                size: 32, color: SitewiseColors.muted),
                              const SizedBox(height: 10),
                              Text(snapshot.hasError ? 'Unable to load agents' : 'No authorized agents available',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: SitewiseColors.ink)),
                              const SizedBox(height: 6),
                              Text(snapshot.hasError ? 'Check your connection and try again.' : 'Try again later or contact the administrator.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 14, height: 1.4, color: SitewiseColors.muted)),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: _retry,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Retry'),
                              ),
                            ]),
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
                            Icon(Icons.info_outline, size: 19, color: SitewiseColors.muted),
                            SizedBox(width: 8),
                            Expanded(child: Text(
                              'Your selected agent must accept the request before proceeding with the inspection.',
                              style: TextStyle(fontSize: 14, height: 1.4, color: SitewiseColors.muted),
                            )),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: canSend ? () => Navigator.of(context).pop(_selected) : null,
                    child: const Text('Send request'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
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
        color: active ? SitewiseColors.action.withValues(alpha: .07) : SitewiseColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: active ? SitewiseColors.action : SitewiseColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _selected = id),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const CircleAvatar(
                backgroundColor: SitewiseColors.infoWash,
                foregroundColor: SitewiseColors.action,
                child: Icon(Icons.person_outline_rounded),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: SitewiseColors.ink)),
                  const SizedBox(height: 4),
                  const Text('Authorized property agent', style: TextStyle(fontSize: 14, color: SitewiseColors.muted)),
                ],
              )),
              const SizedBox(width: 10),
              Icon(active ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: active ? SitewiseColors.action : SitewiseColors.muted),
            ]),
          ),
        ),
      ),
    );
  }
}
