import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_confirm_dialog.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../../shared/widgets/sitewise_status_badge.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile verification detail: single-column evidence with a sticky bottom
/// decision bar.

class AdminVerificationDetailMobilePage extends StatelessWidget {
  final AppCubit appState;
  final String propertyId;
  const AdminVerificationDetailMobilePage({
    super.key,
    required this.appState,
    required this.propertyId,
  });

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      appState: appState,
      title: 'Verification',
      currentRoute: '/admin/verification',
      body: FutureBuilder<CommercialProperty?>(
        future: ServiceLocator.properties.detail(propertyId),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: SitewiseLoadingState(),
            );
          }
          final p = snap.data!;
          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  p.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                              SitewiseStatusBadge.forVerification(
                                p.verification,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text('${p.address}, ${p.postcode} ${p.city}'),
                          const SizedBox(height: 12),
                          Text(
                            'RM${p.rentalRm.toStringAsFixed(0)} · ${p.sizeSqft.toStringAsFixed(0)} sq ft · ${p.propertyType}',
                          ),
                          const Divider(height: 32),
                          const Text(
                            'Checklist',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '• Ownership document provided\n• Address matches SSM record\n• Photos show actual unit\n• Rental within area band',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                decoration: const BoxDecoration(
                  color: SitewiseColors.surface,
                  border: Border(top: BorderSide(color: SitewiseColors.border)),
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                        child: SitewiseSecondaryButton(
                          label: 'Reject',
                          icon: Icons.close,
                          expanded: false,
                          onPressed: () => _reject(context, p.id),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SitewiseButton(
                          label: 'Verify',
                          icon: Icons.verified,
                          expanded: false,
                          onPressed: () => _approve(context, p.id),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _approve(BuildContext context, String id) async {
    await ServiceLocator.verification.approve(id);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Listing verified.')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _reject(BuildContext context, String id) async {
    final ok = await showSitewiseConfirmDialog(
      context,
      title: 'Reject listing?',
      message: 'The owner will be asked to fix the issues and resubmit.',
      confirmLabel: 'Reject',
      destructive: true,
    );
    if (ok) {
      await ServiceLocator.verification.reject(id, 'Incomplete documents');
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}
