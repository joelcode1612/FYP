import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../../shared/widgets/sitewise_map_panel.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../../shared/widgets/sitewise_status_badge.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile owner property detail: single-column management flow.

class OwnerPropertyDetailMobilePage extends StatelessWidget {
  final AppCubit appState;
  final String propertyId;
  const OwnerPropertyDetailMobilePage({
    super.key,
    required this.appState,
    required this.propertyId,
  });

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      appState: appState,
      title: 'Property detail',
      currentRoute: '/owner/properties',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<CommercialProperty?>(
          future: ServiceLocator.properties.detail(propertyId),
          builder: (ctx, snap) {
            if (!snap.hasData) return const SitewiseLoadingState();
            final p = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
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
                            SitewiseStatusBadge.forVerification(p.verification),
                          ],
                        ),
                        Text(
                          '${p.address}, ${p.postcode} ${p.city}, ${p.state}',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'RM${p.rentalRm.toStringAsFixed(0)} · ${p.sizeSqft.toStringAsFixed(0)} sq ft · ${p.propertyType}',
                        ),
                        const SizedBox(height: 12),
                        SitewiseMapPanel(
                          height: 220,
                          pins: [
                            MapPin(
                              id: p.id,
                              label: p.title,
                              latitude: p.latitude,
                              longitude: p.longitude,
                              highlighted: true,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SitewiseSecondaryButton(
                  label: 'Edit listing',
                  icon: Icons.edit,
                  onPressed: () => Navigator.of(
                    context,
                  ).pushNamed('/owner/add-property', arguments: p.id),
                ),
                const SizedBox(height: 8),
                if (p.verification == VerificationStatus.draft)
                  SitewiseButton(
                    label: 'Submit for verification',
                    icon: Icons.send,
                    onPressed: () async {
                      await ServiceLocator.properties.submit(p.id);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Submitted for verification.'),
                          ),
                        );
                        Navigator.of(context).pop();
                      }
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
