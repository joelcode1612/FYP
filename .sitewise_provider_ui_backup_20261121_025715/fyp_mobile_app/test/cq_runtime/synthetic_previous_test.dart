import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';

class NavigationApi extends ApiClient {
  NavigationApi(this.dto);
  final Map<String, dynamic> dto;
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    expect(path, endsWith('/presentations'));
    writes.add(body);
    return dto;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'Previous revisits only an accepted shown answer through server presentation',
    () async {
      final d =
          jsonDecode(
                File(
                  '../shared_logic/test/fixtures/cq_synthetic_presented_q02.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final api = NavigationApi(d);
      final vm = CqViewModel(
        ApiCustomerQuestionnaireRepository.synthetic(
          api,
          runId: d['synthetic_run_id'] as String,
        ),
        d['session_id'] as String,
      );
      vm.session = CqSession.fromJson(d, allowIsolatedTesting: true);
      expect(vm.previousAnsweredSlot, 'Q01');
      await vm.previous();
      expect(vm.error, isNull);
      expect(api.writes.single, {
        'edit_slot_id': 'Q01',
        ...vm.session!.version,
      });
      // Navigation requests a display; it never manufactures or overwrites an answer.
      expect(api.writes.single.containsKey('value'), false);
      vm.dispose();
    },
  );
}
