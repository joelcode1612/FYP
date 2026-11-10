import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';

/// Mobile saved shortlist — same card system as Explore.

class EntrepreneurSavedMobilePage extends ConsumerWidget {
  const EntrepreneurSavedMobilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appNotifierProvider);
    return MobileAppShell(
        title: 'Saved',
        currentRoute: '/entrepreneur/saved',
        body: appState.saved.isEmpty
            ? SitewiseEmptyState(
                icon: Icons.bookmark_border_rounded,
                title: 'Nothing saved yet',
                message: 'Save properties you want to compare later.',
                actionLabel: 'Explore properties',
                onAction: () =>
                    EntrepreneurTabScope.open(context, '/entrepreneur/explore'),
              )
            : FutureBuilder<List<CommercialProperty>>(
                future: ServiceLocator.properties.listings(),
                builder: (c, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const MobilePropertyListSkeleton();
                  }
                  final items = (snap.data ?? const <CommercialProperty>[])
                      .where((p) => appState.saved.contains(p.id))
                      .toList();
                  if (items.isEmpty) {
                    return const SitewiseEmptyState(
                      icon: Icons.bookmark_border_rounded,
                      title: 'Shortlist is empty',
                      message: 'Saved items were removed or are unavailable.',
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      MobileSectionHeader(
                        title: 'Saved properties',
                        subtitle:
                            '${items.length} ${items.length == 1 ? 'property' : 'properties'} in your shortlist',
                      ),
                      const SizedBox(height: 14),
                      for (final p in items) ...[
                        MobilePropertyCard(
                          property: p,
                          saved: true,
                          onToggleSaved: () => ref
                              .read(appNotifierProvider.notifier)
                              .toggleSaved(p.id),
                          compared: appState.compared.contains(p.id),
                          onToggleCompare: () => ref
                              .read(appNotifierProvider.notifier)
                              .toggleCompared(p.id),
                          onTap: () => Navigator.of(context).pushNamed(
                            '/entrepreneur/property-detail',
                            arguments: p.id,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  );
                },
              ),
    );
  }
}
