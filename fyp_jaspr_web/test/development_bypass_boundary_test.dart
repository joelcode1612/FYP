import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/data/dev_auth_bypass.dart';

void main() {
  test(
    'production configuration refuses bypass even if explicitly requested',
    () {
      for (final host in ['localhost', '127.0.0.1', 'sitewise.example']) {
        expect(
          developmentBypassAllowed(
            requested: true,
            developmentBuild: true,
            productionBuild: true,
            host: host,
          ),
          isFalse,
        );
      }
    },
  );
  test('explicit local development is required', () {
    expect(
      developmentBypassAllowed(
        requested: true,
        developmentBuild: true,
        productionBuild: false,
        host: '127.0.0.1',
      ),
      isTrue,
    );
    expect(
      developmentBypassAllowed(
        requested: false,
        developmentBuild: true,
        productionBuild: false,
        host: '127.0.0.1',
      ),
      isFalse,
    );
    expect(
      developmentBypassAllowed(
        requested: true,
        developmentBuild: false,
        productionBuild: false,
        host: '127.0.0.1',
      ),
      isFalse,
    );
    expect(
      developmentBypassAllowed(
        requested: true,
        developmentBuild: true,
        productionBuild: false,
        host: 'sitewise.example',
      ),
      isFalse,
    );
    expect(
      developmentBypassAllowed(
        requested: true,
        developmentBuild: true,
        productionBuild: false,
        host: 'localhost.example',
      ),
      isFalse,
    );
  });
}
