import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_inline_notice.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/async_section.dart';
import '../../widgets/mobile_tour_viewer.dart';

/// Mobile 360° tour: immersive viewer with a bottom scene selector.
///
/// What used to be broken here:
///
///  * `FutureBuilder(future: ServiceLocator.tourRepo.getTourByProperty(...))`
///    was rebuilt with a fresh future on every rebuild, so the read was
///    re-issued on each parent repaint;
///  * a failed read rendered "No tour for this unit" — an API error shown as a
///    genuine empty state, which the brief forbids. A failure is now an error
///    with Retry, and "no tour" only appears when the service actually said so;
///  * the property card was a second `FutureBuilder` that silently rendered
///    nothing on failure, and it printed `suitabilityScore` even when the row
///    carries no score (a fabricated "0").
class EntrepreneurTourMobilePage extends ConsumerStatefulWidget {
  final String propertyId;
  const EntrepreneurTourMobilePage({super.key, required this.propertyId});

  @override
  ConsumerState<EntrepreneurTourMobilePage> createState() =>
      _EntrepreneurTourMobilePageState();
}

class _EntrepreneurTourMobilePageState
    extends ConsumerState<EntrepreneurTourMobilePage> {
  final GlobalKey<AsyncSectionState<_TourData>> _tourKey =
      GlobalKey<AsyncSectionState<_TourData>>();

  Future<void> _refresh() =>
      _tourKey.currentState?.refresh() ?? Future<void>.value();

  /// The same resolution order the property detail page uses, so a live
  /// `fyp.rental_properties` id resolves through the Explore repository while a
  /// catalogue ref falls back to the shared property repository.
  Future<CommercialProperty?> _resolveProperty() async {
    final explore = ref.read(exploreRepositoryProvider);
    if (explore != null) {
      try {
        final detail = await explore.detail(widget.propertyId);
        return detail.property;
      } on NotFoundShape {
        return null;
      }
    }
    return ServiceLocator.properties.detail(widget.propertyId);
  }

  Future<_TourData> _load() async {
    final tour = await ServiceLocator.tourRepo.getTourByProperty(
      widget.propertyId,
    );
    CommercialProperty? property;
    String? propertyError;
    if (tour != null) {
      try {
        property = await _resolveProperty();
      } on Object catch (error) {
        propertyError = readableFailure(
          error,
          fallback: 'The listing details could not be loaded.',
        );
      }
    }
    return _TourData(tour: tour, property: property, propertyError: propertyError);
  }

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      title: '360° tour',
      currentRoute: '/entrepreneur/recommendations',
      actions: [
        IconButton(
          tooltip: 'Reload tour',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _refresh,
        ),
      ],
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _refresh,
        child: AsyncSection<_TourData>(
          key: _tourKey,
          load: _load,
          errorTitle: 'The 360° tour could not be loaded',
          isEmpty: (data) => data.tour == null,
          emptyBuilder: (_) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              SitewiseEmptyState(
                title: 'No tour for this unit',
                message:
                    'The owner has not published a 360° tour yet. Visit the unit or check similar listings.',
              ),
            ],
          ),
          builder: (context, data) {
            final tour = data.tour!;
            return ListView(
              padding: const EdgeInsets.all(16),
              physics: const AlwaysScrollableScrollPhysics(),
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
                if (data.propertyError != null)
                  SitewiseInlineNotice(
                    message: data.propertyError!,
                    onRetry: _refresh,
                  )
                else if (data.property != null)
                  _propertyCard(context, data.property!),
                const SizedBox(height: 12),
                MobileTourViewer(tour: tour),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _propertyCard(BuildContext context, CommercialProperty p) {
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
                    '${p.address}, ${p.city} · '
                    '${p.rentalRm > 0 ? p.rentalDisplay : 'Rent on request'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            // A row without a research score has none — printing 0 would be a
            // fabricated figure.
            if (p.hasSuitabilityScore)
              Text(
                p.suitabilityScore.toStringAsFixed(0),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              )
            else
              const Text(
                'Not scored',
                style: TextStyle(fontSize: 12, color: SitewiseColors.muted),
              ),
          ],
        ),
      ),
    );
  }
}

class _TourData {
  const _TourData({
    required this.tour,
    required this.property,
    required this.propertyError,
  });

  final VirtualTour? tour;
  final CommercialProperty? property;
  final String? propertyError;
}
