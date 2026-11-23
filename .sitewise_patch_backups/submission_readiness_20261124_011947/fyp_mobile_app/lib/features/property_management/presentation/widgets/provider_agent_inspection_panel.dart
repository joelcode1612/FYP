import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/features/capture_360/presentation/pages/ar_capture_mobile_page.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/features/property_management/presentation/widgets/provider_panorama_tour_section.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_confirm_dialog.dart';

/// Agent-only actions over the server-authorized assignment.
class ProviderAgentInspectionPanel extends StatefulWidget {
  const ProviderAgentInspectionPanel({
    super.key,
    required this.propertyId,
    this.listing,
    this.onSaved,
    this.onEdited,
    this.inspectionDetail,
  });
  final ProviderListing? listing;
  final int propertyId;
  final Future<void> Function()? onSaved;
  final VoidCallback? onEdited;
  final AgentListingDetail? inspectionDetail;
  @override
  State<ProviderAgentInspectionPanel> createState() => _InspectionState();
}

class _InspectionState extends State<ProviderAgentInspectionPanel> {
  String get url => '/api/v1/provider-flow/properties/${widget.propertyId}';
  String status = '';
  String? error;
  bool busy = false, loading = true, saved = false;
  bool canCapture = false;
  String? panoramaId;
  List<String> missingPropertyDetails = const [];
  Timer? _readinessTimer;
  int tourRevision = 0;
  bool get standalone => widget.inspectionDetail != null;
  final checks = <String, bool>{
    'floor_area_verified': false,
    'condition_verified': false,
    'parking_verified': false,
    'accessibility_verified': false,
  };
  final note = TextEditingController();
  final floorArea = TextEditingController();
  final parkingNotes = TextEditingController();
  final accessNotes = TextEditingController();
  bool get editable => status == 'accepted' || status == 'needs_correction';
  int get confirmed => checks.values.where((value) => value).length;
  bool get allConfirmed => confirmed == checks.length;
  bool get canUseCapture => canCapture && !busy && !loading;
  // SITEWISE_AGENT_INSPECTION_SUMMARY_V1
  // The four backend-confirmed checks are authoritative; not an eight-item
  // synthetic checklist. A discrepancy is recorded without erasing notes.
  static const labels = {
    'floor_area_verified': 'Floor area',
    'condition_verified': 'Physical condition',
    'parking_verified': 'Parking',
    'accessibility_verified': 'Access & entrance',
  };
  String reference(String key) => switch (key) {
    'floor_area_verified' =>
      widget.listing?.sizeSqft == null
          ? 'Check the unit size against the property information.'
          : 'Owner stated ${widget.listing!.sizeDisplay}; verify on site.',
    'condition_verified' =>
      'Inspect the space and report any differences.',
    'parking_verified' => 'Check actual parking access and conditions.',
    _ => 'Check entrance, visibility and physical access.',
  };

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    _readinessTimer?.cancel();
    note.dispose();
    floorArea.dispose();
    parkingNotes.dispose();
    accessNotes.dispose();
    super.dispose();
  }

  Future<void> refresh({bool loadChecklist = true}) async {
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final response = await ServiceLocator.apiClient.get('$url/inspection');
      final data = response['data'] as Map<String, dynamic>;
      final form = (data['checklist'] as Map?) ?? {};
      if (!mounted) return;
      setState(() {
        status = '${data['assignment_status'] ?? ''}';
        canCapture = data['can_capture'] == true;
        updateTourEligibility(data);
        if (!loadChecklist) return;
        saved =
            data['checklist'] is Map && (data['checklist'] as Map).isNotEmpty;
        for (final key in checks.keys) {
          checks[key] = form[key] == true;
        }
        note.text = '${form['condition_notes'] ?? ''}';
        floorArea.text = '${form['observed_floor_area_sqft'] ?? ''}';
        parkingNotes.text = '${form['parking_notes'] ?? ''}';
        accessNotes.text = '${form['accessibility_notes'] ?? ''}';
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => error = readableFailure(
            e,
            fallback: 'The inspection status could not be loaded.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> command(String action, [Map<String, dynamic>? body]) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ServiceLocator.apiClient.post('$url/$action', body ?? {});
      await refresh();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = readableFailure(
            e,
            fallback: 'The request could not be completed.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> save({bool announce = true}) async {
    if (busy || !editable) return false;
    final rawArea = floorArea.text.trim();
    final observedArea = double.tryParse(rawArea);
    if (rawArea.isNotEmpty &&
        (observedArea == null ||
            !observedArea.isFinite ||
            observedArea <= 0 ||
            observedArea > 10000000)) {
      setState(
        () => error =
            'Enter a valid observed area in square feet, or leave it blank.',
      );
      return false;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ServiceLocator.apiClient.patch('$url/inspection', {
        ...checks,
        'condition_notes': note.text.trim(),
        'observed_floor_area_sqft': observedArea,
        'parking_notes': parkingNotes.text.trim(),
        'accessibility_notes': accessNotes.text.trim(),
      });
      if (mounted) setState(() => saved = true);
      if (mounted && announce) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Inspection saved.')));
      }
      await widget.onSaved?.call();
      return true;
    } catch (e) {
      if (mounted) {
        setState(
          () => error = readableFailure(
            e,
            fallback: 'The inspection could not be saved.',
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> decline() async {
    final controller = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Decline assignment'),
          content: TextField(
            controller: controller,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Reason'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Decline'),
            ),
          ],
        ),
      );
      if (ok == true && controller.text.trim().length >= 2) {
        await command('decline', {'reason': controller.text.trim()});
      }
    } finally {
      controller.dispose();
    }
  }

  Widget optionalInput(
    TextEditingController controller,
    String label, {
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: controller,
      enabled: !busy,
      maxLines: numeric ? 1 : 2,
      maxLength: numeric ? null : 2000,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      onChanged: (_) {
        widget.onEdited?.call();
        setState(() => saved = false);
      },
      decoration: InputDecoration(labelText: label),
    ),
  );

  Future<void> reportDiscrepancy() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => _DiscrepancyDialog(labels),
    );
    if (!mounted || result == null) return;
    final (key, observed) = result;
    final notes = switch (key) {
      'parking_verified' => parkingNotes,
      'accessibility_verified' => accessNotes,
      _ => note,
    };
    final previous = notes.text.trim();
    final entry = '${labels[key]} discrepancy: $observed';
    final revised = previous.isEmpty ? entry : '$previous\n$entry';
    if (revised.length > 2000) {
      setState(
        () => error = 'Shorten the existing notes before adding a discrepancy.',
      );
      return;
    }
    widget.onEdited?.call();
    setState(() {
      checks[key] = false;
      notes.text = revised;
      saved = false;
    });
    await save();
  }

  Future<void> openCapture({String? tourId}) async {
    if (!canUseCapture) return;
    await Navigator.of(context).pushNamed(
      tourId == null ? '/owner/capture' : '/tour-preview',
      arguments:
          tourId ??
          ArCaptureRequest(
            propertyId: '${widget.propertyId}',
            title: widget.listing?.displayTitle,
          ),
    );
    if (!mounted) return;
    setState(() => tourRevision++);
    await refresh(loadChecklist: false);
  }

  void updateTourEligibility(Map<String, dynamic> data) {
    final id = data['panorama_id'];
    panoramaId = id is String && id.isNotEmpty ? id : null;
    final missing = data['missing_required_fields'];
    if (missing is List) {
      missingPropertyDetails = missing.whereType<String>().toList();
    }
    _readinessTimer?.cancel();
    if (editable && panoramaId == null) {
      _readinessTimer = Timer(const Duration(seconds: 10), _pollTour);
    }
  }

  Future<void> _pollTour() async {
    if (!mounted || !editable || panoramaId != null) return;
    try {
      await refreshTourEligibility();
    } catch (_) {
      if (mounted && editable && panoramaId == null) {
        _readinessTimer = Timer(const Duration(seconds: 10), _pollTour);
      }
    }
  }

  Future<void> refreshTourEligibility() async {
    final response = await ServiceLocator.apiClient.get('$url/inspection');
    if (!mounted) return;
    final data = response['data'] as Map<String, dynamic>;
    setState(() => updateTourEligibility(data));
  }

  Future<void> submitInspection() async {
    if (busy ||
        loading ||
        !editable ||
        !allConfirmed ||
        missingPropertyDetails.isNotEmpty) {
      return;
    }
    if (!saved && !await save(announce: false)) return;
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    late final String completedTour;
    late final bool acknowledged;
    try {
      final response = await ServiceLocator.apiClient.get('$url/inspection');
      if (!mounted) return;
      final data = response['data'] as Map<String, dynamic>;
      final id = data['panorama_id'];
      setState(() => updateTourEligibility(data));
      if (missingPropertyDetails.isNotEmpty) return;
      if (id is! String || id.isEmpty) {
        setState(
          () => error =
              'Sync the 360° tour for this inspection before submitting.',
        );
        return;
      }
      completedTour = id;
      acknowledged = data['population_requires_acknowledgement'] == true;
    } catch (e) {
      if (mounted) {
        setState(
          () => error = readableFailure(
            e,
            fallback: 'Could not check whether the inspection is ready.',
          ),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => busy = false);
    }
    final confirmed = await showSitewiseConfirmDialog(
      context,
      title: 'Submit inspection?',
      message:
          'Send the checklist and 360° tour for Admin review.'
          '${acknowledged ? '\n\nPopulation data is unavailable. Submit without a population figure?' : ''}',
      confirmLabel: 'Submit inspection',
    );
    if (!confirmed || !mounted || busy) return;
    await command('submit', {
      'panorama_id': completedTour,
      'acknowledge_unavailable_population': acknowledged,
    });
    if (!mounted || status != 'submitted') return;
    await Navigator.of(
      context,
    ).pushNamed('/provider/submission-success', arguments: widget.propertyId);
  }

  Future<void> previewSummary() async {
    if (!mounted) return;
    // Read from the current form. Preview never saves or submits silently.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: SitewiseM3.surface,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Inspection summary', style: SitewiseM3Type.h2),
                const SizedBox(height: 6),
                const Text(
                  'Review the four on-site checks and 360° tour before submission.',
                  style: TextStyle(color: SitewiseColors.muted),
                ),
                const SizedBox(height: 12),
                for (final entry in checks.entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      entry.value ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: entry.value ? SitewiseColors.success
                          : SitewiseColors.muted,
                    ),
                    title: Text(labels[entry.key]!),
                    subtitle: Text(entry.value ? 'Confirmed on site'
                        : 'Not confirmed yet / discrepancy reported'),
                  ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.threesixty,
                      color: SitewiseColors.action),
                  title: const Text('360° Property Tour'),
                  subtitle: Text(panoramaId == null
                      ? 'Not yet synced — required before submission'
                      : 'Panorama linked to this property'),
                ),
                if (floorArea.text.trim().isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Observed floor area'),
                    subtitle: Text('${floorArea.text.trim()} sq ft'),
                  ),
                if (note.text.trim().isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Inspection findings'),
                    subtitle: Text(note.text.trim()),
                  ),
                if (parkingNotes.text.trim().isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Parking notes'),
                    subtitle: Text(parkingNotes.text.trim()),
                  ),
                if (accessNotes.text.trim().isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Access notes'),
                    subtitle: Text(accessNotes.text.trim()),
                  ),
                if (!saved)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('You have unsaved inspection changes.',
                        style: TextStyle(color: SitewiseColors.warning)),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Close summary'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.inspectionDetail;
    final listing = widget.listing;
    if (detail == null || listing == null) return checklist(context);
    return Scaffold(
      backgroundColor: providerCanvas,
      appBar: const ProviderPageAppBar(
        title: 'Property inspection',
        eyebrow: 'MANAGED LISTING',
      ),
      body: providerContent(
        children: [
          _InspectionOverview(listing: listing, detail: detail, status: status),
          const SizedBox(height: 16),
          checklist(context),
          const SizedBox(height: 16),
          ProviderPanoramaTourSection(
            key: ValueKey(tourRevision),
            propertyId: widget.propertyId,
            onStartCapture: canUseCapture ? openCapture : null,
            onOpenWorkflow: canUseCapture
                ? (tourId) => openCapture(tourId: tourId)
                : null,
            beforeSync: canUseCapture ? () async => canUseCapture : null,
            onSynced: refreshTourEligibility,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: SitewiseM3.surface,
            border: Border(top: BorderSide(color: SitewiseM3.line)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy || loading || !editable ? null : () => save(),
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('Save draft'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: loading ? null : previewSummary,
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: const Text('Review'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy || loading || !editable || !allConfirmed ||
                      missingPropertyDetails.isNotEmpty || panoramaId == null
                      ? null : submitInspection,
                  icon: const Icon(Icons.send_outlined, size: 18),
                  label: const Text('Submit inspection to Admin'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget checklist(BuildContext context) => ProviderCard(
    title: standalone ? 'Inspection checklist' : 'Property verification',
    child: loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                standalone && editable
                    ? 'Confirm the four physical checks'
                    : 'Request: ${status.replaceAll('_', ' ')}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: const TextStyle(color: SitewiseColors.danger),
                ),
                TextButton(onPressed: refresh, child: const Text('Retry')),
              ],
              if (status == 'requested') ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : () => command('accept'),
                  icon: const Icon(Icons.check),
                  label: const Text('Accept request'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : decline,
                  child: const Text('Decline request'),
                ),
              ],
              if (editable) ...[
                if (missingPropertyDetails.isNotEmpty) ...[
                  Text(
                    'Ask the owner to update these property details before '
                    'submitting: ${missingPropertyDetails.join(', ')}.',
                    style: const TextStyle(color: SitewiseColors.danger),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: busy ? null : refresh,
                    child: const Text('Refresh property details'),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Inspection progress',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: SitewiseM3.ink,
                      ),
                    ),
                    Text(
                      '$confirmed / ${checks.length} verified',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: allConfirmed
                            ? SitewiseColors.success
                            : SitewiseM3.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: confirmed / checks.length,
                  semanticsLabel: 'Inspection checklist completion',
                ),
                // SITEWISE_AGENT_COMPACT_UI_V1: dense, 48dp-accessible
                // check rows, without changing the four backend field names.
                for (final entry in checks.entries)
                  Container(
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: SitewiseM3.line),
                      ),
                    ),
                    child: CheckboxListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      activeColor: SitewiseColors.action,
                      value: entry.value,
                      onChanged: busy
                          ? null
                          : (value) {
                              widget.onEdited?.call();
                              setState(() {
                                checks[entry.key] = value ?? false;
                                saved = false;
                              });
                            },
                      title: Text(
                        labels[entry.key]!,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: SitewiseM3.ink,
                        ),
                      ),
                      subtitle: Text(
                        reference(entry.key),
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: SitewiseM3.muted,
                        ),
                      ),
                    ),
                  ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Add inspection notes (optional)'),
                  children: [
                    optionalInput(note, 'Condition or other findings'),
                    optionalInput(
                      floorArea,
                      'Observed floor area (sq ft, optional)',
                      numeric: true,
                    ),
                    optionalInput(parkingNotes, 'Parking notes'),
                    optionalInput(accessNotes, 'Entrance and access notes'),
                  ],
                ),
                TextButton(
                  onPressed: busy ? null : reportDiscrepancy,
                  child: const Text('Report a discrepancy'),
                ),
                if (!standalone)
                  OutlinedButton(
                    onPressed: busy || saved ? null : save,
                    child: Text(saved ? 'Checklist saved' : 'Save checklist'),
                  ),
                if (standalone && panoramaId == null)
                  const Text('A synced 360° tour is required to submit.'),
                if (!allConfirmed)
                  Text(
                    'Still to confirm: ${checks.entries.where((entry) => !entry.value).map((entry) => labels[entry.key]).join(', ')}.',
                    style: const TextStyle(color: SitewiseColors.muted),
                  ),
              ],
              if (status == 'submitted')
                const Text('Submitted for Admin review. Locked.'),
              if (status == 'declined')
                const Text('Request declined; Owner can reassign.'),
            ],
          ),
  );
}

class _InspectionOverview extends StatelessWidget {
  const _InspectionOverview({
    required this.listing,
    required this.detail,
    required this.status,
  });

  final ProviderListing listing;
  final AgentListingDetail detail;
  final String status;

  @override
  Widget build(BuildContext context) {
    final photos = detail.photos.where((photo) => photo.url.trim().isNotEmpty);
    final photoUrl =
        photos.where((photo) => photo.isPrimary).firstOrNull?.url ??
        listing.imageUrl ??
        photos.firstOrNull?.url;
    final assignment = detail.assignment.raw;
    final assignedAt = DateTime.tryParse(
      '${assignment['requested_at'] ?? assignment['created_at'] ?? ''}',
    );
    final ownerName = detail.owner?.displayName.trim() ?? '';
    final statusLabel = switch (status) {
      'requested' || 'accepted' => 'Pending inspection',
      'needs_correction' => 'Needs correction',
      'submitted' => 'Submitted for review',
      'declined' => 'Declined',
      '' => '',
      _ => status.replaceAll('_', ' '),
    };
    const placeholder = ColoredBox(
      color: SitewiseM3.paper,
      child: Center(child: Icon(Icons.storefront_outlined)),
    );
    return ProviderCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            height: 76,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: photoUrl == null || photoUrl.trim().isEmpty
                  ? placeholder
                  : Image.network(
                      photoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => placeholder,
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  listing.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SitewiseM3Type.h2,
                ),
                if (listing.address.trim().isNotEmpty)
                  Text(
                    listing.address,
                    style: const TextStyle(color: SitewiseM3.muted),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _fact('Type', listing.propertyType ?? 'Not provided'),
                    _fact('Size', listing.sizeDisplay),
                    _fact('Monthly rent', listing.rentDisplay),
                  ],
                ),
                const Divider(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _fact(
                      'Owner',
                      ownerName.isEmpty ? 'Not recorded' : ownerName,
                    ),
                    if (assignedAt != null)
                      _fact(
                        'Assigned on',
                        MaterialLocalizations.of(
                          context,
                        ).formatMediumDate(assignedAt.toLocal()),
                      ),
                    if (statusLabel.isNotEmpty)
                      Chip(
                        label: Text(statusLabel),
                        backgroundColor: SitewiseColors.warning.withValues(
                          alpha: 0.12,
                        ),
                        side: BorderSide.none,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fact(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: SitewiseM3.muted),
      ),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );
}

class _DiscrepancyDialog extends StatefulWidget {
  const _DiscrepancyDialog(this.labels);
  final Map<String, String> labels;

  @override
  State<_DiscrepancyDialog> createState() => _DiscrepancyDialogState();
}

class _DiscrepancyDialogState extends State<_DiscrepancyDialog> {
  String? item;
  String detail = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Report a discrepancy'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Save your finding in the draft and reopen this check.'),
          DropdownButton<String>(
            isExpanded: true,
            value: item,
            hint: const Text('Choose a check'),
            items: widget.labels.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => item = value),
          ),
          TextField(
            decoration: const InputDecoration(
              labelText: 'What did you observe?',
            ),
            maxLength: 500,
            maxLines: 3,
            onChanged: (value) => setState(() => detail = value.trim()),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: item == null || detail.isEmpty
            ? null
            : () => Navigator.of(context).pop((item!, detail)),
        child: const Text('Save discrepancy'),
      ),
    ],
  );
}
