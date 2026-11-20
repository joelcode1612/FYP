import 'dart:io';

import 'package:test/test.dart';

/// Source-level layering gates for the three Dart packages.
///
/// The checks read files instead of importing libraries on purpose: an import
/// graph cannot see a hand-written `WebAuth.request(...)` inside a component,
/// and neither can a compile error. `backend/tests/test_architecture.py` is the
/// equivalent gate on the Python side, and the allowlists below work the same
/// way — they are asserted with equality, so fixing a listed file fails this
/// test until its entry is removed.
void main() {
  final root = _findMonorepoRoot();

  List<File> _dartFiles(String relativeDir) {
    final dir = Directory('${root.path}/$relativeDir');
    expect(dir.existsSync(), isTrue, reason: 'missing $relativeDir');
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList(growable: false);
  }

  group('domain layer stays pure', () {
    test('shared_logic domain imports no outer layer or platform SDK', () {
      // Application code may not reach down into data/app layers, and the
      // shared package must stay usable from the browser (Jaspr) build.
      final forbidden = [
        RegExp(r'''^\s*import\s+'[^']*data/''', multiLine: true),
        RegExp(r'''^\s*import\s+'[^']*application/''', multiLine: true),
        RegExp(r'''^\s*import\s+'package:flutter''', multiLine: true),
        RegExp(r'''^\s*import\s+'dart:io''', multiLine: true),
        RegExp(r'''^\s*import\s+'package:http''', multiLine: true),
      ];
      final offenders = <String>[];
      for (final file in _dartFiles('shared_logic/lib/src/domain')) {
        final source = file.readAsStringSync();
        if (forbidden.any((p) => p.hasMatch(source))) {
          offenders.add(file.path.replaceAll('\\', '/'));
        }
      }
      expect(offenders, isEmpty);
    });

    test('location analysis rules hold the bands and no transport', () {
      final rules = File(
        '${root.path}/shared_logic/lib/src/domain/services/'
        'location_analysis_rules.dart',
      );
      expect(rules.existsSync(), isTrue);
      final source = rules.readAsStringSync();
      // The rules are reachable without a client, which is the point of the
      // split: no transport port, no HTTP path, no async.
      expect(source.contains('ApiClient'), isFalse);
      expect(source.contains('_client'), isFalse);
      expect(source.contains('/api/v1/'), isFalse);
      // The bands the entrepreneur reads must live here, not in the repository.
      for (final threshold in ['>= 75', '>= 60', '>= 45', '<= 15', '<= 40']) {
        expect(source, contains(threshold));
      }
    });

    test('intelligence repository is transport only', () {
      final repo = File(
        '${root.path}/shared_logic/lib/src/data/repositories/'
        'api_intelligence_repository.dart',
      );
      final source = repo.readAsStringSync();
      expect(source, contains('LocationAnalysisRules.analyse'));
      // A rating band or an evidence sentence in here would mean the split
      // regressed and a threshold change again touches a network call.
      for (final word in ['Strong', 'Good', 'Moderate', 'Weak']) {
        expect(source.contains(word), isFalse, reason: '$word left the rules');
      }
      expect(source.contains('within 500 m'), isFalse);
    });
  });

  group('screens do not own transport', () {
    /// Page components talk to the backend through a repository resolved from
    /// the app's locator. These files still hold a direct call; each entry is
    /// debt, and the assertion below fails when one is fixed but left listed.
    const knownDirectTransport = [
      // Counts the live catalogue through the auth bridge; the KPI needs the
      // server's `meta.total`, which the abstract PropertyRepository does not
      // expose.
      'fyp_jaspr_web/lib/pages/entrepreneur/dashboard_page.dart',
      // Assessment answer submission and the stage PATCH. The web equivalent
      // moved to `data/assessment_api.dart`; mobile still posts inline.
      'fyp_mobile_app/lib/presentation/mobile/entrepreneur/pages/'
          'entrepreneur_assessment_questions_mobile_page.dart',
      // Named a service and used only as the provider workspace's transport
      // seam, but it lives in a `pages/` folder.
      'fyp_mobile_app/lib/presentation/mobile/provider/pages/'
          'provider_workspace_service.dart',
    ];

    /// Three pages build their own repository from the locator's client or
    /// constructor. Nothing leaves the presentation layer, so this is wiring
    /// debt rather than transport debt — but a page that constructs a
    /// repository also decides its lifetime, which is the locator's job.
    const knownInlineWiring = [
      // `submitOwnerListing` / `createOwnerDraft` / `enrichListing` exist only
      // on the web catalogue class; `AppLocator.propertyRepo` is bound to the
      // abstract `PropertyRepository`, which cannot express them.
      'fyp_jaspr_web/lib/pages/entrepreneur/add_property_page.dart',
      'fyp_mobile_app/lib/presentation/mobile/entrepreneur/pages/'
          'entrepreneur_preferences_mobile_page.dart',
      'fyp_mobile_app/lib/presentation/mobile/entrepreneur/pages/'
          'entrepreneur_property_detail_mobile_page.dart',
    ];

    List<String> _matches(Pattern pattern, List<String> dirs) {
      final found = <String>[];
      for (final dir in dirs) {
        for (final file in _dartFiles(dir)) {
          if (!file.readAsStringSync().contains(pattern)) continue;
          found.add(
            file.path
                .replaceAll('\\', '/')
                .replaceFirst('${root.path}/', '')
                .replaceFirst('./', ''),
          );
        }
      }
      return found..sort();
    }

    test('no page directory calls the raw transport', () {
      final direct = RegExp(
        r'''WebAuth\.request|\.apiClient\.(get|post|patch|delete|uploadMultipart|downloadBinary)\(''',
      );
      expect(
        _matches(direct, [
          'fyp_jaspr_web/lib/pages',
          'fyp_mobile_app/lib/presentation',
        ]),
        knownDirectTransport.toList()..sort(),
      );
    });

    test('pages resolve repositories from the locator', () {
      expect(
        _matches(RegExp(r'Api\w+Repository\('), [
          'fyp_jaspr_web/lib/pages',
          'fyp_mobile_app/lib/presentation',
        ]),
        knownInlineWiring.toList()..sort(),
      );
    });
  });
}

/// The suite spans sibling packages, so it locates the monorepo root instead of
/// assuming where the runner started.
Directory _findMonorepoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    final hasApps =
        Directory('${dir.path}/fyp_mobile_app').existsSync() &&
        Directory('${dir.path}/fyp_jaspr_web').existsSync() &&
        Directory('${dir.path}/shared_logic').existsSync();
    if (hasApps) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate the monorepo root from ${Directory.current.path}.',
  );
}
