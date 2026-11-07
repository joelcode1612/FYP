import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/assessment_session.dart';
import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/assessment_stepper.dart';
import '../../widgets/m3_kit.dart';

/// **NEW ASSESSMENT / STEP 1 OF 3** — "Tell us about your business".///
/// Option A business setup: F&B concept, monthly rent budget (RM) and primary
/// target customer. The property arrives either as route `arguments`
/// (from Property Details → Assess This Property) or from the in-session
/// draft (resumed from the hub) — the user is never asked to pick the same
/// property again. A mock property is never auto-selected: without either
/// source the screen offers the listing browser instead.
///
/// Inputs live on [AssessmentSessionStore]; nothing here talks to the
/// network or writes persistence.

class EntrepreneurAssessmentSetupMobilePage extends StatefulWidget {
  final AppCubit appState;

  /// Property chosen upstream; empty when the flow is resumed from the hub.
  final String propertyId;

  const EntrepreneurAssessmentSetupMobilePage({
    super.key,
    required this.appState,
    required this.propertyId,
  });

  @override
  State<EntrepreneurAssessmentSetupMobilePage> createState() =>
      _EntrepreneurAssessmentSetupMobilePageState();
}

class _EntrepreneurAssessmentSetupMobilePageState
    extends State<EntrepreneurAssessmentSetupMobilePage> {
  static const _concepts = [
    'Specialty café',
    'Bakery & dessert',
    'Quick-service restaurant',
    'Cloud kitchen',
  ];
  static const _audiences = [
    'Residents',
    'Students',
    'Office workers',
    'Mixed audience',
  ];

  CommercialProperty? _property;
  bool _missingProperty = false;
  String? _loadingError;

  String? _concept;
  String? _audience;
  late final TextEditingController _budget;
  String? _formError;

  @override
  void initState() {
    super.initState();
    final draft = ServiceLocator.assessmentSession.draft;
    _concept = draft?.concept.isEmpty == true ? null : draft?.concept;
    _audience = draft?.audience.isEmpty == true ? null : draft?.audience;
    _budget = TextEditingController(
      text: draft?.budgetRm == null
          ? ''
          : draft!.budgetRm!.toStringAsFixed(0),
    );
    _load();
  }

  @override
  void dispose() {
    _budget.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final existing = ServiceLocator.assessmentSession.draft;
    if (widget.propertyId.isEmpty) {
      if (existing != null) {
        setState(() => _property = existing.property);
      } else {
        setState(() => _missingProperty = true);
      }
      return;
    }
    try {
      final p = await ServiceLocator.properties.detail(widget.propertyId);
      if (!mounted) return;
      if (p == null) {
        setState(() => _missingProperty = true);
        return;
      }
      // Resume the same listing, start fresh for a new one (the store keeps
      // inputs only when the property is unchanged).
      ServiceLocator.assessmentSession.start(p);
      setState(() => _property = p);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingError = 'This property could not be loaded.');
    }
  }

  void _submit() {
    final errors = <String>[];
    final concept = _concept;
    final audience = _audience;
    final budgetText = _budget.text.trim();
    double? budget;

    if (concept == null) errors.add('Choose your F&B concept.');
    if (audience == null) errors.add('Choose your primary target customer.');
    if (budgetText.isEmpty) {
      errors.add('Enter your monthly rent budget.');
    } else {
      budget = double.tryParse(budgetText);
      if (budget == null || budget <= 0) {
        errors.add('The rent budget must be a positive amount in RM.');
      }
    }

    setState(() {
      _formError = errors.isEmpty ? null : errors.join(' ');
    });
    if (errors.isNotEmpty) return;

    ServiceLocator.assessmentSession.updateInputs(
      concept: concept!,
      audience: audience!,
      budgetRm: budget!,
    );
    Navigator.of(context).pushNamed('/entrepreneur/assessment-evidence');
  }

  @override
  Widget build(BuildContext context) {
    final p = _property;
    return MobileAppShell(
      appState: widget.appState,
      title: 'New assessment',
      currentRoute: '/entrepreneur/assess',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          SitewiseM3.gutter,
          20,
          SitewiseM3.gutter,
          122,
        ),
        children: [
          FlowBackLink(label: 'Assess'),
          const SizedBox(height: 14),
          Text(
            'NEW ASSESSMENT / STEP 1 OF 3',
            style: SitewiseM3Type.eyebrow,
          ),
          const SizedBox(height: 7),
          Semantics(
            header: true,
            child: Text('Tell us about your business', style: SitewiseM3Type.h1),
          ),
          const SizedBox(height: 8),
          Text(
            p == null
                ? 'Your assessment will stay linked to the property you '
                    'choose.'
                : 'This assessment will stay linked to ${p.title}.',
            style: SitewiseM3Type.lead,
          ),
          const SizedBox(height: 18),
          AssessmentStepper(step: 0),
          const SizedBox(height: 18),
          if (_missingProperty)
            M3EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No property selected',
              message: 'Pick a listing first — the assessment is always '
                  'tied to one property.',
              actionLabel: 'Find a location',
              onAction: () => Navigator.of(context)
                  .pushNamedAndRemoveUntil(
                    '/entrepreneur/explore',
                    (route) => route.isFirst,
                  ),
            )
          else if (_loadingError != null)
            M3Banner(icon: Icons.error_outline_rounded, text: _loadingError!)
          else if (p == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            M3Card(
              padding: const EdgeInsets.all(13),
              child: Row(
                children: [
                  const Icon(
                    Icons.place_outlined,
                    size: 15,
                    color: SitewiseM3.primary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${p.title} · ${p.id}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: SitewiseM3.rowTitle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            M3Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _FieldLabel('F&B concept'),
                  const SizedBox(height: 8),
                  _ChoiceGrid(
                    options: _concepts,
                    selected: _concept,
                    onPick: (v) => setState(() {
                      _concept = v;
                      _formError = null;
                    }),
                  ),
                  const SizedBox(height: 18),
                  _FieldLabel('Monthly rent budget (RM)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _budget,
                    keyboardType: const TextInputType.numberWithOptions(),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      prefixText: 'RM ',
                      hintText: 'e.g. 8500',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() => _formError = null),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Use your expected monthly rental ceiling.',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      color: SitewiseM3.muted,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _FieldLabel('Primary target customer'),
                  const SizedBox(height: 8),
                  _ChoiceGrid(
                    options: _audiences,
                    selected: _audience,
                    onPick: (v) => setState(() {
                      _audience = v;
                      _formError = null;
                    }),
                  ),
                  if (_formError != null) ...[
                    const SizedBox(height: 14),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _formError!,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: SitewiseColors.danger,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  M3PrimaryButton(
                    label: 'Continue to evidence matching',
                    onTap: _submit,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 12.5,
        fontWeight: FontWeight.w800,
        color: SitewiseM3.ink,
      ),
    );
  }
}

/// Single-select chip grid built on the M3 palette. Options wrap instead of
/// scrolling so every choice stays reachable on a narrow phone.
class _ChoiceGrid extends StatelessWidget {
  final List<String> options;
  final String? selected;
  final ValueChanged<String> onPick;

  const _ChoiceGrid({
    required this.options,
    required this.selected,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          Semantics(
            button: true,
            selected: selected == option,
            child: Material(
              color: selected == option ? SitewiseM3.primary : SitewiseM3.surface,
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              child: InkWell(
                borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                onTap: () => onPick(option),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                    border: Border.all(
                      color: selected == option
                          ? SitewiseM3.primary
                          : SitewiseM3.line,
                    ),
                  ),
                  child: Text(
                    option,
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12,
                      fontWeight:
                          selected == option ? FontWeight.w700 : FontWeight.w600,
                      color: selected == option
                          ? SitewiseM3.surface
                          : SitewiseM3.ink,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

