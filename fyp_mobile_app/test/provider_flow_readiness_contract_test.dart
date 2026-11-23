import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural contract tests for the two UI fixes in the Provider flow.
///
/// Full widget pumping is deliberately NOT used here: the screens resolve
/// `ServiceLocator.apiClient`, which is a `final` instance with no injectable
/// transport, so a real widget test would need Supabase credentials and a
/// live FastAPI server. These assertions pin the exact user-visible contract
/// in source instead; the HTTP wire contract is covered separately by
/// `ownership_proof_multipart_test.dart`.
void main() {
  const panelPath =
      'lib/features/property_management/presentation/widgets/'
      'provider_agent_inspection_panel.dart';
  const ownerPath =
      'lib/features/property_management/presentation/pages/'
      'provider_owner_requests_mobile_page.dart';

  final panel = File(panelPath).readAsStringSync();
  final owner = File(ownerPath).readAsStringSync();

  group('Agent inspection readiness UI', () {
    test('has no manual "Check again"/"Retry" readiness button', () {
      expect(panel.toLowerCase().contains('check again'), isFalse);
      // The previous patch's duplicate control was a TextButton labelled
      // "Retry" that re-issued the readiness GET on error.
      expect(panel, isNot(contains("const Text('Retry')")));
      expect(panel, isNot(contains("onPressed: () => refresh(loadChecklist: !_loaded)")));
      // The error still explains what happened and that recovery is automatic.
      expect(panel, contains('Readiness will refresh automatically'));
      expect(panel, contains('style: const TextStyle(color: SitewiseColors.danger)'));
    });

    test('refreshes readiness on every required lifecycle event', () {
      // Screen opens.
      expect(panel, contains('void initState()'));
      expect(panel, contains('    refresh();'));
      // Returning to the screen (route pop and app resume).
      expect(panel, contains('void didPopNext()'));
      expect(panel, contains('refresh(loadChecklist: !_loaded || saved)'));
      expect(panel, contains('AppLifecycleState.resumed'));
      // Checklist saved and missing property details saved.
      expect(panel, contains('await refresh(loadChecklist: false);'));
      expect(panel, contains('if (savedChanges) await refresh(loadChecklist: false);'));
      // Panorama uploaded and confirmed.
      expect(panel, contains('onSynced: () => refresh(loadChecklist: false)'));
      // Submit press re-reads authoritative readiness before confirming.
      expect(panel, contains("ServiceLocator.apiClient.get('\$url/inspection')"));
      expect(panel, contains('updateSubmissionReadiness(data)'));
      // No polling timer was reintroduced.
      expect(panel, isNot(contains('_readinessTimer')));
    });

    test('keeps one Submit button gated on all required evidence', () {
      // Exactly one user-facing submit action - no duplicate button.
      expect(
        RegExp(r"label: const Text\('Submit inspection to Admin'\)")
            .allMatches(panel)
            .length,
        1,
      );
      for (final gate in [
        '!allConfirmed',
        'missingPropertyDetails.isNotEmpty',
        '!ownershipProofAvailable',
        'submissionBlockers.isNotEmpty',
        'panoramaId == null',
      ]) {
        expect(panel, contains(gate), reason: 'missing submit gate: $gate');
      }
      // The interface explains what remains incomplete.
      expect(panel, contains('Still to confirm:'));
      expect(panel, contains('Before sending to Admin'));
      expect(panel, contains('A synced 360° tour is required to submit.'));
      expect(panel, contains('Submit inspection?'));
    });

    test('preserves the four checks, draft save, capture and backend submit', () {
      for (final check in [
        'floor_area_verified',
        'condition_verified',
        'parking_verified',
        'accessibility_verified',
      ]) {
        expect(panel, contains("'$check': false"));
      }
      expect(panel, contains("const Text('Save draft')"));
      expect(panel, contains("'Save checklist'"));
      expect(panel, contains('ProviderPanoramaTourSection('));
      expect(panel, contains("command('submit'"));
      // Still gated server-side; the UI never bypasses the endpoint.
      expect(panel, contains('submissionBlockers'));
    });
  });

  group('Owner Agent Requests error states', () {
    test('separates assignment, upload and Agent-request failures', () {
      expect(owner, contains("String? uploadError;"));
      expect(owner, contains("String? requestError;"));
      for (final entry in [
        ("'Ownership proof upload failed'", 'uploadError!'),
        ("'Agent request failed'", 'requestError!'),
        ("'Agent request status unavailable'", 'error!'),
      ]) {
        final index = owner.indexOf(entry.$1);
        expect(index, greaterThanOrEqualTo(0), reason: 'missing ${entry.$1}');
        expect(
          owner.substring(index, index + 160),
          contains(entry.$2),
          reason: '${entry.$1} must render ${entry.$2}',
        );
      }
    });

    test('surfaces backend rejection and refreshes stored proof status', () {
      expect(owner, contains('readableFailure('));
      expect(owner, contains('const SnackBar('));
      expect(owner, contains("const Text('Ownership proof uploaded successfully')"));
      expect(owner, contains('.statusForProperty('));
      expect(owner, contains('proofStatuses[property.id] = stored.status'));
      // Uploading a document never requests/reassigns an Agent.
      final uploadStart = owner.indexOf('Future<void> uploadOwnershipProof');
      final nextMethod = owner.indexOf(
        '  // SITEWISE_OWNER_REQUESTS_COMPACT_V2',
        uploadStart,
      );
      expect(uploadStart, greaterThanOrEqualTo(0));
      expect(nextMethod, greaterThan(uploadStart));
      final uploadBody = owner.substring(uploadStart, nextMethod);
      expect(uploadBody, isNot(contains('request-agent')));
      expect(uploadBody, isNot(contains('requestAgent(')));
    });
  });
}
