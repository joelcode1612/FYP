import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

void main() {
  test(
    'conflict and throttling are distinct from connectivity and authority',
    () {
      final conflict = apiOperationFailure(
        status: 409,
        code: 'CQ_STALE_REVISION',
      );
      expect(conflict, isA<ConflictFailure>());
      expect(conflict.backendCode, 'CQ_STALE_REVISION');
      expect(conflict.statusCode, 409);
      expect(apiOperationFailure(status: 429), isA<ThrottledFailure>());
      expect(apiOperationFailure(status: 403), isA<UnauthorizedFailure>());
    },
  );
  test(
    'unknown write outcome and unsafe diagnostics do not leak credentials',
    () {
      final unknown = apiOperationFailure(
        mutation: true,
        message: 'Bearer private-secret',
      );
      expect(unknown.outcomeUnknown, true);
      expect(unknown.message, isNot(contains('private-secret')));
      expect(
        apiOperationFailure(status: 409, code: 'unsafe\nvalue').backendCode,
        isNull,
      );
    },
  );
}
