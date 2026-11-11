import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile preferences: single-column touch form.

class EntrepreneurPreferencesMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurPreferencesMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurPreferencesMobilePage> createState() =>
      _EntrepreneurPreferencesMobilePageState();
}

class _EntrepreneurPreferencesMobilePageState
    extends ConsumerState<EntrepreneurPreferencesMobilePage> {
  late final TextEditingController _type;
  late double _budget;
  late double _size;

  @override
  void initState() {
    super.initState();
    _type = TextEditingController(
      text: ServiceLocator.preferences.businessType,
    );
    // Clamped to the slider range: a persisted preference outside it (an older
    // draft, a hand-edited store) would trip the Slider's value assertion and
    // red-screen the page before the user could fix it.
    _budget = ServiceLocator.preferences.maxBudgetRm.clamp(_budgetMin, _budgetMax);
    _size = ServiceLocator.preferences.minSizeSqft.clamp(_sizeMin, _sizeMax);
  }

  static const double _budgetMin = 1500;
  static const double _budgetMax = 12000;
  static const double _sizeMin = 200;
  static const double _sizeMax = 3000;

  @override
  void dispose() {
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
                  min: _budgetMin,
                  max: _budgetMax,
                  divisions: 21,
                  value: _budget,
                  onChanged: (v) => setState(() => _budget = v),
                ),
                const SizedBox(height: 8),
                Text('Min size: ${_size.toStringAsFixed(0)} sq ft'),
                Slider(
                  min: _sizeMin,
                  max: _sizeMax,
                  divisions: 14,
                  value: _size,
                  onChanged: (v) => setState(() => _size = v),
                ),
                const SizedBox(height: 16),
                SitewiseButton(
                  label: 'Save & see recommendations',
                  icon: Icons.auto_awesome,
                  onPressed: () {
                    ref
                        .read(entrepreneurNotifierProvider.notifier)
                        .updatePreferences(
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
