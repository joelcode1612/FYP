import 'package:shared_logic/shared_logic.dart';
import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../../shared/widgets/sitewise_section_header.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_property_card.dart';

/// Mobile verification queue: verification cards with tap-to-review.

class AdminVerificationMobilePage extends StatefulWidget {
  final AppCubit appState;
  const AdminVerificationMobilePage({super.key, required this.appState});

  @override
  State<AdminVerificationMobilePage> createState() =>
      _AdminVerificationMobilePageState();
}

class _AdminVerificationMobilePageState
    extends State<AdminVerificationMobilePage> {
  final vm = ServiceLocator.newAdminCubit();

  @override
  void initState() {
    super.initState();
    vm.loadDashboard();
    vm.loadPendingTours();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<AdminCubit, AdminState>(
        bloc: vm,
        builder: (ctx, _) => MobileAppShell(
        appState: widget.appState,
        title: 'Verification',
        currentRoute: '/admin/verification',
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SitewiseSectionHeader(
                title: 'Awaiting review',
                subtitle: 'Tap a listing to review and verify.',
              ),
              const SizedBox(height: 12),
              if (vm.loading)
                const SitewiseLoadingState()
              else if (vm.queue.isEmpty)
                const SitewiseEmptyState(
                  title: 'Queue is clear',
                  message:
                      'No properties are waiting for verification right now.',
                )
              else
                for (final p in vm.queue)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: MobilePropertyCard(
                      property: p,
                      onTap: () => Navigator.of(context).pushNamed(
                        '/admin/verification-detail',
                        arguments: p.id,
                      ),
                    ),
                  ),
              const SizedBox(height: 20),
              const SitewiseSectionHeader(
                title: 'Tours awaiting verification',
                subtitle: 'Approve completed 360° tours for entrepreneurs.',
              ),
              const SizedBox(height: 12),
              if (vm.pendingTours.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No tours are waiting for verification.'),
                  ),
                )
              else
                for (final t in vm.pendingTours)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text('${t.frameCount} frames captured'),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => vm.rejectTour(t.id),
                                    child: const Text('Reject'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () => vm.approveTour(t.id),
                                    child: const Text('Approve'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
