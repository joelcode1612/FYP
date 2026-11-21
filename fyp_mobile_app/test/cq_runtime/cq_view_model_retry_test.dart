import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/assessment/presentation/viewmodels/cq_view_model.dart';

class LostDeliveryApi implements ApiClient {
  final Map<String, dynamic> fixture;
  late Map<String, dynamic> current = fixture['before'] as Map<String, dynamic>;
  int posts = 0;
  LostDeliveryApi(this.fixture);
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => current;
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    posts++;
    expect(path, endsWith('/stimuli'));
    if (posts == 1) {
      expect(body['kind'], 'concept');
      current = {
        ...fixture['afterConcept'] as Map<String, dynamic>,
        'manifest': fixture['before']['manifest'],
      };
      throw const NetworkFailure(
        'Simulated response lost after committed delivery.',
      );
    }
    expect(posts, 2);
    expect(body['kind'], 'menu');
    current = {
      ...fixture['afterMenu'] as Map<String, dynamic>,
      'manifest': fixture['before']['manifest'],
    };
    return current;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RefusedWriteApi implements ApiClient {
  final Map<String, dynamic> data;
  final bool loseFirstResponse;
  int writes = 0, reads = 0;
  final List<String> requestIds = [];
  RefusedWriteApi(this.data, {this.loseFirstResponse = false});
  @override
  Future<Map<String, dynamic>> get(
    String p, {
    Map<String, String>? query,
  }) async {
    reads++;
    return data;
  }

  @override
  Future<Map<String, dynamic>> post(String p, Map<String, dynamic> body) async {
    writes++;
    requestIds.add(body['request_id'] as String);
    if (loseFirstResponse && writes == 1) {
      throw const NetworkFailure.transport(
        'Response lost.',
        outcomeUnknown: true,
      );
    }
    throw const ConflictFailure(
      'Reload saved session.',
      backendCode: 'CQ_STALE_REVISION',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final lost in [false, true]) {
    test(
      'conflict reloads without replay; uncertain response retains identity: $lost',
      () async {
        final data =
            jsonDecode(
                  File(
                    '../shared_logic/test/fixtures/cq_session_isolated.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final api = RefusedWriteApi(data, loseFirstResponse: lost);
        final vm = CqViewModel(
          ApiCustomerQuestionnaireRepository(api, allowIsolatedTesting: true),
          data['session_id'],
        );
        addTearDown(vm.dispose);
        await vm.load();
        await vm.submit();
        expect(api.writes, 1);
        if (lost) {
          await vm.retry();
          expect(api.writes, 2);
          expect(api.requestIds.toSet(), hasLength(1));
        }
        final writes = api.writes, reads = api.reads;
        await vm.retry();
        expect(api.writes, writes);
        expect(api.reads, reads + 1);
        expect(vm.error, isNull);
      },
    );
  }
  test(
    'retry reconciles a committed delivery and requires a new acknowledgement for the next stimulus',
    () async {
      final fixture =
          jsonDecode(
                File(
                  '../shared_logic/test/fixtures/cq_delivery_retry.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final api = LostDeliveryApi(fixture),
          repo = ApiCustomerQuestionnaireRepository(
            api,
            allowIsolatedTesting: true,
          );
      final vm = CqViewModel(repo, api.current['session_id'] as String);
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.session!.data['next_stimulus_kind'], 'concept');
      await vm.stimulus();
      expect(vm.error, isNotNull);
      expect(api.posts, 1);
      await vm.retry();
      expect(vm.error, isNull);
      expect(api.posts, 1);
      expect(vm.session!.data['next_stimulus_kind'], 'menu');
      await vm.stimulus();
      expect(api.posts, 2);
      expect(vm.session!.data['next_stimulus_kind'], 'offer');
    },
  );
}
