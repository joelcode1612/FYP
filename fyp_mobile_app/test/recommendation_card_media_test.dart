import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/presentation/mobile/entrepreneur/pages/entrepreneur_recommendations_mobile_page.dart';
import 'package:shared_logic/shared_logic.dart';

/// Card-level acceptance for the Recommendations redesign:
/// full-width gallery with a photo counter, the 360° action ONLY for a
/// backend-ready panorama, plain-language requirement verdicts (never a
/// bare `no criteria`), grouped rent/area figures and aligned actions.
RankedProperty _item({
  List<String> photos = const [],
  Map<String, dynamic>? panorama,
  int matchedCount = 2,
  int verifiableCount = 3,
}) {
  return RankedProperty.fromJson({
    'property_id': 'MD-01755',
    'title': 'Corner Shoplot, Taman Sri Tebrau',
    'address': 'Jalan Tebrau',
    'city': 'Johor Bahru',
    'state': 'Johor',
    'rental_rm': 7500,
    'size_sqft': 1760,
    'property_type': 'Shoplot',
    'image_url': 'https://img.example/cover.jpg',
    'photos': photos,
    'panorama': ?panorama,
    'research': {
      'catalog_suitability_score': 71.4,
      'suitability_available': true,
      'pu_score': 71.4,
      'pu_available': true,
      'pu_score_scale': '0-100',
    },
    'recommendation': {
      'available': true,
      'rank': 1,
      'matched_count': matchedCount,
      'verifiable_count': verifiableCount,
      'matched_requirements': ['Budget', 'Foot traffic'],
      'unmatched_requirements': <String>[],
    },
  });
}

Widget _host(Widget child) => MaterialApp(
  routes: {
    '/entrepreneur/panorama': (r) {
      final args = ModalRoute.of(r)!.settings.arguments! as Map;
      return Scaffold(
        body: Center(child: Text('PANO:${args['url']}|${args['title']}')),
      );
    },
    '/entrepreneur/property-detail': (r) => Scaffold(
      body: Center(
        child: Text('DETAIL:${ModalRoute.of(r)!.settings.arguments}'),
      ),
    ),
  },
  home: Scaffold(
    body: ListView(shrinkWrap: true, children: [child]),
  ),
);

/// Pumps the card and drains the network-image backoff timers so no test
/// ends with a pending Timer (photos never load in the test HTTP sandbox).
Future<void> _pumpCard(
  WidgetTester tester,
  RankedProperty item, {
  void Function()? onSave,
}) async {
  await tester.pumpWidget(
    _host(
      RecommendationCard(
        item: item,
        isSaved: false,
        isCompared: false,
        isSelected: false,
        onOpen: () {},
        onSave: onSave ?? () {},
        onCompare: () {},
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 8));
  await tester.pump();
}

void main() {
  testWidgets('multiple photos render a counter chip', (tester) async {
    await _pumpCard(
      tester,
      _item(
        photos: const [
          'https://img.example/1.jpg',
          'https://img.example/2.jpg',
          'https://img.example/3.jpg',
        ],
      ),
    );
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('a single photo shows no counter', (tester) async {
    await _pumpCard(
      tester,
      _item(photos: const ['https://img.example/1.jpg']),
    );
    expect(find.textContaining(' / '), findsNothing);
  });

  testWidgets('360° action appears only for a ready panorama and opens the viewer', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      _item(
        photos: const ['https://img.example/1.jpg'],
        panorama: {
          'available': true,
          'status': 'ready',
          'url': 'https://cdn.example/pano.jpg',
          'reason': null,
        },
      ),
    );
    expect(find.text('360° View'), findsOneWidget);

    await tester.tap(find.text('360° View'));
    await tester.pumpAndSettle();
    expect(
      find.text('PANO:https://cdn.example/pano.jpg|Corner Shoplot, Taman Sri Tebrau'),
      findsOneWidget,
    );
  });

  testWidgets('processing or absent panorama never shows a 360° action', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      _item(
        photos: const ['https://img.example/1.jpg'],
        panorama: {
          'available': false,
          'status': 'processing',
          'url': null,
          'reason': 'still processing',
        },
      ),
    );
    expect(find.text('360° View'), findsNothing);

    await _pumpCard(tester, _item(photos: const ['https://img.example/1.jpg']));
    expect(find.text('360° View'), findsNothing);
  });

  testWidgets('verdict states: verifiable count, and the explained fallback', (
    tester,
  ) async {
    await _pumpCard(tester, _item(matchedCount: 2, verifiableCount: 3));
    expect(
      find.text('Meets 2 of 3 of your requirements.'),
      findsOneWidget,
    );

    await _pumpCard(tester, _item(matchedCount: 0, verifiableCount: 0));
    expect(find.textContaining('Fit not verified yet'), findsOneWidget);
    expect(find.textContaining('no criteria'), findsNothing);
  });

  testWidgets('rent and floor area are grouped and emphasised', (tester) async {
    await _pumpCard(tester, _item());
    expect(find.text('RM 7,500/mo'), findsOneWidget);
    expect(find.text('1,760 sq ft'), findsOneWidget);
    expect(find.text('Monthly rent'), findsOneWidget);
    // (the fixture avoids a requirement literally named 'Floor area' so this
    // finder addresses the metric label only)
    expect(find.text('Floor area'), findsOneWidget);
  });

  testWidgets('actions are the aligned trio: details, insights, compare', (
    tester,
  ) async {
    var saved = 0;
    await _pumpCard(tester, _item(), onSave: () => saved++);
    expect(find.text('View Details'), findsOneWidget);
    expect(find.text('Insights'), findsOneWidget);
    expect(find.text('Compare'), findsOneWidget);

    // The actions row can sit below the 600px test viewport; scroll it in
    // before tapping so the hit-test lands on the real button.
    await tester.ensureVisible(find.text('View Details'));
    await tester.pump();
    await tester.tap(find.text('View Details'));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL:MD-01755'), findsOneWidget);
  });

  testWidgets('bookmark toggle sits over the media and calls onSave', (
    tester,
  ) async {
    var saved = 0;
    await _pumpCard(tester, _item(), onSave: () => saved++);
    final toggle = find.byIcon(Icons.bookmark_border);
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    expect(saved, 1);
  });
}
