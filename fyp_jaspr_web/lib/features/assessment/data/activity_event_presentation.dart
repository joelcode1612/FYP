/// Presentation mapping for persisted Activity History events.
///
/// Kept out of the widget so the mapping can be tested without mounting the
/// authenticated panel, and so "what does this record say" is one reviewable
/// function rather than logic spread through a build method.
///
/// Two rules govern everything here:
///
///  * an identifier is not a title, and a version is not a reason — the
///    persisted `kind`, `rule_id`, `evaluator_version` and `builder_version`
///    each get the label that matches what they actually are; and
///  * a field the record does not store stays absent. Nothing is defaulted to
///    a success, a completion, or a friendly value it has not earned.
library;

class ActivityEventPresentation {
  const ActivityEventPresentation({
    required this.title,
    required this.summary,
    this.engineVersion,
  });

  final String title;
  final String summary;

  /// The engine/ruleset/builder version, when the record carries one.
  /// Null means the source stores no version for this event kind.
  final String? engineVersion;
}

/// Human titles for the persisted event kinds. An unmapped kind keeps its raw
/// code rather than borrowing a label it has not earned.
const Map<String, String> _titles = {
  'ASSESSMENT_CREATED': 'Assessment created',
  'ANSWER_SAVED': 'Answer saved',
  'BDJ_EVALUATED': 'Candidate rule evaluation',
  'CANDIDATE_FINDING_RECORDED': 'Candidate finding recorded',
  'REVIEW_RECORDED': 'Review recorded',
  'CONTEXT_CONFIRMED': 'Business context confirmed',
  'UNCERTAINTY_CONFIRMED': 'Uncertainty declared',
  'CLARIFICATION_RECORDED': 'Finding decision recorded',
  'CONTEXT_PERSISTED': 'Business context persisted',
};

String? _versionOf(Map<String, dynamic> event) {
  for (final key in const [
    'evaluator_version',
    'rule_version',
    'builder_version',
  ]) {
    final value = event[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

ActivityEventPresentation presentActivityEvent(Map<String, dynamic> event) {
  final kind = event['kind'] as String? ?? '';
  final revision = event['assessment_revision'];
  final status = event['status'];
  final version = _versionOf(event);

  final summary = switch (kind) {
    'ASSESSMENT_CREATED' =>
      'Assessment created. The creating actor is not separately recorded.',
    'ANSWER_SAVED' =>
      event['item_key'] is String && (event['item_key'] as String).isNotEmpty
          ? 'Answer for ${event['item_key']} recorded at revision $revision.'
          : 'Answer recorded at revision $revision.',
    'BDJ_EVALUATED' => version == null
        ? 'Deterministic candidate-rule evaluation recorded at revision '
              '$revision.'
        : 'Deterministic candidate-rule evaluation by $version recorded at '
              'revision $revision.',
    'CANDIDATE_FINDING_RECORDED' =>
      'Candidate finding ${event['rule_id'] ?? 'unidentified rule'}'
          '${version == null ? '' : ' ($version)'} recorded at revision '
          '$revision'
          '${status == null ? '' : ' with review state $status'}.',
    'REVIEW_RECORDED' => 'Review recorded at revision $revision.',
    'CONTEXT_CONFIRMED' => _confirmationSummary(event, revision),
    'UNCERTAINTY_CONFIRMED' =>
      'Separate entrepreneur uncertainty declaration recorded at revision '
          '$revision.',
    'CLARIFICATION_RECORDED' =>
      'Decision${status == null ? '' : ' $status'} recorded at revision '
          '$revision'
          '${event['source_id'] == null ? '' : ' against finding ${event['source_id']}'}.',
    'CONTEXT_PERSISTED' =>
      'Business context${status == null ? '' : ' $status'}'
          '${version == null ? '' : ' from builder $version'} at revision '
          '$revision.',
    _ => 'Persisted ${event['module'] ?? 'M2'} metadata at revision $revision.',
  };

  return ActivityEventPresentation(
    title: _titles[kind] ?? kind,
    summary: summary,
    engineVersion: version,
  );
}

String _confirmationSummary(Map<String, dynamic> event, Object? revision) {
  final digest = event['snapshot_digest'];
  if (digest is! String || digest.isEmpty) {
    return 'Confirmation snapshot recorded at revision $revision.';
  }
  final shown = digest.length >= 12 ? '${digest.substring(0, 12)}…' : digest;
  return 'Confirmation snapshot recorded at revision $revision; digest $shown';
}
