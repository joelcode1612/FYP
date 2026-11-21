import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/layouts/provider_tab_scope.dart';
import 'package:fyp/features/dashboard/application/provider_dashboard_controller.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';

/// Owner-only read view of existing management relationships and publication
/// states. The current backend does NOT expose Owner -> Agent invitation,
/// acceptance or decline commands. This UI deliberately provides no fake
/// request-submission or acceptance buttons.
class ProviderOwnerRequestsMobilePage extends ConsumerWidget {
  const ProviderOwnerRequestsMobilePage({super.key});

  void _open(BuildContext context, int propertyId) {
    final route = '/provider/property-detail';
    final scope = ProviderTabScope.maybeOf(context);
    if (scope != null && scope.handlesRoute(route)) {
      scope.go(route, arguments: propertyId);
    } else {
      Navigator.of(context).pushNamed(route, arguments: propertyId);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashboard = ref.watch(providerDashboardProvider);
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: () => settleRefresh(
        ref.refresh(providerDashboardProvider.future),
      ),
      child: dashboard.when(
        skipLoadingOnRefresh: true,
        loading: providerLoadingView,
        error: (error, _) => providerContent(children: [
          ProviderMessage(
            icon: Icons.wifi_off_outlined,
            title: 'Request tracking is unavailable',
            body: 'Could not load your authorized property records: $error',
            onRetry: () => ref.invalidate(providerDashboardProvider),
          ),
        ]),
        data: (data) {
          final agentManaged = data.listings
              .where((listing) => listing.management?.isAgent ?? false)
              .toList();
          final awaitingReview = data.listings
              .where((listing) => listing.stage == ProviderStage.pending)
              .toList();
          final corrections = data.listings
              .where((listing) => listing.stage == ProviderStage.rejected)
              .toList();
          return providerContent(children: [
            const Text(
              'Requests & progress',
              style: SitewiseM3Type.h1,
            ),
            const SizedBox(height: 8),
            const Text(
              'Follow the manager shown on each property and its Administrator '
              'review status. These values come from your authorized listings.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14,
                height: 1.5,
                color: SitewiseM3.muted,
              ),
            ),
            const SizedBox(height: 18),
            const ProviderMessage(
              icon: Icons.info_outline_rounded,
              title: 'About Agent requests',
              body: 'The backend currently records assignments, not Agent '
                  'accept/decline responses. Agent invitations will appear '
                  'here after the request API is implemented; no request is '
                  'created by viewing this screen.',
            ),
            const SizedBox(height: 16),
            _section(
              context,
              'Agent-managed properties',
              agentManaged,
              empty: 'No Agent-managed property is currently reported.',
            ),
            const SizedBox(height: 16),
            _section(
              context,
              'Pending Admin review',
              awaitingReview,
              empty: 'No property is currently awaiting review.',
            ),
            const SizedBox(height: 16),
            _section(
              context,
              'Corrections required',
              corrections,
              empty: 'No rejected property is reported.',
            ),
          ]);
        },
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<ProviderListing> listings, {
    required String empty,
  }) => ProviderCard(
    title: '$title (${listings.length})',
    child: listings.isEmpty
        ? Text(
            empty,
            style: const TextStyle(
              fontFamily: kFontFamily,
              color: SitewiseM3.muted,
              fontSize: 14,
              height: 1.45,
            ),
          )
        : Column(
            children: [
              for (var i = 0; i < listings.length; i++) ...[
                if (i > 0) const Divider(height: 24, color: SitewiseM3.line),
                _requestRow(context, listings[i]),
              ],
            ],
          ),
  );

  Widget _requestRow(BuildContext context, ProviderListing listing) =>
      InkWell(
        onTap: () => _open(context, listing.id),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.apartment_outlined,
                color: SitewiseColors.action,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      listing.displayTitle,
                      style: const TextStyle(
                        color: SitewiseM3.ink,
                        fontFamily: kFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      listing.management?.display ??
                          'Management details unavailable',
                      style: const TextStyle(
                        color: SitewiseM3.muted,
                        fontFamily: kFontFamily,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 7),
                    ProviderStatusPill(stage: listing.stage, compact: true),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: SitewiseM3.muted),
            ],
          ),
        ),
      );
}
