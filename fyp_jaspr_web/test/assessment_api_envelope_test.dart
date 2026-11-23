import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';

/// Regression for CP-10 DEF-01.
///
/// The PATCH write endpoints (`saveRequirements`, `completeStage`) answer
/// with the `{"assessment": {...}}` envelope. Before the fix the wrapper was
/// fed straight into `AssessmentRecord.fromJson`, so every non-nullable
/// String cast read null: the UI reported "Your answers were not saved" after
/// the server had already persisted the row (requirements_version bumped),
/// and the chained `complete_stage` call never ran — Stage 2 could never
/// complete through the UI.
///
/// The payload below is the exact shape the server returned in the failing
/// run (logs/api_stage2_complete_debug.json), abbreviated to the fields the
/// parser reads.
Map<String, dynamic> wrappedResponse() => {
      'assessment': {
        'assessment_id': '0a79fba2-3a39-4bd1-96b0-f245a1b2c0a7',
        'property_id': 'MD-02521',
        'status': 'in_progress',
        'current_stage': 3,
        'current_stage_key': 'location_evidence',
        'completed_stages': 2,
        'total_stages': 5,
        'progress_percent': 40,
        'report_available': false,
        'requirements': {
          'fnb_concept': 'cafe_coffee_shop',
          'service_model': 'hybrid',
        },
        'requirements_version': 3,
        'requirements_legacy_view': null,
        'stages': [
          {
            'key': 'select_property',
            'number': 1,
            'title': 'Select property',
            'status': 'complete',
            'completed_at': '2026-11-11T17:54:53.282099+00:00',
            'unavailable_reason': null,
          },
          {
            'key': 'business_requirements',
            'number': 2,
            'title': 'Business preferences',
            'status': 'complete',
            'completed_at': '2026-11-18T04:10:00+00:00',
            'unavailable_reason': null,
          },
        ],
        'capabilities': <String, dynamic>{},
        'next_action': <String, dynamic>{},
        'property': null,
        'created_at': '2026-11-11T17:54:53.282099+00:00',
        'updated_at': '2026-11-18T04:10:00+00:00',
      },
    };

void main() {
  test('DEF-01: the write-endpoint envelope is unwrapped before parsing', () {
    final record = AssessmentApi.parseAssessmentEnvelope(wrappedResponse());
    expect(record.assessmentId, '0a79fba2-3a39-4bd1-96b0-f245a1b2c0a7');
    expect(record.currentStage, 3);
    expect(record.completedStages, 2);
    expect(record.stageByKey('business_requirements')?.status, 'complete');
  });

  test('DEF-01: parsing the raw wrapper fails loudly, not silently', () {
    // Documents the pre-fix behaviour: feeding the wrapper directly throws,
    // which is why the UI surfaced a false save failure. The fix routes both
    // write paths through parseAssessmentEnvelope instead.
    final wrapper = wrappedResponse();
    expect(
      () => AssessmentRecord.fromJson(wrapper),
      throwsA(isA<TypeError>()),
    );
  });

  test('DEF-01: a null property stays null instead of crashing the record',
      () {
    final record = AssessmentApi.parseAssessmentEnvelope(wrappedResponse());
    expect(record.property, isNull);
  });
}
