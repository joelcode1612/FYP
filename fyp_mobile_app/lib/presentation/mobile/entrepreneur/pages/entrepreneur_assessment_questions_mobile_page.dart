import 'package:flutter/material.dart';
import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/assessment_stepper.dart';
import '../../widgets/m3_kit.dart';

/// **ASSESSMENT / STEP 1 OF 3** — the eight business-preference questions.
///
/// One question per screen with a progress bar and Previous/Next, matching the
/// web workspace exactly: the same snake_case answer tokens, the same backend
/// record, the same validation. Answers are written to
/// `PATCH /api/v1/assessments/{id}` so an interrupted assessment resumes from
/// the server rather than from this device only.
///
/// The answers belong to the personalized constraint layer. They are never fed
/// to the trained PU model, whose 47-feature contract is fixed by the artifact.
class EntrepreneurAssessmentQuestionsPage extends StatefulWidget {
  /// Catalogue id of the property this assessment is for.
  final String propertyId;

  const EntrepreneurAssessmentQuestionsPage({super.key, required this.propertyId});

  @override
  State<EntrepreneurAssessmentQuestionsPage> createState() =>
      _EntrepreneurAssessmentQuestionsPageState();
}

class _Question {
  final String id;
  final String prompt;
  final String help;
  final bool multi;
  final List<(String, String)> options;

  const _Question({
    required this.id,
    required this.prompt,
    required this.help,
    this.multi = false,
    this.options = const [],
  });
}

/// The eight questions. Tokens are the backend's published values.
const List<_Question> _questions = [
  _Question(
    id: 'fnb_concept',
    prompt: 'What kind of F&B business are you opening?',
    help: 'Your concept shapes how competition figures are read.',
    options: [
      ('cafe_coffee_shop', 'Café / Coffee Shop'),
      ('restaurant', 'Restaurant'),
      ('bakery_dessert_shop', 'Bakery / Dessert Shop'),
      ('fast_food_quick_service', 'Fast Food / Quick Service'),
      ('beverage_shop_kiosk', 'Beverage Shop / Kiosk'),
      ('other_fnb', 'Other F&B'),
    ],
  ),
  _Question(
    id: 'service_model',
    prompt: 'How will you serve customers?',
    help: 'Dine-in, takeaway and delivery place different demands on a site.',
    options: [
      ('dine_in', 'Dine-in'),
      ('takeaway_quick_service', 'Takeaway / Quick Service'),
      ('delivery_focused', 'Delivery Focused'),
      ('hybrid', 'Hybrid'),
    ],
  ),
  _Question(
    id: 'target_customers',
    prompt: 'Who are your target customers?',
    help: 'Select every group that matters. At least one is required.',
    multi: true,
    options: [
      ('nearby_residents', 'Nearby Residents'),
      ('office_workers', 'Office Workers'),
      ('students', 'Students'),
      ('commuters', 'Commuters'),
      ('general_public', 'General Public'),
    ],
  ),
  _Question(
    id: 'recommendation_priority',
    prompt: 'What matters most when choosing the location?',
    help: 'The priority the assessment is read against.',
    options: [
      ('high_customer_demand', 'High Customer Demand'),
      ('affordable_operating_location', 'Affordable Operating Location'),
      ('easy_customer_accessibility', 'Easy Customer Accessibility'),
      ('favorable_competition', 'Favorable Competition'),
      ('balanced_suitability', 'Balanced Suitability'),
    ],
  ),
  _Question(
    id: 'target_price_segment',
    prompt: 'How is your menu priced?',
    help: 'Price positioning informs how competitor density is interpreted.',
    options: [
      ('budget_friendly', 'Budget-Friendly'),
      ('mid_range', 'Mid-Range'),
      ('premium', 'Premium'),
      ('mixed_price_range', 'Mixed Price Range'),
    ],
  ),
  _Question(
    id: 'customer_access_mode',
    prompt: 'How will most customers reach you?',
    help: 'Checked against the transport measurements the analysis holds.',
    options: [
      ('walking', 'Walking'),
      ('public_transportation', 'Public Transportation'),
      ('private_vehicle', 'Private Vehicle'),
      ('mixed_transportation', 'Mixed Transportation'),
    ],
  ),
  _Question(
    id: 'max_monthly_rent_myr',
    prompt: 'What is your maximum monthly rental?',
    help: 'In MYR. Must be greater than zero; compared with the asking rent.',
  ),
  _Question(
    id: 'min_floor_area_sqft',
    prompt: 'What is the smallest floor area you can operate in?',
    help: 'In square feet. Must be greater than zero; compared with the listing.',
  ),
];

class _EntrepreneurAssessmentQuestionsPageState
    extends State<EntrepreneurAssessmentQuestionsPage> {
  final Map<String, dynamic> _answers = {};
  final Map<String, TextEditingController> _controllers = {};
  int _step = 0;
  String? _error;
  bool _busy = false;
  String? _assessmentId;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    for (final q in _questions) {
      if (q.options.isEmpty) _controllers[q.id] = TextEditingController();
    }
    _open();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Creates or resumes the server-side assessment for this property.
  Future<void> _open() async {
    try {
      final response = await ServiceLocator.apiClient.post(
        '/api/v1/assessments/',
        {'property_id': widget.propertyId},
      );
      final record = (response['assessment'] as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _assessmentId = '${record['assessment_id']}';
        final stored = (record['requirements'] as Map?)?.cast<String, dynamic>();
        if (stored != null) {
          for (final q in _questions) {
            final value = stored[q.id];
            if (value == null) continue;
            if (q.multi && value is List) {
              _answers[q.id] = [for (final item in value) '$item'];
            } else if (q.options.isEmpty) {
              _controllers[q.id]?.text = '$value';
            } else {
              _answers[q.id] = '$value';
            }
          }
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _fatal = _describe(error));
    }
  }

  /// Turns an API failure into a sentence the entrepreneur can act on.
  static String _describe(Object error) {
    final text = '$error';
    if (text.contains('property_not_saved') || text.contains('403')) {
      return 'Save this property to your shortlist before starting an assessment.';
    }
    if (text.contains('401')) return 'Your session expired. Sign in again.';
    return 'The assessment service could not be reached. Check your connection.';
  }

  bool _valid(_Question q) {
    if (q.options.isEmpty) {
      final parsed = double.tryParse(_controllers[q.id]?.text.trim() ?? '');
      return parsed != null && parsed.isFinite && parsed > 0;
    }
    if (q.multi) {
      final picked = _answers[q.id];
      return picked is List && picked.isNotEmpty;
    }
    return _answers[q.id] is String && '${_answers[q.id]}'.isNotEmpty;
  }

  Map<String, dynamic> _payload() => {
    for (final q in _questions)
      q.id: q.options.isEmpty
          ? double.parse(_controllers[q.id]!.text.trim())
          : _answers[q.id],
  };

  Future<void> _submit({required bool complete}) async {
    if (_busy) return;
    final firstInvalid = _questions.indexWhere((q) => !_valid(q));
    if (firstInvalid >= 0) {
      setState(() {
        _step = firstInvalid;
        _error = 'Answer this question before saving.';
      });
      return;
    }
    final id = _assessmentId;
    if (id == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ServiceLocator.apiClient.patch('/api/v1/assessments/$id', {
        'requirements': _payload(),
        if (complete) 'complete_stage': 'business_requirements',
      });
      if (!mounted) return;
      setState(() => _busy = false);
      if (complete) {
        Navigator.of(context).pushNamed(
          '/entrepreneur/assessment-evidence',
          arguments: widget.propertyId,
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describe(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fatal != null) {
      return MobileAppShell(
        title: 'Assessment',
        currentRoute: '/entrepreneur/assess',
        body: Padding(
          padding: const EdgeInsets.all(SitewiseM3.gutter),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              M3EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Assessment unavailable',
                message: _fatal!,
                actionLabel: 'Back to Assess',
                onAction: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      );
    }

    final q = _questions[_step];
    final isLast = _step == _questions.length - 1;
    final progress = (_step + 1) / _questions.length;

    return MobileAppShell(
      title: 'Business details',
      currentRoute: '/entrepreneur/assess',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          SitewiseM3.gutter,
          20,
          SitewiseM3.gutter,
          122,
        ),
        children: [
          const FlowBackLink(label: 'Assess'),
          const SizedBox(height: 14),
          Text('NEW ASSESSMENT / STEP 1 OF 3', style: SitewiseM3Type.eyebrow),
          const SizedBox(height: 7),
          Semantics(
            header: true,
            child: Text('Tell us about your business', style: SitewiseM3Type.h1),
          ),
          const SizedBox(height: 8),
          Text(
            'Question ${_step + 1} of ${_questions.length} · property '
            '${widget.propertyId}',
            style: SitewiseM3Type.lead,
          ),
          const SizedBox(height: 14),
          AssessmentStepper(step: 0),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: const AlwaysStoppedAnimation(SitewiseM3.primary),
            ),
          ),
          const SizedBox(height: 18),
          M3Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(q.prompt, style: SitewiseM3Type.h2),
                const SizedBox(height: 6),
                Text(
                  q.help,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: SitewiseM3.muted,
                  ),
                ),
                const SizedBox(height: 16),
                if (q.options.isEmpty)
                  TextField(
                    controller: _controllers[q.id],
                    keyboardType: const TextInputType.numberWithOptions(),
                    decoration: InputDecoration(
                      prefixText: q.id == 'max_monthly_rent_myr' ? 'RM ' : null,
                      suffixText: q.id == 'max_monthly_rent_myr' ? null : 'sq ft',
                      hintText: q.id == 'max_monthly_rent_myr' ? '8500' : '900',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (token, caption) in q.options)
                        _Choice(
                          label: caption,
                          selected: _picked(q, token),
                          onTap: () => setState(() {
                            _toggle(q, token);
                            _error = null;
                          }),
                        ),
                    ],
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
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
                Row(
                  children: [
                    if (_step > 0)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setState(() {
                            _step -= 1;
                            _error = null;
                          }),
                          child: const Text('Previous'),
                        ),
                      ),
                    if (_step > 0) const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: M3PrimaryButton(
                        label: _busy
                            ? 'Saving…'
                            : isLast
                            ? 'Save and continue'
                            : 'Next',
                        onTap: () {
                                if (_busy) return;
                                if (!_valid(q)) {
                                  setState(
                                    () => _error =
                                        'Answer this question to continue.',
                                  );
                                  return;
                                }
                                if (isLast) {
                                  _submit(complete: true);
                                } else {
                                  setState(() {
                                    _step += 1;
                                    _error = null;
                                  });
                                }
                              },
                      ),
                    ),
                  ],
                ),
                if (isLast) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : () => _submit(complete: false),
                    child: const Text('Save answers only'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _picked(_Question q, String token) {
    final value = _answers[q.id];
    if (q.multi) return value is List && value.contains(token);
    return value == token;
  }

  void _toggle(_Question q, String token) {
    if (q.multi) {
      final current = [
        for (final item in (_answers[q.id] as List? ?? const [])) '$item',
      ];
      if (current.contains(token)) {
        current.remove(token);
      } else {
        current.add(token);
      }
      _answers[q.id] = current;
      return;
    }
    _answers[q.id] = token;
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? SitewiseM3.primary : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? SitewiseM3.primary : const Color(0xFFE2E8F0),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : SitewiseM3.rowTitle,
          ),
        ),
      ),
    );
  }
}
