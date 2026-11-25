import 'dart:convert';
import 'dart:io';

import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_questionnaire.dart';

/// Contract test for the Stage 4 Section A client model.
///
/// The fixture is **not** hand-written. It is the exact response body captured
/// from `GET /api/v1/project1-workflow/assessments/{id}/stage4/
/// preview-questionnaire` against the isolated PG18 database, for the confirmed
/// assessment `3eac222f-5376-426c-866e-bae90c0825ba` at revision 19
/// (confirmation `1513ede5-701b-4222-bca8-9f7b46c78cef`).
///
/// Its purpose is to prove the client parses real server output, not a shape
/// this repository invented. Two owner declarations drive the substitutions
/// below: `M2V2-01 = "UNDECIDED"` (so the area stays unresolved) and
/// `M2V2-14 = PRICED, Flat White, 12 oz, RM 12.50`.
const fixturePath = 'test/fixtures/stage4_preview_q01_q13_server_payload.json';

/// Question ids that must still show a placeholder, because the owner has not
/// declared a study area. Exactly these four contain `[named area]`.
const expectedUnresolvedIds = {'Q01', 'Q02', 'Q05', 'Q12'};

/// Questions whose governed wording carries no placeholder at all, so the
/// populated stem must be byte-identical to the template.
const expectedNoSubstitutionIds = {
  'Q03',
  'Q04',
  'Q06',
  'Q08',
  'Q09',
  'Q10',
  'Q11',
};

Map<String, dynamic> loadPayload() =>
    jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;

void main() {
  final questionnaire = PreviewQuestionnaire.fromJson(loadPayload());

  group('Stage 4 Section A — recorded server payload', () {
    test('all thirteen governed questions are present, in order', () {
      expect(questionnaire.questionCount, 13);
      expect(questionnaire.questions, hasLength(13));
      expect(
        questionnaire.questions.map((q) => q.questionId).toList(),
        [for (var i = 1; i <= 13; i++) 'Q${i.toString().padLeft(2, '0')}'],
      );
    });

    test('the payload describes a preview, never an authorisation', () {
      expect(questionnaire.authority, 'PREVIEW_ONLY_NON_AUTHORITATIVE');
      expect(questionnaire.catalogueVersion, 'cq-preview-catalogue/1');
      // A preview that claimed fielding authority would be a contract breach.
      expect(questionnaire.fieldingAuthorized, isFalse);
    });

    test('no governed core question is reported as approved', () {
      // Zero is the fact that makes preview-only the only honest surface: the
      // fixed core has no scientific approval, so nothing here may be fielded.
      expect(questionnaire.approvedQuestionCount, 0);
      for (final question in questionnaire.questions) {
        expect(
          question.approvalState,
          'NOT_APPROVED',
          reason: '${question.questionId} must not be reported as approved',
        );
        expect(
          question.measurementStatus,
          isNot('APPROVED'),
          reason: '${question.questionId} measurement is not approved',
        );
        expect(question.measurementStatus, isNotEmpty);
      }
    });

    test('exactly the undeclared-area questions stay unresolved', () {
      expect(questionnaire.populationStatus, 'PARTIAL_UNRESOLVED');
      final unresolved = {
        for (final q in questionnaire.questions)
          if (q.hasUnresolvedRequiredSlot) q.questionId,
      };
      expect(unresolved, expectedUnresolvedIds);
      // The count the UI prints must agree with the rows it renders.
      expect(questionnaire.unresolvedRequiredSlotCount, unresolved.length);
    });

    test('an UNDECIDED study area keeps the placeholder visible', () {
      // Hiding the question would misreport the instrument as shorter than it
      // is; the governed bracket must survive into the rendered stem.
      final q01 = questionnaire.questions.first;
      expect(q01.questionId, 'Q01');
      expect(q01.populatedStem, contains('[named area]'));
      expect(q01.unresolvedSlots, hasLength(1));
      final slot = q01.unresolvedSlots.single;
      expect(slot.slot, 'named_area');
      expect(slot.required, isTrue);
      expect(slot.source, contains('M2V2-01'));
      expect(slot.reason, isNotEmpty);
    });

    test('a declared offer is substituted into the price question', () {
      final q07 = questionnaire.questions[6];
      expect(q07.questionId, 'Q07');
      expect(q07.populationStatus, 'COMPLETE');
      expect(q07.hasUnresolvedRequiredSlot, isFalse);
      expect(q07.populatedStem, contains('RM 12.50'));
      expect(q07.populatedStem, contains('Flat White, 12 oz'));
      // Nothing governed may be left as a raw placeholder once resolved.
      expect(q07.populatedStem, isNot(contains('[')));
      expect(q07.populatedStem, isNot(contains(']')));
    });

    test('questions without placeholders are rendered verbatim', () {
      for (final question in questionnaire.questions) {
        if (!expectedNoSubstitutionIds.contains(question.questionId)) continue;
        expect(
          question.populatedStem,
          question.stemTemplate,
          reason: '${question.questionId} has no placeholder and must not be '
              'reworded by the client',
        );
        expect(question.populationStatus, 'NO_SUBSTITUTION_REQUIRED');
      }
    });

    test('the concept version is substituted but the area is not', () {
      final q05 = questionnaire.questions[4];
      expect(q05.questionId, 'Q05');
      // Declared concept version, taken from the confirmed business context.
      expect(q05.populatedStem, contains('M2-CONFIRMED-19-'));
      // The same question still needs the area, so both states coexist.
      expect(q05.populatedStem, contains('[named area]'));
    });

    test('answer codes are carried through for rendering', () {
      final q13 = questionnaire.questions.last;
      expect(q13.questionId, 'Q13');
      expect(q13.responseType, 'ordinal_single');
      expect(q13.maxSelections, 1);
      expect(q13.codes, hasLength(7));
      expect(q13.codes, contains('PREFER_NOT_TO_ANSWER'));
      expect(q13.construct, 'EXP01_PRICE_EXPECTATION');
    });

    test('Q13 substitution replaces the governed item, and is recorded here', () {
      // The governed stem names its own concrete item. The server substitutes
      // the owner's declared product instead, which changes what is measured.
      // This test pins the *current* behaviour so the divergence from the
      // governed literal cannot drift unnoticed: see DD-030.
      final q13 = questionnaire.questions.last;
      expect(
        q13.stemTemplate,
        'What would you expect to pay for [defined item: medium latte, dine-in]?',
      );
      expect(
        q13.populatedStem,
        'What would you expect to pay for Flat White, 12 oz?',
      );
      expect(q13.populatedStem, isNot(contains('medium latte')));
    });
  });
}
