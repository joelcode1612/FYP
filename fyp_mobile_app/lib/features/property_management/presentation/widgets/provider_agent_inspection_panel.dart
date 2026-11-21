import 'package:flutter/material.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';

/// Agent-only actions over the server-authorized assignment.
class ProviderAgentInspectionPanel extends StatefulWidget {
  const ProviderAgentInspectionPanel({super.key, required this.propertyId,
      required this.onCapture, required this.onSubmitted});
  final int propertyId;
  final Future<void> Function() onCapture;
  final Future<void> Function() onSubmitted;
  @override
  State<ProviderAgentInspectionPanel> createState() => _InspectionState();
}

class _InspectionState extends State<ProviderAgentInspectionPanel> {
  String get url => '/api/v1/provider-flow/properties/${widget.propertyId}';
  String status = '';
  String? error;
  bool busy = false, loading = true, uploaded = false, saved = false;
  final checks = <String, bool>{
    'floor_area_verified': false, 'condition_verified': false,
    'parking_verified': false, 'accessibility_verified': false,
  };
  final note = TextEditingController();
  final floorArea = TextEditingController();
  final parkingNotes = TextEditingController();
  final accessNotes = TextEditingController();
  bool get editable => status == 'accepted' || status == 'needs_correction';
  bool get ready => saved && checks.values.every((value) => value) && uploaded;

  @override
  void initState() { super.initState(); refresh(); }
  @override
  void dispose() { note.dispose(); floorArea.dispose(); parkingNotes.dispose(); accessNotes.dispose(); super.dispose(); }

  Future<void> refresh() async {
    if (!mounted) return;
    setState(() { loading = true; error = null; });
    try {
      final response = await ServiceLocator.apiClient.get('$url/inspection');
      final data = response['data'] as Map<String, dynamic>;
      final form = (data['checklist'] as Map?) ?? {};
      if (!mounted) return;
      setState(() {
        status = '${data['assignment_status'] ?? ''}';
        saved = data['checklist'] is Map && (data['checklist'] as Map).isNotEmpty;
        uploaded = data['panorama_uploaded'] == true;
        for (final key in checks.keys) { checks[key] = form[key] == true; }
        note.text = '${form['condition_notes'] ?? ''}';
        floorArea.text = '${form['observed_floor_area_sqft'] ?? ''}';
        parkingNotes.text = '${form['parking_notes'] ?? ''}';
        accessNotes.text = '${form['accessibility_notes'] ?? ''}';
      });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => loading = false); }
  }

  Future<void> command(String action, [Map<String, dynamic>? body]) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await ServiceLocator.apiClient.post('$url/$action', body ?? {});
      if (action == 'submit') await widget.onSubmitted();
      await refresh();
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> save() async {
    if (busy || !editable) return;
    setState(() { busy = true; error = null; });
    try {
      await ServiceLocator.apiClient.patch('$url/inspection', {
        ...checks, 'condition_notes': note.text.trim(),
        'observed_floor_area_sqft': double.tryParse(floorArea.text.trim()),
        'parking_notes': parkingNotes.text.trim(),
        'accessibility_notes': accessNotes.text.trim(),
      });
      if (mounted) setState(() => saved = true);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Inspection saved.')),
      );
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> decline() async {
    final controller = TextEditingController();
    try {
      final ok = await showDialog<bool>(context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Decline assignment'),
          content: TextField(controller: controller, maxLines: 2,
            decoration: const InputDecoration(labelText: 'Reason')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Decline')),
          ],
        ));
      if (ok == true && controller.text.trim().length >= 2) {
        await command('decline', {'reason': controller.text.trim()});
      }
    } finally { controller.dispose(); }
  }

  @override
  Widget build(BuildContext context) => ProviderCard(
    title: 'On-site verification & 360° tour',
    child: loading ? const Center(child: CircularProgressIndicator())
    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Request: ${status.replaceAll('_', ' ')}',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      if (error != null) ...[
        const SizedBox(height: 8),
        Text(error!, style: const TextStyle(color: SitewiseColors.danger)),
        TextButton(onPressed: refresh, child: const Text('Retry')),
      ],
      if (status == 'requested') ...[
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: busy ? null : () => command('accept'),
          icon: const Icon(Icons.check), label: const Text('Accept request')),
        OutlinedButton(onPressed: busy ? null : decline,
          child: const Text('Decline request')),
      ],
      if (editable) ...[
        const SizedBox(height: 12),
        const Text('Confirm your physical inspection against Owner details.',
          style: TextStyle(fontWeight: FontWeight.w700)),
        for (final entry in checks.entries)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: SitewiseColors.action,
            value: entry.value,
            onChanged: busy ? null : (v) => setState(() { checks[entry.key] = v ?? false; saved = false; }),
            title: Text(switch (entry.key) {
              'floor_area_verified' => 'Floor area verified',
              'condition_verified' => 'Physical condition verified',
              'parking_verified' => 'Parking verified',
              _ => 'Access / entrance verified',
            }),
          ),
        TextField(controller: note, maxLines: 3,
          onChanged: (_) => setState(() => saved = false),
          decoration: const InputDecoration(labelText: 'Inspection findings / discrepancies')),
        const SizedBox(height: 10),
        TextField(controller: floorArea, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() => saved = false),
          decoration: const InputDecoration(labelText: 'Observed floor area (sq ft, optional)')),
        const SizedBox(height: 10),
        TextField(controller: parkingNotes, maxLines: 2,
          onChanged: (_) => setState(() => saved = false),
          decoration: const InputDecoration(labelText: 'Parking inspection notes')),
        const SizedBox(height: 10),
        TextField(controller: accessNotes, maxLines: 2,
          onChanged: (_) => setState(() => saved = false),
          decoration: const InputDecoration(labelText: 'Access / entrance inspection notes')),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: busy ? null : save,
          icon: const Icon(Icons.save_outlined), label: const Text('Save checklist')),
        const SizedBox(height: 14),
        Text(uploaded ? '360° panorama uploaded to SiteWise.'
            : '360° panorama not uploaded. Capture required.',
          style: TextStyle(color: uploaded ? SitewiseColors.success : SitewiseColors.muted)),
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: busy ? null : () async {
          await widget.onCapture();
          await refresh();
        }, icon: const Icon(Icons.threesixty),
          label: const Text('Capture / retake 360° tour')),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: !ready || busy ? null : () => command('submit'),
          icon: const Icon(Icons.send_outlined),
          label: const Text('Confirm Verification & Submit to Admin')),
        if (!ready) const Padding(padding: EdgeInsets.only(top: 8),
          child: Text('Save all four checks and upload the 360° panorama.',
            style: TextStyle(color: SitewiseColors.muted))),
      ],
      if (status == 'submitted') const Text('Submitted for Admin review. Locked.'),
      if (status == 'declined') const Text('Request declined; Owner can reassign.'),
    ]),
  );
}
