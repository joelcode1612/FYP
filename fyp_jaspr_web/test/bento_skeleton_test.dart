import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/ui.dart';

/// Structure test for [BentoSkeleton]: it must mirror the loaded bento
/// geometry — head, 4 KPI tiles, hero + wide + 3 cards — so the swap from
/// skeleton to data never reflows the page.
void main() {
  testComponents('bento skeleton mirrors the loaded grid structure', (
    tester,
  ) async {
    tester.pumpComponent(const BentoSkeleton());

    // bh-title: title + 2 text rows; bh-actions: 3 rows; kpis: 4 blocks;
    // bento: hero + wide + 3 cards. 3 + 3 + 4 + 5 = 15 skeleton blocks.
    expect(find.byType(Skeleton), findsNComponents(15));
    expect(find.byType(BentoSkeleton), findsOneComponent);
  });
}
