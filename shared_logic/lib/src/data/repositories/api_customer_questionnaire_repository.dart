import '../../core/network/api_client.dart';
import '../../domain/entities/customer_questionnaire.dart';

class ApiCustomerQuestionnaireRepository {
  final ApiClient client;
  final bool allowIsolatedTesting;
  const ApiCustomerQuestionnaireRepository(
    this.client, {
    this.allowIsolatedTesting = false,
  });
  Future<({String state, List<CqInvitation> invitations})> invitations() async {
    final d = await client.get('/api/v1/cq/invitations');
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
      await client.get('/api/v1/cq/sessions/$sid'),
      sid: sid,
      previous: previous,
    );
  }

  Future<CqSession> start(CqInvitation invitation, String locale) async {
    final s = _parse(
      await client.post('/api/v1/cq/sessions', {
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
    };
    if (!fields.containsKey(action) ||
        body.keys.any((k) => !fields[action]!.contains(k))) {
      throw ArgumentError(
        'Unsupported CQ operation or reserved version field.',
      );
    }
    return _parse(
      await client.post('/api/v1/cq/sessions/${s.id}/$action', {
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
  Future<Map<String, dynamic>> withdraw(CqSession s, String requestId) async {
    final d = await client.post('/api/v1/cq/sessions/${s.id}/withdraw', {
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
    final d = await client.get('/api/v1/cq/sessions/$sid/history');
    if (d['contract_version'] != 'cq-history/1' || d['session_id'] != sid)
      throw const FormatException('Invalid CQ history.');
    return d;
  }
}
