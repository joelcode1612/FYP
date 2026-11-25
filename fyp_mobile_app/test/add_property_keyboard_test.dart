import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/features/property_management/presentation/pages/sitewise_add_property_mobile_page.dart';
import 'package:fyp/shared/presentation/layouts/mobile_bottom_nav.dart';
import 'package:fyp/shared/presentation/layouts/provider_tab_host.dart';
import 'package:shared_logic/shared_logic.dart';

class _TestAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => AuthState.initializing;
}

class _DraftApi extends ApiClient {
  final createRequests = <Map<String, dynamic>>[];
  final updateRequests = <String>[];
  final readRequests = <String>[];
  bool failFirstRead = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    readRequests.add(path);
    if (failFirstRead && readRequests.length == 1) throw const NetworkFailure();
    return {
      'data': {'id': 42, 'name': 'Existing draft', 'property_type': 'Shoplot'},
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    createRequests.add(body);
    if (createRequests.length == 1) {
      throw const NetworkFailure.transport(
        'Connection lost.',
        outcomeUnknown: true,
      );
    }
    return {
      'data': {'id': 42},
      'meta': {'replayed': true},
    };
  }

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    updateRequests.add(path);
    return {
      'data': {'id': 42, ...body},
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _openDraftPage(
  WidgetTester tester,
  _DraftApi api, {
  String? id,
}) async {
  final previousRepository = ServiceLocator.ownerListings;
  final previousMode = MobileConfig.overrideUsesLiveApi;
  ServiceLocator.ownerListings = ApiOwnerListingRepository(api);
  MobileConfig.overrideUsesLiveApi = true;
  addTearDown(() {
    ServiceLocator.ownerListings = previousRepository;
    MobileConfig.overrideUsesLiveApi = previousMode;
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authNotifierProvider.overrideWith(_TestAuthNotifier.new),
        appInitialStateProvider.overrideWithValue(
          const AppState(role: AppRole.owner),
        ),
      ],
      child: MaterialApp(
        home: SitewiseAddPropertyMobilePage(initialDraftId: id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _saveProgress(WidgetTester tester) async {
  final button = find.text('Save progress');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'title-only save keeps entries and reuses the create key after a lost response',
    (tester) async {
      final api = _DraftApi();
      await _openDraftPage(tester, api);
      await tester.enterText(find.byType(TextField).first, 'First title');
      await _saveProgress(tester);
      expect(find.text('First title'), findsOneWidget);
      expect(find.text('Connection lost.'), findsOneWidget);
      expect(api.createRequests.single['rental_price'], isNull);

      await tester.enterText(find.byType(TextField).first, 'Edited title');
      await _saveProgress(tester);
      expect(api.createRequests.length, 2);
      expect(
        api.createRequests.first['draft_request_id'],
        api.createRequests.last['draft_request_id'],
      );
      expect(api.updateRequests, ['/api/v1/properties/listings/42']);
      expect(
        find.text('Draft progress saved.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('failed resume blocks writes and retries the original draft ID', (
    tester,
  ) async {
    final api = _DraftApi()..failFirstRead = true;
    await _openDraftPage(tester, api, id: '42');
    expect(find.text('Save progress'), findsNothing);
    expect(api.createRequests, isEmpty);

    await tester.tap(find.text('Retry loading draft'));
    await tester.pumpAndSettle();
    expect(find.text('Existing draft'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Edited title');
    await _saveProgress(tester);
    expect(api.readRequests, List.filled(2, '/api/v1/properties/listings/42'));
    expect(api.createRequests, isEmpty);
    expect(api.updateRequests, ['/api/v1/properties/listings/42']);
  });

  testWidgets(
    'Owner Add Property keeps the tab stack stable as the keyboard opens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(_TestAuthNotifier.new),
            appInitialStateProvider.overrideWithValue(
              const AppState(role: AppRole.owner),
            ),
          ],
          child: const MaterialApp(
            home: ProviderTabHost(initialRoute: ProviderTabHost.addRoute),
          ),
        ),
      );

      final form = find.byType(SitewiseAddPropertyMobilePage);
      final formHeight = tester.getSize(form).height;
      final viewport = find.descendant(
        of: form,
        matching: find.byType(SingleChildScrollView),
      );
      final closedViewportHeight = tester.getSize(viewport).height;
      final dock = find.byType(MobileBottomNav);
      final dockHeight = tester.getSize(dock).height;
      final title = find.byType(TextField).first;
      await tester.tap(title);
      await tester.pump();

      tester.view.padding = const FakeViewPadding();
      for (final inset in [20.0, 140.0, 320.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
        expect(tester.getSize(form).height, formHeight);
        expect(tester.getSize(dock).height, dockHeight);
        expect(dock.hitTestable(), findsNothing);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText).first)
              .focusNode
              .hasFocus,
          isTrue,
        );
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(title).bottom, lessThan(480));
      expect(tester.getRect(viewport).bottom, closeTo(480, 1));

      tester.view.viewInsets = const FakeViewPadding();
      tester.view.padding = const FakeViewPadding(bottom: 24);
      await tester.pumpAndSettle();
      expect(tester.getSize(dock).height, dockHeight);
      expect(dock.hitTestable(), findsOneWidget);
      expect(tester.getSize(viewport).height, closedViewportHeight);
      expect(tester.takeException(), isNull);
    },
  );
}
