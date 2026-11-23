import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';

/// Collects only the information still absent from an authorized Agent's draft.
/// The backend owns the required-field list and validates every mutation.
class AgentPropertyDetailsSheet extends StatefulWidget {
  const AgentPropertyDetailsSheet({super.key, required this.propertyId});

  final int propertyId;

  static Future<bool> open(BuildContext context, int propertyId) async {
    return (await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          useSafeArea: true,
          backgroundColor: Colors.white,
          builder: (_) => AgentPropertyDetailsSheet(propertyId: propertyId),
        )) ??
        false;
  }

  @override
  State<AgentPropertyDetailsSheet> createState() =>
      _AgentPropertyDetailsSheetState();
}

class _AgentPropertyDetailsSheetState extends State<AgentPropertyDetailsSheet> {
  static const _labels = <String, String>{
    'name': 'Property title',
    'property_type': 'Property type',
    'address': 'Street address',
    'city': 'City / township',
    'state': 'State / federal territory',
    'postcode': 'Postcode',
    'rental_price': 'Monthly rental (RM)',
    'size_sqft': 'Built-up area (sq ft)',
  };
  static const _typeChoices = <String>[
    'Shoplot',
    'Retail Space',
    'Ground Floor Shop',
    'Corner Shoplot',
    'Retail Unit',
    'Kiosk',
    'Commercial F&B Premise',
  ];

  final Map<String, TextEditingController> _values = {
    for (final key in _labels.keys) key: TextEditingController(),
  };
  List<String> _missing = const [];
  bool _loading = true;
  bool _saving = false;
  bool _savedAny = false;
  bool _editable = false;
  String? _error;

  String get _url =>
      '/api/v1/provider-flow/properties/${widget.propertyId}/details';

  @override
  void initState() {
    super.initState();
    _readiness();
  }

  @override
  void dispose() {
    for (final controller in _values.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _readiness() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ServiceLocator.apiClient.get(_url);
      final raw = result['data'];
      if (raw is! Map) throw StateError('Property details were not returned.');
      final fields = raw['fields'];
      final missing = raw['missing_required_fields'];
      if (!mounted) return;
      setState(() {
        _missing = missing is List ? missing.whereType<String>().toList() : [];
        _editable = raw['editable'] == true;
        if (fields is Map) {
          for (final entry in _values.entries) {
            final value = fields[entry.key];
            // Never discard unsaved input after a failed request.
            if (entry.value.text.trim().isEmpty && value != null) {
              entry.value.text = '$value';
            }
          }
        }
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = readableFailure(
            e,
            fallback: 'Could not load missing property information.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _keyForMissing(String name) => switch (name.trim().toLowerCase()) {
    'name' => 'name',
    'property type' => 'property_type',
    'address' => 'address',
    'city' => 'city',
    'state' => 'state',
    'postcode' => 'postcode',
    'rental price' || 'a rental price greater than zero' => 'rental_price',
    'size sqft' || 'a built-up area greater than zero' => 'size_sqft',
    _ => null,
  };

  Future<void> _save() async {
    if (_saving || !_editable) return;
    final fields = <String, dynamic>{};
    final keys = _missing.map(_keyForMissing).whereType<String>().toSet();
    for (final key in keys) {
      final text = _values[key]!.text.trim();
      if (text.isEmpty) continue;
      if (key == 'postcode' && !RegExp(r'^\d{5}$').hasMatch(text)) {
        setState(() => _error = 'Postcode must contain five digits.');
        return;
      }
      if (key == 'property_type' && !_typeChoices.contains(text)) {
        setState(() => _error = 'Choose a supported property type.');
        return;
      }
      if (key == 'rental_price' || key == 'size_sqft') {
        final amount = double.tryParse(text);
        if (amount == null || amount <= 0) {
          setState(() => _error = '${_labels[key]} must be greater than zero.');
          return;
        }
        fields[key] = amount;
      } else {
        fields[key] = text;
      }
    }
    if (fields.isEmpty) {
      setState(() => _error = 'Fill at least one missing field to save.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ServiceLocator.apiClient.patch(_url, fields);
      if (!mounted) return;
      final raw = result['data'];
      if (raw is! Map) throw StateError('The saved property was not returned.');
      final missing = raw['missing_required_fields'];
      setState(() {
        _missing = missing is List ? missing.whereType<String>().toList() : [];
        _savedAny = true;
      });
      if (_missing.isEmpty) {
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Details saved. Complete the remaining fields before submission.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = readableFailure(
            e,
            fallback: 'Could not save the property details.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String key) {
    final controller = _values[key]!;
    if (key == 'property_type' ||
        key == 'state' ||
        key == 'city' ||
        key == 'postcode') {
      final List<String> choices = switch (key) {
        'property_type' => _typeChoices,
        'state' => MalaysiaLocations.stateNames,
        'city' => MalaysiaLocations.citiesFor(_values['state']!.text.trim()),
        'postcode' => MalaysiaLocations.postcodesFor(
          _values['state']!.text.trim(),
          _values['city']!.text.trim(),
        ),
        _ => const [],
      };
      return DropdownButtonFormField<String>(
        key: ValueKey(
          '$key-${_values['state']!.text}-${_values['city']!.text}',
        ),
        initialValue: choices.contains(controller.text)
            ? controller.text
            : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: _labels[key],
          border: const OutlineInputBorder(),
          helperText: choices.isEmpty
              ? 'Choose the previous location first'
              : null,
        ),
        items: [
          for (final choice in choices)
            DropdownMenuItem(
              value: choice,
              child: Text(choice, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _saving || choices.isEmpty
            ? null
            : (value) {
                setState(() {
                  controller.text = value ?? '';
                  if (key == 'state') {
                    _values['city']!.clear();
                    _values['postcode']!.clear();
                  } else if (key == 'city') {
                    _values['postcode']!.clear();
                  }
                });
              },
      );
    }
    return TextField(
      controller: controller,
      enabled: !_saving,
      maxLines: key == 'address' ? 2 : 1,
      keyboardType: key == 'rental_price' || key == 'size_sqft'
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: _labels[key],
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keys = _missing
        .map(_keyForMissing)
        .whereType<String>()
        .toSet()
        .toList();
    final media = MediaQuery.of(context);
    final height =
        (media.size.height - media.viewInsets.bottom - media.padding.top) *
        0.88;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Complete property details',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Collect missing information before Admin submission.',
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(_savedAny),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      children: [
                        if (keys.isEmpty && _error == null)
                          const Text(
                            'All required property details are present.',
                          ),
                        Text(
                          '${keys.length} required details remaining',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 14),
                        for (final key in keys) ...[
                          _field(key),
                          const SizedBox(height: 14),
                        ],
                        if (!_editable)
                          const Text(
                            'Accept the assignment to edit these details.',
                          ),
                        if (_error case final error?) ...[
                          Text(
                            error,
                            style: const TextStyle(
                              color: SitewiseColors.danger,
                            ),
                          ),
                          TextButton(
                            onPressed: _readiness,
                            child: const Text('Retry loading'),
                          ),
                        ],
                        const SizedBox(height: 12),
                        const Text(
                          'Only missing fields can be completed here. To change facts '
                          'already supplied by the owner, use the existing change request workflow.',
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: FilledButton(
                onPressed: _loading || _saving || !_editable || keys.isEmpty
                    ? null
                    : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: Text(_saving ? 'Saving…' : 'Save collected details'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
