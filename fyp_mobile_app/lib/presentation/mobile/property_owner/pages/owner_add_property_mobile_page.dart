import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../shell/mobile_app_shell.dart';

/// Mobile add/edit property: step-by-step touch form (basics → location →
/// commercials). Persists via the application service in a real backend;
/// here it confirms and returns.

class OwnerAddPropertyMobilePage extends StatefulWidget {
  final AppCubit appState;
  final String? editingId;
  const OwnerAddPropertyMobilePage({
    super.key,
    required this.appState,
    this.editingId,
  });

  @override
  State<OwnerAddPropertyMobilePage> createState() =>
      _OwnerAddPropertyMobilePageState();
}

class _OwnerAddPropertyMobilePageState
    extends State<OwnerAddPropertyMobilePage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController(text: 'Subang Jaya');
  final _rental = TextEditingController();
  final _size = TextEditingController();
  int _step = 0;

  @override
  void dispose() {
    _title.dispose();
    _address.dispose();
    _city.dispose();
    _rental.dispose();
    _size.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      appState: widget.appState,
      title: widget.editingId == null ? 'Add Property' : 'Edit Property',
      currentRoute: '/owner/add-property',
      body: Form(
        key: _formKey,
        child: Stepper(
          currentStep: _step,
          onStepContinue: _next,
          onStepCancel: () => setState(() => _step = (_step - 1).clamp(0, 2)),
          onStepTapped: (i) => setState(() => _step = i),
          controlsBuilder: (ctx, details) => Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: details.onStepContinue,
                    child: Text(_step == 2 ? 'Save draft' : 'Continue'),
                  ),
                ),
                if (_step > 0) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: details.onStepCancel,
                      child: const Text('Back'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          steps: [
            Step(
              title: const Text('Basics'),
              isActive: _step >= 0,
              content: Column(
                children: [
                  TextFormField(
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: 'Listing title',
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: 'Street address',
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                ],
              ),
            ),
            Step(
              title: const Text('Location'),
              isActive: _step >= 1,
              content: TextFormField(
                controller: _city,
                decoration: const InputDecoration(labelText: 'City'),
              ),
            ),
            Step(
              title: const Text('Commercials'),
              isActive: _step >= 2,
              content: Column(
                children: [
                  TextFormField(
                    controller: _rental,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Monthly rental (RM)',
                      prefixText: 'RM ',
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _size,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Floor area (sq ft)',
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _next() {
    if (_step < 2) {
      setState(() => _step++);
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Draft saved. Submit for verification from the detail page.',
        ),
      ),
    );
    Navigator.of(context).pop();
  }
}
