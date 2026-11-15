import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/data/navigation.dart';

/// Admin navigation + user-directory mapping (spec 3 + 6).
void main() {
  test('admin sidebar has exactly the four approved destinations', () {
    final routes = webDestinationsFor(AppRole.admin).map((d) => d.route).toList();
    expect(routes, ['/admin', '/admin/users', '/admin/agents', '/admin/listings']);
  });

  group('user directory mapping', () {
    Map<String, dynamic> row({Object? count = _absent}) => {
      'user_id': '00000000-0000-0000-0000-000000000001',
      'email': 'owner@example.test',
      'full_name': 'Nurul Aiman',
      'role': 'entrepreneur',
      'account_status': 'active',
      'created_at': '2026-02-03T10:00:00Z',
      if (count != _absent) 'listing_count': count,
    };

    test('the backend listing count is carried through', () {
      expect(ApiUserRepository.fromJson(row(count: 3)).listingCount, 3);
    });

    test('a computed zero stays a zero', () {
      expect(ApiUserRepository.fromJson(row(count: 0)).listingCount, 0);
    });

    test('an absent count is unknown, not zero', () {
      expect(ApiUserRepository.fromJson(row()).listingCount, isNull);
    });

    test('the three stored roles map to their own workspace role', () {
      AppRole roleOf(String raw) =>
          ApiUserRepository.fromJson(row()..['role'] = raw).role;
      expect(roleOf('entrepreneur'), AppRole.entrepreneur);
      expect(roleOf('agent'), AppRole.agent);
      expect(roleOf('admin'), AppRole.admin);
      // Legacy aliases canonicalise exactly as the backend does.
      expect(roleOf('administrator'), AppRole.admin);
      expect(roleOf('property_owner'), AppRole.entrepreneur);
    });

    test('every stored account status is representable', () {
      String statusOf(String raw) =>
          ApiUserRepository.fromJson(row()..['account_status'] = raw).status;
      expect(statusOf('pending'), 'Pending');
      expect(statusOf('active'), 'Active');
      expect(statusOf('suspended'), 'Suspended');
    });
  });
}

/// Sentinel so an omitted `listing_count` is distinguishable from an explicit
/// null in the payload.
const Object _absent = Object();