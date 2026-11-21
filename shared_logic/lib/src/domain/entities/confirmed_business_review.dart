/// Read-only projection of an explicitly selected persisted M2 confirmation.
/// Source integrity and currentness are checked by the server on every read.
final class ConfirmedBusinessReview {
  final String assessmentId, confirmationId, snapshotDigest, ruleVersion;
  final int revision;
  final List<ConfirmedReviewAnswer> answers;
  final List<ConfirmedReviewFinding> findings;
  final List<ConfirmedReviewEvent> activity;
  final bool activityTruncated;

  const ConfirmedBusinessReview._(
    this.assessmentId,
    this.confirmationId,
    this.snapshotDigest,
    this.ruleVersion,
    this.revision,
    this.answers,
    this.findings,
    this.activity,
    this.activityTruncated,
  );

  factory ConfirmedBusinessReview.fromJson(Map<String, dynamic> json) {
    if (json['contract_version'] != 'project1-confirmed-review/1' ||
        json['source_status'] != 'CURRENT_CONFIRMED_SOURCE' ||
        json['trust_class'] != 'T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION' ||
        json['evaluation_state'] != 'EVALUATED_CANDIDATE' ||
        json['activity_scope'] != 'M2_RECORDS_THROUGH_CONFIRMED_REVISION' ||
        json['fielding_authorized'] != false ||
        json['qj_handoff_authorized'] != false ||
        json['report_release_authorized'] != false ||
        json['activity_truncated'] is! bool) {
      throw const FormatException('Unsupported confirmed review contract.');
    }
    final revision = _revision(json, 'assessment_revision');
    final digest = _text(json, 'snapshot_digest');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid confirmation digest.');
    }
    final answers = _records(
      json,
      'answers',
    ).map(ConfirmedReviewAnswer.fromJson).toList();
    final refs = answers.map((a) => a.answerId).toSet();
    if (refs.length != answers.length ||
        answers.map((a) => a.itemKey).toSet().length != answers.length) {
      throw const FormatException('Duplicate review source.');
    }
    final findings = _records(
      json,
      'findings',
    ).map(ConfirmedReviewFinding.fromJson).toList();
    if (findings.map((f) => f.id).toSet().length != findings.length ||
        findings.any(
          (f) => f.sourceAnswerIds.any((id) => !refs.contains(id)),
        )) {
      throw const FormatException('Unbound review finding.');
    }
    final activity = _records(
      json,
      'activity',
    ).map(ConfirmedReviewEvent.fromJson).toList();
    if (activity.length > 50 ||
        activity.map((e) => e.id).toSet().length != activity.length ||
        activity.any((e) => e.revision > revision)) {
      throw const FormatException('Invalid review activity scope.');
    }
    return ConfirmedBusinessReview._(
      _uuid(json, 'assessment_id'),
      _uuid(json, 'confirmation_id'),
      digest,
      _text(json, 'rule_version'),
      revision,
      List.unmodifiable(answers),
      List.unmodifiable(findings),
      List.unmodifiable(activity),
      json['activity_truncated'] as bool,
    );
  }
}

final class ConfirmedReviewAnswer {
  final String itemKey, question, state, answerId, itemVersionId;
  final Object? value;
  const ConfirmedReviewAnswer._(
    this.itemKey,
    this.question,
    this.state,
    this.answerId,
    this.itemVersionId,
    this.value,
  );
  factory ConfirmedReviewAnswer.fromJson(Map<String, dynamic> json) {
    final value = json['value'];
    if (value != null &&
        value is! String &&
        !(value is List && value.every((v) => v is String))) {
      throw const FormatException('Invalid declaration value.');
    }
    return ConfirmedReviewAnswer._(
      _text(json, 'item_key'),
      _text(json, 'question'),
      _text(json, 'answer_state'),
      _uuid(json, 'source_answer_revision_id'),
      _uuid(json, 'source_item_version_id'),
      value is List ? List<String>.unmodifiable(value.cast<String>()) : value,
    );
  }
  String get displayValue =>
      value is List ? (value as List).join(', ') : value?.toString() ?? state;
}

final class ConfirmedReviewFinding {
  final String id,
      ruleId,
      issueType,
      explanation,
      notProven,
      nextAction,
      reviewState;
  final List<String> sourceAnswerIds;
  const ConfirmedReviewFinding._(
    this.id,
    this.ruleId,
    this.issueType,
    this.explanation,
    this.notProven,
    this.nextAction,
    this.reviewState,
    this.sourceAnswerIds,
  );
  factory ConfirmedReviewFinding.fromJson(Map<String, dynamic> json) {
    final refs = json['source_answer_ids'];
    if (refs is! List ||
        refs.isEmpty ||
        refs.any((v) => v is! String || !_isUuid(v)) ||
        refs.toSet().length != refs.length) {
      throw const FormatException('Missing review source references.');
    }
    return ConfirmedReviewFinding._(
      _uuid(json, 'id'),
      _text(json, 'rule_id'),
      _text(json, 'issue_type'),
      _text(json, 'explanation'),
      _text(json, 'not_proven'),
      _text(json, 'next_action'),
      _text(json, 'review_state'),
      List<String>.unmodifiable(refs.cast<String>()),
    );
  }
}

final class ConfirmedReviewEvent {
  final String id, kind;
  final int revision;
  final DateTime occurredAt;
  final String? actorId;
  const ConfirmedReviewEvent._(
    this.id,
    this.kind,
    this.revision,
    this.occurredAt,
    this.actorId,
  );
  factory ConfirmedReviewEvent.fromJson(Map<String, dynamic> json) {
    final kind = _text(json, 'kind');
    if (!const {
      'ANSWER_SAVED',
      'BDJ_EVALUATED',
      'REVIEW_RECORDED',
      'CONTEXT_CONFIRMED',
      'CLARIFICATION_RECORDED',
    }.contains(kind)) {
      throw const FormatException('Unsupported activity kind.');
    }
    final at = DateTime.tryParse(_text(json, 'occurred_at'));
    if (at == null || !at.isUtc)
      throw const FormatException('UTC activity timestamp required.');
    return ConfirmedReviewEvent._(
      _uuid(json, 'event_id'),
      kind,
      _revision(json, 'assessment_revision'),
      at,
      json['actor_id'] == null ? null : _uuid(json, 'actor_id'),
    );
  }
}

String _text(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty)
    throw FormatException('Missing $key.');
  return value;
}

bool _isUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
).hasMatch(value);
String _uuid(Map<String, dynamic> json, String key) {
  final value = _text(json, key);
  if (!_isUuid(value)) throw FormatException('Invalid $key.');
  return value;
}

int _revision(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key.');
  return value;
}

List<Map<String, dynamic>> _records(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List || value.any((v) => v is! Map<String, dynamic>))
    throw FormatException('Missing $key.');
  return value.cast<Map<String, dynamic>>();
}
