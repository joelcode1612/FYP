import 'package:shared_logic/shared_logic.dart';
import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../../shared/widgets/sitewise_search_bar.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_property_card.dart';

/// Mobile listings: search plus a vertical card list.

class AdminListingsMobilePage extends StatefulWidget {
  final AppCubit appState;
  const AdminListingsMobilePage({super.key, required this.appState});

  @override
  State<AdminListingsMobilePage> createState() =>
      _AdminListingsMobilePageState();
}

class _AdminListingsMobilePageState extends State<AdminListingsMobilePage> {
  final vm = ServiceLocator.newAdminCubit();
  String query = '';

  @override
  void initState() {
    super.initState();
    vm.loadDashboard();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<AdminCubit, AdminState>(
        bloc: vm,
        builder: (ctx, _) {
        final items = vm.listings
            .where(
              (p) =>
                  query.isEmpty ||
                  '${p.title} ${p.city}'.toLowerCase().contains(
                    query.toLowerCase(),
                  ),
            )
            .toList();
        return MobileAppShell(
          appState: widget.appState,
          title: 'Listings',
          currentRoute: '/admin/listings',
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: SitewiseSearchBar(
                  hint: 'Search listings…',
                  onChanged: (v) => setState(() => query = v),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: vm.loading
                    ? const SitewiseLoadingState()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: items.length,
                        itemBuilder: (c, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: MobilePropertyCard(
                            property: items[i],
                            onTap: () => Navigator.of(context).pushNamed(
                              '/admin/listing-detail',
                              arguments: items[i].id,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
      ),
    );
  }
}
