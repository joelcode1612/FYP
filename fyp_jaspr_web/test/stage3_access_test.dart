import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/application/stage3_access.dart';

void main() {
  test('reads the current link even when no local cache exists', () async {
    var reads = 0;
    final verified = await verifyStage3M2Link(
      expectedM2Id: 'confirmed-m2',
      readCurrentLink: () async {
        reads++;
        return {'m2_assessment_id': 'confirmed-m2'};
      },
    );
    expect(verified, isTrue);
    expect(reads, 1);
  });

  test('rejects a missing or changed link and propagates service errors', () async {
    expect(await verifyStage3M2Link(expectedM2Id: 'old',
        readCurrentLink: () async => {'m2_assessment_id': 'new'}), isFalse);
    expect(await verifyStage3M2Link(expectedM2Id: 'old',
        readCurrentLink: () async => null), isFalse);
    await expectLater(verifyStage3M2Link(expectedM2Id: 'old',
        readCurrentLink: () async => throw StateError('service unavailable')),
        throwsStateError);
  });
}
