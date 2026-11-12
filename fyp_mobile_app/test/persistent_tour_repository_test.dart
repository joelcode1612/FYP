import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/data/datasources/local/draft_local_data_source.dart';
import 'package:fyp/data/repositories/persistent_tour_repository.dart';
import 'package:shared_logic/shared_logic.dart';

void main() {
  PersistentTourRepository repository(InMemoryDraftLocalDataSource source) =>
      PersistentTourRepository(source, initialTours: () => const []);

  group('PersistentTourRepository', () {
    test(
      'restores a draft and its frame progress after a repository restart',
      () async {
        final source = InMemoryDraftLocalDataSource();
        final firstRun = repository(source)..setAccount('owner-a');
        final created = await firstRun.createDraft(
          propertyId: 'listing-42',
          title: 'AR capture',
          frameCount: 0,
        );
        await firstRun.updateTour(
          created.copyWith(frameCount: 12, sceneCount: 12),
        );

        final restarted = repository(source)..setAccount('owner-a');
        final restored = await restarted.tourForPropertyDraft('listing-42');

        expect(restored, isNotNull);
        expect(restored!.id, created.id);
        expect(restored.frameCount, 12);
        expect(restored.sceneCount, 12);
      },
    );

    test(
      'does not expose one account\'s capture draft to another account',
      () async {
        final source = InMemoryDraftLocalDataSource();
        final firstRun = repository(source)..setAccount('owner-a');
        await firstRun.createDraft(
          propertyId: 'listing-42',
          title: 'Owner A capture',
          frameCount: 3,
        );

        final otherAccount = repository(source)..setAccount('owner-b');

        expect(await otherAccount.tourForPropertyDraft('listing-42'), isNull);
      },
    );

    test(
      'preserves the newest unfinished draft selection across reload',
      () async {
        final source = InMemoryDraftLocalDataSource();
        final firstRun = repository(source)..setAccount('owner-a');
        final older = await firstRun.createDraft(
          propertyId: 'listing-42',
          title: 'Older capture',
          frameCount: 1,
        );
        await firstRun.updateTour(
          older.copyWith(status: VirtualTourStatus.ready),
        );
        final latest = await firstRun.createDraft(
          propertyId: 'listing-42',
          title: 'Latest capture',
          frameCount: 7,
        );

        final restarted = repository(source)..setAccount('owner-a');
        final resumable = await restarted.tourForPropertyDraft('listing-42');

        expect(resumable?.id, latest.id);
        expect(resumable?.frameCount, 7);
      },
    );
  });
}
