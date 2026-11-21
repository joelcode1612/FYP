// Existing CQ screens and existing test-only bearer override; no production
// identity verification, scientific authority or API dependency is replaced.
import 'package:integration_test/integration_test.dart';
import '../test/cq_runtime/cq_api_widget_test.dart' as existing;
void main(){
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  existing.main();
}
