import 'package:shared_logic/shared_logic.dart';
import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_property_card.dart';

/// Mobile properties: vertical card list with an add action.

class OwnerPropertiesMobilePage extends StatefulWidget {
  final AppCubit appState;
  const OwnerPropertiesMobilePage({super.key, required this.appState});

  @override
  State<OwnerPropertiesMobilePage> createState() =>
      _OwnerPropertiesMobilePageState();
}

class _OwnerPropertiesMobilePageState extends State<OwnerPropertiesMobilePage> {
  final vm = ServiceLocator.newOwnerCubit();

  @override
  void initState() {
    super.initState();
    vm.load();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<OwnerCubit, OwnerState>(
        bloc: vm,
        builder: (ctx, _) => MobileAppShell(
        appState: widget.appState,
        title: 'Properties',
        currentRoute: '/owner/properties',
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () =>
              Navigator.of(context).pushNamed('/owner/add-property'),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        body: vm.loading
            ? const SitewiseLoadingState()
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: vm.properties.length,
                itemBuilder: (c, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: MobilePropertyCard(
                    property: vm.properties[i],
                    onTap: () => Navigator.of(context).pushNamed(
                      '/owner/property-detail',
                      arguments: vm.properties[i].id,
                    ),
                  ),
                ),
              ),
      ),
      ),
    );
  }
}
