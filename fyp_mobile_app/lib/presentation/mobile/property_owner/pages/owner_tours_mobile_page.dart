import 'dart:async';
import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_bottom_sheet.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_confirm_dialog.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_tour_viewer.dart';

/// Mobile 360° tours: property-picked AR capture plus per-tour preview,
/// submit-for-verification and delete with confirmation.

class OwnerToursMobilePage extends StatefulWidget {
  final AppCubit appState;
  const OwnerToursMobilePage({super.key, required this.appState});

  static const ownerId = 'owner-1';

  @override
  State<OwnerToursMobilePage> createState() => _OwnerToursMobilePageState();
}

class _OwnerToursMobilePageState extends State<OwnerToursMobilePage> {
  final vm = ServiceLocator.newOwnerCubit();

  @override
  void initState() {
    super.initState();
    vm.load();
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<OwnerCubit, OwnerState>(
        bloc: vm,
        builder: (ctx, _) => MobileAppShell(
        appState: widget.appState,
        title: '360° Tours',
        currentRoute: '/owner/tours',
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SitewiseButton(
                label: 'Capture new tour (AR)',
                icon: Icons.camera_alt,
                onPressed: _pickProperty,
              ),
              const SizedBox(height: 16),
              if (vm.loading)
                const SitewiseLoadingState()
              else if (vm.tours.isEmpty)
                const SitewiseEmptyState(
                  title: 'No tours yet',
                  message:
                      'Capture a 360° tour for a listing to help entrepreneurs explore remotely.',
                )
              else
                for (final tour in vm.tours)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _tourCard(tour),
                  ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _pickProperty() {
    if (vm.properties.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add a property first.')));
      return;
    }
    showSitewiseBottomSheet<void>(
      context,
      title: 'Select property to capture',
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in vm.properties)
            ListTile(
              title: Text(p.title),
              subtitle: Text(p.city),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(
                  context,
                ).pushNamed('/owner/capture', arguments: p.id);
              },
            ),
        ],
      ),
    );
  }

  Widget _tourCard(VirtualTour tour) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tour.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                _statusPill(tour.status),
              ],
            ),
            Text(
              '${tour.sceneCount} scenes · ${_statusLabel(tour.status)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            MobileTourViewer(tour: tour),
            const SizedBox(height: 12),
            SitewiseSecondaryButton(
              label: 'Open preview & manage',
              icon: Icons.preview_outlined,
              onPressed: () => Navigator.of(
                context,
              ).pushNamed('/owner/tour-preview', arguments: tour.id),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (tour.status == VirtualTourStatus.draft ||
                    tour.status == VirtualTourStatus.ready)
                  Expanded(
                    child: SitewiseSecondaryButton(
                      label: 'Submit',
                      icon: Icons.send,
                      expanded: false,
                      onPressed: () async {
                        await vm.submitTour(tour.id);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Submitted for verification.'),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                if (tour.status == VirtualTourStatus.draft ||
                    tour.status == VirtualTourStatus.ready)
                  const SizedBox(width: 8),
                Expanded(
                  child: SitewiseSecondaryButton(
                    label: 'Delete',
                    icon: Icons.delete_outline,
                    expanded: false,
                    onPressed: () async {
                      final ok = await showSitewiseConfirmDialog(
                        context,
                        title: 'Delete this tour?',
                        message:
                            'The panorama and all captured frames will be permanently removed.',
                        confirmLabel: 'Delete',
                        destructive: true,
                      );
                      if (ok) {
                        await vm.deleteTour(tour.id);
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusPill(VirtualTourStatus status) {
    final color = switch (status) {
      VirtualTourStatus.approved => SitewiseColors.success,
      VirtualTourStatus.pendingVerification ||
      VirtualTourStatus.processing => SitewiseColors.warning,
      VirtualTourStatus.rejected => SitewiseColors.danger,
      VirtualTourStatus.draft ||
      VirtualTourStatus.ready => SitewiseColors.action,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _statusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _statusLabel(VirtualTourStatus status) => switch (status) {
    VirtualTourStatus.draft => 'Draft',
    VirtualTourStatus.processing => 'Processing…',
    VirtualTourStatus.ready => 'Ready',
    VirtualTourStatus.pendingVerification => 'Pending verification',
    VirtualTourStatus.approved => 'Approved',
    VirtualTourStatus.rejected => 'Rejected',
  };
}
