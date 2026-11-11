import 'assessment.dart';

enum DraftStatus { inProgress, paused, previewCompleted }

class AssessmentDraft {
  final String id;
  final DraftStatus status;
  final int revision;
  final String bankVersion;
  final String routingVersion;
  final String contextVersion;
  final String conceptVersion;
  final String language; // en or bm
  final bool consentGiven; // synthetic UI preview only
  final String? currentQuestionId;
  final Map<String, String> answerCodes;
  final DateTime updatedAt;

  const AssessmentDraft({
    required this.id,
    required this.status,
    required this.revision,
    required this.bankVersion,
    required this.routingVersion,
    required this.contextVersion,
    required this.conceptVersion,
    required this.language,
    required this.consentGiven,
    required this.currentQuestionId,
    required this.answerCodes,
    required this.updatedAt,
  });

  factory AssessmentDraft.start(AssessmentOffer offer) => AssessmentDraft(
    id: offer.id,
    status: DraftStatus.inProgress,
    revision: 0,
    bankVersion: offer.bankVersion,
    routingVersion: offer.routingVersion,
    contextVersion: offer.contextVersion,
    conceptVersion: offer.conceptVersion,
    language: 'en',
    consentGiven: false,
    currentQuestionId: null,
    answerCodes: const {},
    updatedAt: DateTime.now().toUtc(),
  );

  AssessmentDraft withChanges({
    DraftStatus? status,
    String? language,
    bool? consentGiven,
    String? currentQuestionId,
    bool clearCursor = false,
    Map<String, String>? answerCodes,
  }) => AssessmentDraft(
    id: id,
    status: status ?? this.status,
    revision: revision + 1,
    bankVersion: bankVersion,
    routingVersion: routingVersion,
    contextVersion: contextVersion,
    conceptVersion: conceptVersion,
    language: language ?? this.language,
    consentGiven: consentGiven ?? this.consentGiven,
    currentQuestionId: clearCursor
        ? null
        : currentQuestionId ?? this.currentQuestionId,
    answerCodes: Map.unmodifiable(answerCodes ?? this.answerCodes),
    updatedAt: DateTime.now().toUtc(),
  );

  bool matches(AssessmentOffer offer) =>
      bankVersion == offer.bankVersion &&
      routingVersion == offer.routingVersion &&
      contextVersion == offer.contextVersion &&
      conceptVersion == offer.conceptVersion;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'status': status.name,
    'revision': revision,
    'bank_version': bankVersion,
    'routing_version': routingVersion,
    'context_version': contextVersion,
    'concept_version': conceptVersion,
    'language': language,
    'consent_given': consentGiven,
    'current_question_id': currentQuestionId,
    'answers': answerCodes,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory AssessmentDraft.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != 1) {
      throw const FormatException(
        'Unsupported saved-draft schema; manual recovery required.',
      );
    }
    return AssessmentDraft(
      id: json['id'] as String,
      status: DraftStatus.values.byName(json['status'] as String),
      revision: json['revision'] as int,
      bankVersion: json['bank_version'] as String,
      routingVersion: json['routing_version'] as String,
      contextVersion: json['context_version'] as String,
      conceptVersion: json['concept_version'] as String,
      language: json['language'] as String,
      consentGiven: json['consent_given'] as bool,
      currentQuestionId: json['current_question_id'] as String?,
      answerCodes: Map<String, String>.from(json['answers'] as Map),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}
