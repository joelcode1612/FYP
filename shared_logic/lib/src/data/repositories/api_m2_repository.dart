import '../../core/network/api_client.dart';
import 'dart:math';
import 'dart:convert';
import 'package:crypto/crypto.dart';

String _sourceCanonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_sourceCanonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_sourceCanonical).join(',')}]';
  return jsonEncode(value);
}

/// Existing persisted BCB envelope. A verified hash is not a research grant.
Object? _freezeSource(Object? value) => value is Map<String, dynamic>
    ? Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k, _freezeSource(v))),
      )
    : value is List
    ? List<dynamic>.unmodifiable(value.map(_freezeSource))
    : value;

final class M2BusinessContext {
  final Map<String, dynamic> data;
  M2BusinessContext._(this.data);
  factory M2BusinessContext.parse(
    Map<String, dynamic> d,
    String assessmentId,
    String confirmationId,
    int revision,
  ) {
    final packet = d['packet'] as Map<String, dynamic>;
    final body = {...packet}..remove('packet_hash');
    final hash = sha256.convert(utf8.encode(_sourceCanonical(body))).toString();
    if (d['contract_version'] != 'persisted-business-context/1' ||
        d['assessment_id'] != assessmentId ||
        d['confirmation_id'] != confirmationId ||
        d['assessment_revision'] != revision ||
        d['lifecycle_status'] != 'PERSISTED' ||
        !ApiM2Repository._uuid.hasMatch(d['context_id'] as String? ?? '') ||
        d['replayed'] is! bool ||
        DateTime.tryParse(d['created_at'] as String? ?? '') == null ||
        d['qj_execution_authorized'] != false ||
        d['qg_execution_authorized'] != false ||
        packet['schema_version'] != 'business-context-package/1.0' ||
        packet['identity']['assessment_id'] != assessmentId ||
        packet['confirmation']['id'] != confirmationId ||
        packet['confirmation']['revision'] != revision ||
        packet['confirmation']['status'] != 'CURRENT_CONFIRMED' ||
        packet['packet_hash'] != hash ||
        packet['permissions'] is! Map ||
        packet['permissions']['qj_execution'] != false ||
        packet['permissions']['qg_execution'] != false ||
        (packet['permissions'] as Map).values.any((v) => v != false)) {
      throw const FormatException(
        'Business context source, digest or authority mismatch.',
      );
    }
    return M2BusinessContext._(_freezeSource(d) as Map<String, dynamic>);
  }
  String get id => data['context_id'] as String;
}

String m2RequestId() {
  final r = Random.secure(), b = List<int>.filled(16, 0);
  for (var i = 0; i < b.length; i++) {
    b[i] = r.nextInt(256);
  }
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

final class M2Draft {
  final Map<String, dynamic> data;
  M2Draft._(this.data);
  factory M2Draft.fromJson(Map<String, dynamic> d, {String? assessmentId}) {
    final a = d['assessment'] as Map<String, dynamic>;
    final instrument = d['instrument'] as Map<String, dynamic>;
    final items = (d['items'] as List).cast<Map<String, dynamic>>();
    if (a['id'] != assessmentId ||
        a['revision'] is! int ||
        a['instrument_id'] != instrument['id'] ||
        items.isEmpty ||
        items.any((q) => q['instrument_id'] != a['instrument_id']) ||
        items.map((q) => q['item_key']).toSet().length != items.length) {
      throw const FormatException(
        'The saved M2 instrument and assessment bindings could not be verified.',
      );
    }
    final byKey = {for (final q in items) q['item_key']: q};
    for (final e in (d['answers'] as Map<String, dynamic>).entries) {
      final answer = e.value as Map<String, dynamic>, q = byKey[e.key];
      if (q == null ||
          answer['assessment_id'] != a['id'] ||
          answer['item_version_id'] != q['id'] ||
          (answer['assessment_revision'] as int) > (a['revision'] as int)) {
        throw const FormatException(
          'Saved answer versions do not match this M2 assessment.',
        );
      }
    }
    return M2Draft._(d);
  }
  String get id => data['assessment']['id'] as String;
  int get revision => data['assessment']['revision'] as int;
  List<Map<String, dynamic>> get items =>
      (data['items'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> get answers => data['answers'] as Map<String, dynamic>;
}

/// Initial M2 entry uses persisted drafts. Confirmation is a separate later
/// action and is never a prerequisite for list/open/save/source projection.
final class ApiM2Repository {
  final ApiClient client;
  const ApiM2Repository(this.client);
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  void _id(String id) {
    if (!_uuid.hasMatch(id))
      throw const FormatException(
        'A persisted M2 assessment or instrument is required.',
      );
  }

  Future<List<Map<String, dynamic>>> _list(
    String resource,
    String contract,
  ) async {
    final d = await client.get(
      '/api/v1/m2/$resource',
      query: {'limit': '50', 'offset': '0'},
    );
    if (d['contract_version'] != contract)
      throw const FormatException('M2 catalogue is unavailable.');
    return (d['items'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> instruments() =>
      _list('instruments', 'm2-instrument-list/1');
  Future<List<Map<String, dynamic>>> assessments() =>
      _list('assessments', 'm2-assessment-list/1');
  Future<M2Draft> read(String id) async {
    _id(id);
    return M2Draft.fromJson(
      await client.get('/api/v1/m2/assessments/$id'),
      assessmentId: id,
    );
  }

  Future<M2Draft> create(String instrumentId) async {
    _id(instrumentId);
    final a = await client.post('/api/v1/m2/assessments', {
      'instrument_version_id': instrumentId,
    });
    final draft = await read(a['id'] as String);
    if (draft.data['instrument']['id'] != instrumentId)
      throw const FormatException('Instrument binding changed.');
    return draft;
  }

  Future<M2Draft> save(
    M2Draft draft,
    String key,
    String state,
    Object? value,
  ) async {
    if (!draft.items.any((q) => q['item_key'] == key))
      throw const FormatException('Item is outside this M2 version.');
    await client.put(
      '/api/v1/m2/assessments/${draft.id}/answers/${Uri.encodeComponent(key)}',
      {
        'expected_revision': draft.revision,
        'answer_state': state,
        'value': value,
      },
    );
    final result = await read(draft.id);
    if (result.data['instrument']['id'] != draft.data['instrument']['id'] ||
        result.revision <= draft.revision) {
      throw const FormatException('Saved M2 revision could not be verified.');
    }
    return result;
  }

  Future<Map<String, dynamic>> action(
    M2Draft d,
    String action,
    Map<String, dynamic> body,
  ) {
    if (body.containsKey('expected_revision') ||
        action.contains('..') ||
        action.startsWith('/')) {
      throw ArgumentError('Reserved source revision or invalid M2 action.');
    }
    return client.post('/api/v1/m2/assessments/${d.id}/$action', {
      ...body,
      'expected_revision': d.revision,
    });
  }

  Future<Map<String, dynamic>> evaluate(M2Draft d) async {
    final result = await action(d, 'bdj/evaluate', {});
    if (result['assessment_id'] != d.id || result['revision'] != d.revision) {
      throw const FormatException('Stale BDJ source.');
    }
    return result;
  }

  Future<Map<String, dynamic>> decide(
    M2Draft d,
    String findingId,
    String decision,
    String requestId,
  ) async {
    _id(findingId);
    _id(requestId);
    if (!['KEEP_ORIGINAL', 'REVIEW_LATER'].contains(decision))
      throw ArgumentError('Invalid finding decision.');
    final result = await action(d, 'findings/$findingId/decisions', {
      'decision': decision,
      'request_id': requestId,
    });
    final event = result['event'] as Map<String, dynamic>;
    if (event['assessment_id'] != d.id ||
        event['assessment_revision'] != d.revision ||
        event['finding_id'] != findingId ||
        event['decision'] != decision ||
        event['request_id'] != requestId ||
        result['answer_changed'] != false ||
        result['finding_resolved'] != false) {
      throw const FormatException('Finding decision source mismatch.');
    }
    return result;
  }

  Future<Map<String, dynamic>> review(M2Draft d) async {
    final result = await action(d, 'review', {});
    if (result['assessment_id'] != d.id ||
        result['assessment_revision'] != d.revision ||
        !_uuid.hasMatch(result['id'] as String? ?? ''))
      throw const FormatException('Review source mismatch.');
    return result;
  }

  Future<Map<String, dynamic>> confirm(
    M2Draft d,
    List<String> findingIds,
  ) async {
    final result = await action(d, 'confirm', {
      'acknowledged_issue_ids': findingIds,
    });
    if (result['assessment_id'] != d.id ||
        result['assessment_revision'] != d.revision ||
        !_uuid.hasMatch(result['id'] as String? ?? '')) {
      throw const FormatException('Confirmation source mismatch.');
    }
    final snapshot = result['snapshot_json'] as Map<String, dynamic>;
    if (snapshot['assessment_id'] != d.id ||
        snapshot['assessment_revision'] != d.revision ||
        snapshot['qj_handoff_authorized'] != false ||
        result['snapshot_digest'] !=
            sha256
                .convert(utf8.encode(_sourceCanonical(snapshot)))
                .toString()) {
      throw const FormatException(
        'Confirmation snapshot fingerprint mismatch.',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> confirmUncertainty(
    String confirmationId,
    String exactText,
  ) async {
    _id(confirmationId);
    final result = await client.post(
      '/api/v1/m2/confirmations/$confirmationId/uncertainty',
      {'exact_text': exactText},
    );
    if (result['confirmation_id'] != confirmationId ||
        !_uuid.hasMatch(result['id'] as String? ?? '') ||
        result['exact_text'] != exactText.trim())
      throw const FormatException('Uncertainty confirmation mismatch.');
    return result;
  }

  Future<M2BusinessContext> buildContext(
    String assessmentId,
    String confirmationId,
    int revision,
  ) async {
    _id(assessmentId);
    _id(confirmationId);
    return M2BusinessContext.parse(
      await client.post(
        '/api/v1/m2/assessments/$assessmentId/business-context',
        {'confirmation_id': confirmationId, 'expected_revision': revision},
      ),
      assessmentId,
      confirmationId,
      revision,
    );
  }

  Future<M2BusinessContext> readContext(
    String assessmentId,
    String confirmationId,
    int revision,
    String contextId,
  ) async {
    _id(assessmentId);
    _id(confirmationId);
    _id(contextId);
    final result = M2BusinessContext.parse(
      await client.get(
        '/api/v1/m2/assessments/$assessmentId/business-contexts/$contextId',
      ),
      assessmentId,
      confirmationId,
      revision,
    );
    if (result.id != contextId)
      throw const FormatException('Context identity changed.');
    return result;
  }

  Future<Map<String, dynamic>> contextStatus(
    String assessmentId,
    String confirmationId,
    int revision,
  ) async {
    _id(assessmentId);
    _id(confirmationId);
    final d = await client.get(
      '/api/v1/m2/assessments/$assessmentId/confirmations/$confirmationId/business-context-status',
    );
    if (d['assessment_id'] != assessmentId ||
        d['confirmation_id'] != confirmationId ||
        d['assessment_revision'] != revision ||
        d['source_is_current'] is! bool ||
        !['PENDING', 'HELD', 'FAILED', 'PERSISTED'].contains(d['status']) ||
        d['attempt_count'] is! int ||
        d['attempt_count'] < 0) {
      throw const FormatException('Business context status source mismatch.');
    }
    return d;
  }

  Future<Map<String, dynamic>> worksheet(M2Draft d) async {
    final result = await client.get(
      '/api/v1/m2/assessments/${d.id}/business-understanding',
    );
    if (result['assessment_id'] != d.id || result['revision'] != d.revision) {
      throw const FormatException('Stale BDJ source.');
    }
    return result;
  }

  Future<Map<String, dynamic>> source(M2Draft d) => client.get(
    '/api/v1/m2/assessments/${d.id}/source-projection',
    query: {'expected_revision': '${d.revision}'},
  );
  Future<Map<String, dynamic>> activity(String id) async {
    _id(id);
    final d = await client.get('/api/v1/m2/assessments/$id/activity');
    if (d['contract_version'] != 'm2-activity/1' ||
        d['assessment_id'] != id ||
        d['assessment_revision'] is! int ||
        d['events'] is! List ||
        d['truncated'] is! bool) {
      throw const FormatException('Saved M2 activity could not be verified.');
    }
    final seen = <String>{};
    for (final raw in d['events'] as List) {
      final e = raw as Map<String, dynamic>;
      final date = DateTime.tryParse(e['occurred_at'] as String? ?? '');
      final key = '${e['kind']}:${e['event_id']}';
      if (e['event_id'] is! String ||
          !_uuid.hasMatch(e['event_id']) ||
          e['kind'] is! String ||
          !seen.add(key) ||
          date == null ||
          !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(e['occurred_at']) ||
          e['assessment_revision'] is! int ||
          e['assessment_revision'] < 0 ||
          e['assessment_revision'] > d['assessment_revision'] ||
          (e['actor_id'] != null &&
              (e['actor_id'] is! String || !_uuid.hasMatch(e['actor_id']))) ||
          (e['source_id'] != null &&
              (e['source_id'] is! String || !_uuid.hasMatch(e['source_id'])))) {
        throw const FormatException(
          'Saved activity source versions could not be verified.',
        );
      }
    }
    if (d['history_extension'] != null) {
      if (d['history_extension'] != 'workflow-history-metadata/1' ||
          d['bcb_history_available'] is! bool ||
          d['bcb_statuses'] is! List ||
          d['bcb_statuses_truncated'] is! bool ||
          d['authorization_decisions_included'] != false) {
        throw const FormatException(
          'Workflow history sources could not be verified.',
        );
      }
      for (final raw in d['bcb_statuses'] as List) {
        final b = raw as Map<String, dynamic>;
        if (!_uuid.hasMatch(b['confirmation_id'] as String? ?? '') ||
            b['assessment_revision'] is! int ||
            b['assessment_revision'] < 0 ||
            b['assessment_revision'] > d['assessment_revision'] ||
            !['PENDING', 'PERSISTED', 'HELD', 'FAILED'].contains(b['status']) ||
            b['source_is_current'] is! bool ||
            b['attempt_count'] is! int ||
            b['attempt_count'] < 0 ||
            (b['context_id'] != null &&
                !_uuid.hasMatch(b['context_id'] as String? ?? ''))) {
          throw const FormatException(
            'BCB snapshot source could not be verified.',
          );
        }
      }
    }
    return d;
  }
}
