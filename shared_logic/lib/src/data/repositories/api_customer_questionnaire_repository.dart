import '../../core/network/api_client.dart';
import '../../domain/entities/customer_questionnaire.dart';

class ApiCustomerQuestionnaireRepository {
  final ApiClient client;
  final bool allowIsolatedTesting;
  final String basePath;
  final String? syntheticRunId;
  const ApiCustomerQuestionnaireRepository(
    this.client, {
    this.allowIsolatedTesting = false,
  }) : basePath = '/api/v1/cq',
       syntheticRunId = null;

  ApiCustomerQuestionnaireRepository.synthetic(
    this.client, {
    required String runId,
  }) : allowIsolatedTesting = true,
       syntheticRunId = runId,
       basePath = '/api/v1/cq/developer-imports/${Uri.encodeComponent(runId)}';
  Future<({String state, List<CqInvitation> invitations})> invitations() async {
    final d = await client.get('$basePath/invitations');
    if (d['contract_version'] != 'cq-invitations/1' ||
        !['ready', 'held', 'empty'].contains(d['state'])) {
      throw const FormatException('Invalid CQ invitation response.');
    }
    final invitations = (d['invitations'] as List)
        .map(
          (x) => CqInvitation.fromJson(
            x as Map<String, dynamic>,
            allowIsolatedTesting: allowIsolatedTesting,
          ),
        )
        .toList(growable: false);
    if (d['state'] != 'ready' && invitations.isNotEmpty)
      throw const FormatException('Unapproved invitations.');
    return (state: d['state'] as String, invitations: invitations);
  }

  CqSession _parse(Map<String, dynamic> d, {String? sid, CqSession? previous}) {
    final s = CqSession.fromJson(d, allowIsolatedTesting: allowIsolatedTesting);
    if (syntheticRunId != null &&
        (d['synthetic_execution'] != true ||
            d['synthetic_run_id'] != syntheticRunId ||
            d['origin'] != 'SYNTHETIC_TEST' ||
            d['real_reportable'] != false ||
            d['production_fielding_authorized'] != false)) {
      throw const FormatException('Synthetic execution boundary mismatch.');
    }
    if ((sid != null && s.id != sid) ||
        (previous != null &&
            (s.manifestHash != previous.manifestHash ||
                s.data['campaign_id'] != previous.data['campaign_id'] ||
                s.data['release_id'] != previous.data['release_id'] ||
                s.revision < previous.revision))) {
      throw const FormatException('The CQ session binding changed.');
    }
    return s;
  }

  Future<CqSession> read(String sid, {CqSession? previous}) async {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(sid)) {
      throw const FormatException(
        'A saved customer questionnaire session is required.',
      );
    }
    return _parse(
      await client.get('$basePath/sessions/$sid'),
      sid: sid,
      previous: previous,
    );
  }

  Future<CqSession> start(CqInvitation invitation, String locale) async {
    final s = _parse(
      await client.post('$basePath/sessions', {
        'campaign_id': invitation.campaignId,
        'manifest_hash': invitation.manifestHash,
        'locale': locale,
      }),
    );
    if (s.manifestHash != invitation.manifestHash ||
        s.data['campaign_id'] != invitation.campaignId ||
        s.data['release_id'] != invitation.releaseId)
      throw const FormatException('Invitation binding mismatch.');
    return s;
  }

  Future<CqSession> mutate(
    CqSession s,
    String action,
    Map<String, dynamic> body,
  ) async {
    const fields = {
      'consent': {'request_id', 'consented', 'consent_version'},
      'stimuli': {'kind'},
      'presentations': {'edit_slot_id'},
      'answers': {'request_id', 'display_id', 'slot_id', 'value'},
      'submit': {'request_id'},
      'pause': {'request_id'},
      'resume': {'request_id'},
      'rendered': {'display_id'},
    };
    if (!fields.containsKey(action) ||
        body.keys.any((k) => !fields[action]!.contains(k))) {
      throw ArgumentError(
        'Unsupported CQ operation or reserved version field.',
      );
    }
    return _parse(
      await client.post('$basePath/sessions/${s.id}/$action', {
        ...body,
        ...s.version,
      }),
      sid: s.id,
      previous: s,
    );
  }

  Future<CqSession> consent(CqSession s, String requestId) =>
      mutate(s, 'consent', {
        'request_id': requestId,
        'consented': true,
        'consent_version': s.manifest['consent_version'],
      });
  Future<CqSession> deliverStimulus(CqSession s, String kind) =>
      mutate(s, 'stimuli', {'kind': kind});
  Future<CqSession> present(CqSession s, {String? editSlotId}) => mutate(
    s,
    'presentations',
    {if (editSlotId != null) 'edit_slot_id': editSlotId},
  );
  Future<CqSession> answer(
    CqSession s, {
    required String requestId,
    required String displayId,
    required String slotId,
    required Object? value,
  }) => mutate(s, 'answers', {
    'request_id': requestId,
    'display_id': displayId,
    'slot_id': slotId,
    'value': value,
  });
  Future<CqSession> submit(CqSession s, String requestId) =>
      mutate(s, 'submit', {'request_id': requestId});
  Future<CqSession> pause(CqSession s, String requestId) =>
      mutate(s, 'pause', {'request_id': requestId});
  Future<CqSession> resume(CqSession s, String requestId) =>
      mutate(s, 'resume', {'request_id': requestId});
  Future<CqSession> rendered(CqSession s) =>
      mutate(s, 'rendered', {'display_id': s.presentation!['display_id']});
  Future<Map<String, dynamic>> withdraw(CqSession s, String requestId) async {
    final d = await client.post('$basePath/sessions/${s.id}/withdraw', {
      ...s.version,
      'request_id': requestId,
    });
    if (d['contract_version'] != 'cq-withdrawal/1' ||
        d['session_id'] != s.id ||
        d['status'] != 'WITHDRAWN') {
      throw const FormatException('Invalid withdrawal receipt.');
    }
    return d;
  }

  Future<Map<String, dynamic>> history(String sid) async {
    final d = await client.get('$basePath/sessions/$sid/history');
    if (d['contract_version'] != 'cq-history/1' || d['session_id'] != sid)
      throw const FormatException('Invalid CQ history.');
    return d;
  }
}
