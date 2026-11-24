import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';

ProviderListing listing({
  required String status,
  bool isPublished = false,
  bool? backendEditable,
  String? taskState,
}) => ProviderListing(
  id: 11904,
  title: 'Lock test',
  address: 'Test address',
  status: status,
  isPublished: isPublished,
  backendEditable: backendEditable,
  taskState: taskState,
);

void main() {
  test(
    'approved is read-only even unpublished and even when backend says editable',
    () {
      final approved = listing(
        status: 'approved',
        backendEditable: true,
        taskState: 'approved',
      );
      expect(approved.isActive, isFalse);
      expect(approved.lockedForEditing, isTrue);
      expect(approved.canEdit, isFalse);
      expect(
        listing(
          status: 'approved',
          isPublished: true,
          backendEditable: true,
        ).canEdit,
        isFalse,
      );
    },
  );

  test('pending review and verified states are read-only', () {
    for (final status in ['pending', 'under_review', 'verified']) {
      expect(listing(status: status, backendEditable: true).canEdit, isFalse);
    }
    expect(
      listing(status: 'draft', taskState: 'awaiting_review').canEdit,
      isFalse,
    );
  });

  test('draft and correction states remain editable when permitted', () {
    expect(listing(status: 'draft', backendEditable: true).canEdit, isTrue);
    expect(listing(status: 'rejected', backendEditable: true).canEdit, isTrue);
    expect(
      listing(
        status: 'draft',
        taskState: 'corrections',
        backendEditable: true,
      ).canEdit,
      isTrue,
    );
  });

  test('explicit backend denial always wins', () {
    expect(listing(status: 'draft', backendEditable: false).canEdit, isFalse);
    expect(
      listing(
        status: 'rejected',
        backendEditable: false,
        taskState: 'corrections',
      ).canEdit,
      isFalse,
    );
  });
}
