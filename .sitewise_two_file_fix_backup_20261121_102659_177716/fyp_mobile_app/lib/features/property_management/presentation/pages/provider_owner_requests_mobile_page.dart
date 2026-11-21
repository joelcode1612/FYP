import 'package:file_picker/file_picker.dart';
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
  List<Map<String, dynamic>> agents = const [];
  bool busy = false;
  String? error;
  final Map<int, String> statuses = {};
  final Map<int, String> agentNames = {};

  @override
  void initState() { super.initState(); refresh(); }

  Future<void> refresh() async {
    try {
      final response = await ServiceLocator.apiClient.get('/api/v1/provider-flow/agents');
      final available = response['data'];
      if (available is! List) throw StateError('Agent directory is unavailable.');
      if (!mounted) return;
      setState(() {
        agents = available.whereType<Map<String, dynamic>>().toList();
        error = null;
      });
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

  Future<void> requestAgent(ProviderListing property) async {
    if (busy) return;
    String? chosen;
    final selected = await showDialog<String>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, change) => AlertDialog(
        title: const Text('Assign authorized Agent'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(property.displayTitle),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: chosen,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Property Agent'),
            items: agents.map((a) => DropdownMenuItem<String>(
              value: '${a['user_id']}',
              child: Text('${a['name']}', overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (v) => change(() => chosen = v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: chosen == null ? null : () => Navigator.pop(ctx, chosen),
            child: const Text('Send request')),
        ],
      )));
    if (selected == null || !mounted) return;
    setState(() { busy = true; error = null; });
    try {
      await ServiceLocator.apiClient.post(
        '/api/v1/provider-flow/properties/${property.id}/request-agent',
        {'agent_user_id': selected},
      );
      ref.invalidate(providerDashboardProvider);
      await refresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Agent request sent. The Agent must accept it first.'),
      ));
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> uploadOwnershipProof(ProviderListing property) async {
    if (busy) return;
    final pick = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['pdf','jpg','jpeg','png'],
      withData: true,
    );
    if (pick == null || pick.files.isEmpty || !mounted) return;
    final selected = pick.files.first;
    if (selected.bytes == null) {
      setState(() => error = 'Could not read the selected file. Try another document.');
      return;
    }
    final name = selected.name.toLowerCase();
    final contentType = name.endsWith('.pdf') ? 'application/pdf'
        : name.endsWith('.png') ? 'image/png' : 'image/jpeg';
    setState(() { busy = true; error = null; });
    try {
      await ServiceLocator.propertyVerification.uploadDocument(
        propertyId: '${property.id}',
        dimension: VerificationDimension.ownership,
        documentType: 'ownership_proof',
        filename: selected.name,
        bytes: selected.bytes!,
        contentType: contentType,
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Ownership proof uploaded securely for Admin review.'),
      ));
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
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
                    onPressed: busy || agents.isEmpty ||
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
