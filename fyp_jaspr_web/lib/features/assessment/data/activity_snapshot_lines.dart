/// Presentation of the Activity History *current state* section.
///
/// This turns the backend's `publication` and `measurement` projections into
/// display lines. It is deliberately pure and free of Flutter/jaspr imports so
/// the wording can be asserted directly against fixture payloads -- the
/// distinctions these lines encode (computed vs accepted, preview vs customer
/// evidence, count present vs not reported) are the whole point of the section
/// and must not be verifiable only by mounting a browser.
///
/// Two rules hold throughout:
///
/// * An absent value is reported as *not reported*, never as zero. A service
///   that omits `session_count` has not told us there were no responses.
/// * Nothing here reconstructs a measurement value. The backend does not send
///   one, and these lines must not imply it did.
library;

/// ISO timestamp → `YYYY-MM-DD` in local time, for the response window only.
/// The stored ISO value is not rewritten anywhere else on the page.
String shortDate(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// Aggregate response size for a published questionnaire.
///
/// A receipt mismatch is reported as a mismatch rather than reconciled:
/// duplicate submissions are expected to be idempotent, so if the two numbers
/// disagree the honest statement is that they disagree.
String responseLine(Map p) {
  final sessions = p['session_count'];
  if (sessions is! int) {
    return 'Response counts: not reported by this service version. This is '
        'not evidence that no responses exist.';
  }
  final submitted = p['submitted_session_count'];
  final open = p['open_session_count'];
  final withdrawn = p['withdrawn_session_count'];
  final receipts = p['receipt_count'];
  final matches = p['receipts_match_submitted_sessions'] == true;
  final first = p['first_session_at'];
  final last = p['last_session_at'];
  final window = (first is String && last is String)
      ? ' · sessions recorded ${shortDate(first)} to ${shortDate(last)}'
      : '';
  final receiptText = receipts is! int
      ? 'receipt count not reported'
      : matches
      ? '$receipts submission ${receipts == 1 ? 'receipt' : 'receipts'} '
            '(matches submitted sessions)'
      : '$receipts submission ${receipts == 1 ? 'receipt' : 'receipts'} — '
            'does not match $submitted submitted sessions; duplicate '
            'submission handling is not confirmed';
  return 'Responses: $sessions ${sessions == 1 ? 'session' : 'sessions'} · '
      '${submitted is int ? submitted : '?'} submitted · '
      '${open is int ? open : '?'} open · '
      '${withdrawn is int ? withdrawn : '?'} withdrawn · '
      '$receiptText$window.';
}

/// Publication state lines from `activity['publication']`.
///
/// The three failure modes stay distinct: an unreadable source is
/// NOT_VERIFIED, not "not published"; a hash mismatch means the state cannot be
/// asserted; and a release built for an earlier revision is reported as
/// historical rather than current.
List<String> publicationLines(Map? activity) {
  final p = activity?['publication'];
  if (p is! Map) {
    return [
      'Questionnaire publication: NOT_VERIFIED — publication metadata could '
          'not be read. This is not evidence that no questionnaire exists.',
    ];
  }
  final state = p['state'] as String? ?? 'UNKNOWN';
  final detail = p['detail'] as String?;
  if (state == 'NOT_PUBLISHED') {
    return [
      'Questionnaire publication: not published. No campaign is owned by '
          'this actor for this assessment.',
    ];
  }
  if (state != 'PUBLISHED') {
    return [
      'Questionnaire publication: $state'
          '${detail == null || detail.isEmpty ? '' : ' — $detail'}. '
          'Publication state cannot be asserted.',
    ];
  }
  final publishedAt = p['campaign_created_at'];
  final bank = p['bank_version'];
  final questions = p['question_count'];
  final authorized = p['authorized_question_count'];
  final releaseId = p['release_id'];
  final campaignId = p['campaign_id'];
  final sourceClass = p['source_class'];
  final builtFor = p['published_at_revision'];
  final current = p['current_revision'];
  final fielding = p['fielding_enabled'] == true ? 'enabled' : 'disabled';
  final currentness = builtFor == current
      ? 'built for the current revision $builtFor'
      : 'built for revision $builtFor; the assessment is now at $current, so '
            'this release is historical';
  return [
    'Questionnaire published $publishedAt · bank $bank · $questions '
        'questions · $authorized authorized for this assessment · release '
        '$releaseId · campaign $campaignId · source $sourceClass · '
        '$currentness · fielding $fielding.',
    responseLine(p),
    'Publication and response figures are assessment-level only: no '
        'respondent identity, answer, session record or receipt body is '
        'included.',
  ];
}

/// Measurement metadata lines from `activity['measurement']`.
///
/// Three separate facts are kept separate, because collapsing them is how
/// "a number was computed" becomes "the finding is accepted": the execution
/// status, the finding admission status, and the evidence class.
List<String> measurementLines(Map? activity) {
  final m = activity?['measurement'];
  if (m is! Map) {
    return [
      'EE-01 measurement: NOT_VERIFIED — measurement metadata could not be '
          'read. This is not evidence that no measurement was taken.',
    ];
  }
  final state = m['state'];
  if (state == 'NO_CAMPAIGN') {
    return [
      'EE-01 measurement: none bound. No questionnaire campaign exists for '
          'this assessment, so no measurement can reference one. This is a '
          'publication fact, not a measurement failure.',
    ];
  }
  if (state != 'MEASURED') {
    return [
      'EE-01 measurement: $state. '
          '${m['detail'] ?? 'No measurement snapshot is recorded yet.'}',
    ];
  }
  final lines = <String>[];
  final summary = m['summary'];
  if (summary is Map) {
    final count = summary['snapshot_count'];
    final slots = summary['slots'];
    final customer = summary['customer_research_snapshot_count'];
    final preview = summary['by_evidence_class'] is Map
        ? (summary['by_evidence_class'] as Map)['DEVELOPER_PREVIEW']
        : null;
    lines.add(
      'EE-01 measurements: ${count ?? '?'} snapshot(s) over '
      '${summary['slot_count'] ?? '?'} slot(s) '
      '(${slots is List ? slots.join(', ') : 'slots not reported'}) · '
      '$customer from customer research evidence · '
      '${preview ?? 0} from developer-preview evidence. '
      'No measurement value is shown.',
    );
  }
  for (final item in m['measurements'] as List? ?? const []) {
    if (item is! Map) continue;
    final version = item['snapshot_version'];
    final fingerprint = version is Map ? version['fingerprint'] as String? : null;
    final gates = item['gates'] as List? ?? const [];
    lines.add(
      'Measurement ${item['slot_id']} · executed ${item['computation']} · '
      'outcome ${item['measurement_status']} · '
      'evidence ${item['evidence_class']} · cutoff ${item['cutoff']} · '
      'snapshot '
      '${fingerprint == null ? 'not recorded' : '${fingerprint.substring(0, 12)}…'} · '
      'scientific acceptance ${item['scientific_acceptance']} · '
      'report authorization ${item['report_authorization']} · '
      'finding admission ${item['admission_status']} '
      '(${item['finding_count']} finding(s) released)'
      '${gates.isEmpty ? '' : ' · gates: ${gates.join(', ')}'}.',
    );
  }
  return lines;
}
