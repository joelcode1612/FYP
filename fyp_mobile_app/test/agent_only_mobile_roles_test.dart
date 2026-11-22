import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/routing/mobile_role.dart';

void main() {
  test('only the Agent may open the legacy capture route', () {
    expect(canEnterMobileRoute(AppRole.agent, '/owner/capture'), isTrue);
    expect(canEnterMobileRoute(AppRole.owner, '/owner/capture'), isFalse);
    expect(canEnterMobileRoute(AppRole.entrepreneur, '/owner/capture'), isFalse);
    expect(canEnterMobileRoute(AppRole.admin, '/owner/capture'), isFalse);
  });
  test('only Owner can create property and view requests', () {
    expect(canEnterMobileRoute(AppRole.owner, '/provider/add-property'), isTrue);
    expect(canEnterMobileRoute(AppRole.agent, '/provider/add-property'), isFalse);
    expect(canEnterMobileRoute(AppRole.owner, '/provider/requests'), isTrue);
    expect(canEnterMobileRoute(AppRole.agent, '/provider/requests'), isFalse);
  });
  test('Agent assigned property and tasks are accessible', () {
    expect(canEnterMobileRoute(AppRole.agent, '/provider/listings'), isTrue);
    expect(canEnterMobileRoute(AppRole.agent, '/provider/tasks'), isTrue);
  });
}
