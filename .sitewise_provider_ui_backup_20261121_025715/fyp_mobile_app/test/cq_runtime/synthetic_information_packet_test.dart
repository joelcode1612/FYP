import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/assessment/view/cq_session_page.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';

class PacketApi extends ApiClient {
  PacketApi(this.fixture, {this.loseFirst = false, this.initial = 'concept'})
    : stage = initial;
  final Map<String, dynamic> fixture;
  final bool loseFirst;
  final String initial;
  String stage;
  bool lost = false;
  final deliveries = <String>[];
  final order = ['concept', 'menu', 'offer', 'occasion', 'features', 'ready'];
  Map<String, dynamic> get current => {
    ...((fixture['states'] as Map)[stage] as Map<String, dynamic>),
    'manifest': fixture['manifest'],
  };
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
    if (path.endsWith('/stimuli')) {
      expect(body['kind'], stage);
      expect(body['expected_revision'], current['revision']);
      deliveries.add(stage);
      stage = order[order.indexOf(stage) + 1];
      if (loseFirst && !lost) {
        lost = true;
        throw NetworkFailure.transport(
          'Test response lost after commit.',
          outcomeUnknown: true,
        );
      }
      return current;
    }
    if (path.endsWith('/presentations')) {
      expect(stage, 'ready');
      return current;
    }
    if (path.endsWith('/rendered')) {
      final result = current;
      result['presentation'] = {
        ...(result['presentation'] as Map),
        'rendered': true,
      };
      return result;
    }
    throw StateError('Unexpected packet request $path');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Map<String, dynamic> fixture() =>
      jsonDecode(
            File(
              '../shared_logic/test/fixtures/cq_synthetic_information_packet.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final lost in [false, true]) {
    test(
      'one packet confirmation preserves five ordered deliveries; lost response=$lost',
      () async {
        final f = fixture(), api = PacketApi(f, loseFirst: lost);
        final vm = CqViewModel(
          ApiCustomerQuestionnaireRepository.synthetic(
            api,
            runId: api.current['synthetic_run_id'] as String,
          ),
          api.current['session_id'] as String,
        );
        addTearDown(vm.dispose);
        await vm.load();
        expect(vm.displayedSyntheticStimuli, api.order.take(5).toList());
        await vm.acknowledgeDisplayedStimuli(vm.displayedSyntheticStimuli);
        if (lost) {
          expect(vm.error, isNotNull);
          await vm.retry();
        }
        expect(vm.error, isNull);
        expect(api.deliveries, api.order.take(5).toList());
        expect(vm.session!.presentation!['slot_id'], 'Q02');
        expect(vm.session!.data['next_stimulus_kind'], isNull);
      },
    );
  }
  test(
    'reopened partial packet preserves earlier deliveries and confirms only remaining versions',
    () async {
      final f = fixture(), api = PacketApi(f, initial: 'occasion');
      final vm = CqViewModel(
        ApiCustomerQuestionnaireRepository.synthetic(
          api,
          runId: api.current['synthetic_run_id'] as String,
        ),
        api.current['session_id'] as String,
      );
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.displayedSyntheticStimuli, ['occasion', 'features']);
      await vm.acknowledgeDisplayedStimuli(vm.displayedSyntheticStimuli);
      expect(api.deliveries, ['occasion', 'features']);
      expect(vm.error, isNull);
    },
  );
  testWidgets(
    'context packet shows all required source texts with one Continue action',
    (tester) async {
      final f = fixture(), api = PacketApi(f);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cqRepositoryProvider.overrideWithValue(
              ApiCustomerQuestionnaireRepository.synthetic(
                api,
                runId: api.current['synthetic_run_id'] as String,
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CqSessionPage(
                sessionId: api.current['session_id'] as String,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final kind in api.order.take(5)) {
        final stimulus =
            ((f['manifest'] as Map)['stimuli'] as Map)[kind] as Map;
        expect(
          find.text((stimulus['text'] as Map)['EN'] as String),
          findsOneWidget,
        );
      }
      expect(find.text('Continue to questions'), findsOneWidget);
      expect(find.text('Continue with this information'), findsNothing);
      expect(
        api.deliveries,
        isEmpty,
      ); // Rendering alone never records acknowledgment.
      await tester.ensureVisible(find.byKey(const Key('cq-stimulus')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cq-stimulus')));
      await tester.pumpAndSettle();
      expect(api.deliveries, api.order.take(5).toList());
      expect(find.text('Q02'), findsOneWidget);
    },
  );
}
