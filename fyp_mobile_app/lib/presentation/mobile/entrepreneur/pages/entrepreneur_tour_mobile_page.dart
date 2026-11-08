import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_tour_viewer.dart';

/// Mobile 360° tour: immersive viewer with a bottom scene selector.

class EntrepreneurTourMobilePage extends StatelessWidget {
  final String propertyId;
  const EntrepreneurTourMobilePage({super.key, required this.propertyId});

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      title: '360° tour',
      currentRoute: '/entrepreneur/explore',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<VirtualTour?>(
          future: ServiceLocator.tourRepo.getTourByProperty(propertyId),
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SitewiseLoadingState();
            }
            final tour = snap.data;
            if (tour == null) {
              return const SitewiseEmptyState(
                title: 'No tour for this unit',
                message:
                    'The owner has not published a 360° tour yet. Visit the unit or check similar listings.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tour.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                Text(
                  '${tour.sceneCount} scenes · ${tour.published ? 'Published' : 'Draft'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _propertyCard(context, propertyId),
                const SizedBox(height: 12),
                MobileTourViewer(tour: tour),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _propertyCard(BuildContext context, String propertyId) {
    return FutureBuilder<CommercialProperty?>(
      future: ServiceLocator.properties.detail(propertyId),
      builder: (c, psnap) {
        if (!psnap.hasData || psnap.data == null) {
          return const SizedBox();
        }
        final p = psnap.data!;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${p.address}, ${p.city} · RM${p.rentalRm.toStringAsFixed(0)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text(
                  p.suitabilityScore.toStringAsFixed(0),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
