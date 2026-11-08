import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../application/state/entrepreneur_view_model.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile preferences: single-column touch form.

class EntrepreneurPreferencesMobilePage extends StatefulWidget {
  const EntrepreneurPreferencesMobilePage({super.key});

  @override
  State<EntrepreneurPreferencesMobilePage> createState() =>
      _EntrepreneurPreferencesMobilePageState();
}

class _EntrepreneurPreferencesMobilePageState
    extends State<EntrepreneurPreferencesMobilePage> {
  final EntrepreneurViewModel vm = ServiceLocator.newEntrepreneurViewModel();
  late final TextEditingController _type;
  late double _budget;
  late double _size;

  @override
  void initState() {
    super.initState();
    _type = TextEditingController(
      text: ServiceLocator.preferences.businessType,
    );
    _budget = ServiceLocator.preferences.maxBudgetRm;
    _size = ServiceLocator.preferences.minSizeSqft;
  }

  @override
  void dispose() {
    vm.dispose();
    _type.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      title: 'Business preferences',
      currentRoute: '/entrepreneur',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _type,
                  decoration: const InputDecoration(labelText: 'Business type'),
                ),
                const SizedBox(height: 20),
                Text('Max budget: RM${_budget.toStringAsFixed(0)}'),
                Slider(
                  min: 1500,
                  max: 12000,
                  divisions: 21,
                  value: _budget,
                  onChanged: (v) => setState(() => _budget = v),
                ),
                const SizedBox(height: 8),
                Text('Min size: ${_size.toStringAsFixed(0)} sq ft'),
                Slider(
                  min: 200,
                  max: 3000,
                  divisions: 14,
                  value: _size,
                  onChanged: (v) => setState(() => _size = v),
                ),
                const SizedBox(height: 16),
                SitewiseButton(
                  label: 'Save & see recommendations',
                  icon: Icons.auto_awesome,
                  onPressed: () {
                    vm.updatePreferences(
                      BusinessPreferences(
                        businessType: _type.text,
                        maxBudgetRm: _budget,
                        minSizeSqft: _size,
                        preferredAreas:
                            ServiceLocator.preferences.preferredAreas,
                        seatingModel: ServiceLocator.preferences.seatingModel,
                      ),
                    );
                    Navigator.of(
                      context,
                    ).pushNamed('/entrepreneur/recommendations');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
