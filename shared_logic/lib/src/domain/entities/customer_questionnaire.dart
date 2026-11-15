import 'dart:convert';
import 'package:crypto/crypto.dart';

// Matches the existing Python CUST03 digest (sorted keys, compact JSON,
// ensure_ascii). UTF-16 escaping preserves supplementary Unicode characters.
String cqDigest(Object? value) {
  String encode(Object? x) {
    if (x is Map) {
      final keys = x.keys.cast<String>().toList()..sort();
      return '{${keys.map((k) => '${encode(k)}:${encode(x[k])}').join(',')}}';
    }
    if (x is List) return '[${x.map(encode).join(',')}]';
    final json = jsonEncode(x);
    return String.fromCharCodes(
      json.codeUnits.expand(
        (c) => c >= 127
            ? ('\\u${c.toRadixString(16).padLeft(4, '0')}').codeUnits
            : [c],
      ),
    );
  }

  return sha256.convert(utf8.encode(encode(value))).toString();
}

dynamic _freeze(Object? value) => value is Map<String, dynamic>
    ? Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k, _freeze(v))),
      )
    : value is List
    ? List<dynamic>.unmodifiable(value.map(_freeze))
    : value;

/// Versioned CQ wire contract. Eligibility and next-question decisions belong
/// exclusively to FastAPI. Isolated test authority is rejected by default.
class CqSession {
  final Map<String, dynamic> data;
  CqSession._(this.data);
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  static void authority(Map<String, dynamic> data, bool allowIsolatedTesting) {
    final scope = data['execution_scope'];
    if (!(scope == 'PRODUCTION' &&
            data['production_fielding_authorized'] == true) &&
        !(scope == 'ISOLATED_TEST' &&
            allowIsolatedTesting &&
            data['production_fielding_authorized'] == false)) {
      throw const FormatException(
        'Customer participation is held pending authorization.',
      );
    }
  }

  factory CqSession.fromJson(
    Map<String, dynamic> source, {
    bool allowIsolatedTesting = false,
  }) {
    final d = _freeze(source) as Map<String, dynamic>;
    authority(d, allowIsolatedTesting);
    if (d['contract_version'] != 'cq-session/1' ||
        ![
          'session_id',
          'campaign_id',
          'release_id',
        ].every((k) => _uuid.hasMatch(d[k] as String? ?? '')) ||
        !_hash.hasMatch(d['manifest_hash'] as String? ?? '') ||
        d['revision'] is! int ||
        (d['revision'] as int) < 0 ||
        !['ACTIVE', 'SUBMITTED', 'WITHDRAWN'].contains(d['status']) ||
        d['consented'] is! bool ||
        d['can_submit'] is! bool ||
        !['EN', 'BM'].contains(d['locale'])) {
      throw const FormatException('Invalid CQ session binding.');
    }
    final m = d['manifest'] as Map<String, dynamic>;
    if (cqDigest(m) != d['manifest_hash'])
      throw const FormatException('Questionnaire manifest integrity failed.');
    if (m['contract_version'] != 'cq-manifest/1' ||
        m['lane'] != 'BASELINE' ||
        !['C0', 'C1'].contains(m['mode']) ||
        [
          'version',
          'bank_version',
          'policy_version',
          'consent_version',
        ].any((k) => m[k] is! String || (m[k] as String).isEmpty)) {
      throw const FormatException('Unsupported CQ manifest.');
    }
    final questions = (m['questions'] as List).cast<Map<String, dynamic>>();
    final policy = m['test_placement'];
    final extended = allowIsolatedTesting && d['execution_scope'] == 'ISOLATED_TEST' &&
        policy == 'isolated-last/1' && questions.length == 14 &&
        questions.last['id'] == 'Q14' &&
        _uuid.hasMatch(questions.last['version'] as String? ?? '') &&
        questions.last['required_for_answer'] == false &&
        questions.last['stimulus_text'] is String;
    if (policy != null && !extended || questions.length != 13 && !extended)
      throw const FormatException('Incomplete CQ instrument.');
    final slots = <String>{};
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i], id = 'Q${(i + 1).toString().padLeft(2, '0')}';
      if (q['id'] != id ||
          q['version'] is! String ||
          q['required_for_answer'] is! bool ||
          q['required_for_presentation'] is! bool ||
          (q['wording'] as Map)[d['locale']] is! String) {
        throw const FormatException('Invalid CQ question version.');
      }
      final codes = (q['codes'] as List).cast<String>();
      final labels = ((q['labels'] as Map)[d['locale']] as Map);
      if (codes.isEmpty ||
          codes.toSet().length != codes.length ||
          labels.length != codes.length ||
          codes.any((c) => labels[c] is! String)) {
        throw const FormatException('Invalid CQ codebook.');
      }
      if (extended && i == 13 &&
          (q['option_version'] != cqDigest([for (final code in codes) [code, labels[code]]]) ||
           (q['stimulus_text'] as String).trim().isEmpty ||
           q['type'] != 'single_select' || q['required_for_presentation'] != true)) {
        throw const FormatException('Invalid isolated question or option version.');
      }
      final features = (q['feature_ids'] as List).cast<String>();
      if (features.isEmpty) {
        slots.add(id);
      } else {
        slots.addAll(features.map((f) => '$id:$f'));
      }
    }
    final rows = (d['routing'] as List).cast<Map<String, dynamic>>();
    if (rows.length != slots.length ||
        rows.map((r) => r['slot_id']).toSet().length != slots.length ||
        rows.any(
          (r) =>
              !slots.contains(r['slot_id']) ||
              !['SHOWN', 'NOT_SHOWN'].contains(r['verdict']) ||
              ![
                'PENDING',
                'NOT_SHOWN',
                'SKIPPED',
                'REFUSED',
                'ANSWERED_SUBSTANTIVE',
                'ANSWERED_NON_SUBSTANTIVE',
              ].contains(r['state']) ||
              !_hash.hasMatch(r['context_digest'] as String? ?? ''),
        )) {
      throw const FormatException('Invalid server routing decision.');
    }
    final next = d['next_slot_id'];
    if (next != null &&
        !rows.any(
          (r) =>
              r['slot_id'] == next &&
              r['verdict'] == 'SHOWN' &&
              r['state'] == 'PENDING',
        )) {
      throw const FormatException('Invalid next presentation.');
    }
    final presentation = d['presentation'] as Map<String, dynamic>?;
    if (presentation != null &&
        (!slots.contains(presentation['slot_id']) ||
            !_uuid.hasMatch(presentation['display_id'] as String? ?? '') ||
            !rows.any(
              (r) =>
                  r['slot_id'] == presentation['slot_id'] &&
                  r['verdict'] == 'SHOWN' &&
                  r['context_digest'] == presentation['context_digest'],
            ) ||
            !questions.any(
              (q) =>
                  q['id'] == presentation['question_id'] &&
                  q['version'] == presentation['question_version'],
            ))) {
      throw const FormatException('Presentation does not match the manifest.');
    }
    final receipt = d['receipt'] as Map<String, dynamic>?;
    if (receipt != null) {
      final body = Map<String, dynamic>.from(receipt)..remove('receipt_hash');
      if (cqDigest(body) != receipt['receipt_hash'] ||
          receipt['execution_scope'] != d['execution_scope'] ||
          receipt['production_fielding_authorized'] !=
              d['production_fielding_authorized']) {
        throw const FormatException('Submission receipt integrity failed.');
      }
    }
    if (receipt != null &&
        (receipt['contract_version'] != 'cq-submission-receipt/1' ||
            receipt['session_id'] != d['session_id'] ||
            receipt['campaign_id'] != d['campaign_id'] ||
            receipt['manifest_hash'] != d['manifest_hash'] ||
            !_hash.hasMatch(receipt['receipt_hash'] as String? ?? ''))) {
      throw const FormatException('Receipt does not match the session.');
    }
    if (d['status'] == 'SUBMITTED' && receipt == null)
      throw const FormatException('Missing submission receipt.');
    if (d['status'] == 'SUBMITTED' &&
        (cqDigest(receipt!['effective_answers']) != cqDigest(rows) ||
            receipt['decision_hash'] != cqDigest(rows))) {
      throw const FormatException(
        'Receipt does not match the effective answer snapshot.',
      );
    }
    return CqSession._(d);
  }
  String get id => data['session_id'] as String;
  int get revision => data['revision'] as int;
  String get manifestHash => data['manifest_hash'] as String;
  Map<String, dynamic> get manifest => data['manifest'] as Map<String, dynamic>;
  Map<String, dynamic>? get presentation =>
      data['presentation'] as Map<String, dynamic>?;
  List<Map<String, dynamic>> get routing =>
      (data['routing'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> question(String slot) => (manifest['questions'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((q) => q['id'] == slot.split(':').first);
  Map<String, dynamic> get version => {
    'expected_revision': revision,
    'manifest_hash': manifestHash,
  };
}

class CqInvitation {
  final String campaignId, releaseId, manifestHash, title;
  final String? sessionId;
  const CqInvitation(
    this.campaignId,
    this.releaseId,
    this.manifestHash,
    this.title,
    this.sessionId,
  );
  factory CqInvitation.fromJson(
    Map<String, dynamic> d, {
    bool allowIsolatedTesting = false,
  }) {
    CqSession.authority(d, allowIsolatedTesting);
    if (!CqSession._uuid.hasMatch(d['campaign_id'] as String? ?? '') ||
        !CqSession._uuid.hasMatch(d['release_id'] as String? ?? '') ||
        !CqSession._hash.hasMatch(d['manifest_hash'] as String? ?? '') ||
        (d['session_id'] != null &&
            !CqSession._uuid.hasMatch(d['session_id'] as String))) {
      throw const FormatException('Invalid CQ invitation.');
    }
    return CqInvitation(
      d['campaign_id'] as String,
      d['release_id'] as String,
      d['manifest_hash'] as String,
      d['title'] as String,
      d['session_id'] as String?,
    );
  }
}
