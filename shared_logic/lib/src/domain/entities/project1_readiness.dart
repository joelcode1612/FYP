/// Read-only server availability. This contract cannot carry questions,
/// responses, measurements, reports or client-supplied authority.
final class Project1HeldArtifact {
  final String code;
  final String message;
  const Project1HeldArtifact({required this.code, required this.message});

  factory Project1HeldArtifact.fromJson(Map<String, dynamic> json) {
    if (json['state'] != 'held' || json['code'] is! String ||
        (json['code'] as String).isEmpty || json['message'] is! String ||
        (json['message'] as String).isEmpty) {
      throw const FormatException('Unsupported Project1 availability.');
    }
    return Project1HeldArtifact(
      code: json['code'] as String, message: json['message'] as String,
    );
  }
}

final class Project1Readiness {
  final String? assessmentId;
  final String? propertyId;
  final Project1HeldArtifact review;
  final Project1HeldArtifact questionnaire;
  final Project1HeldArtifact report;
  final Project1HeldArtifact activity;

  const Project1Readiness({
    required this.assessmentId, required this.propertyId,
    required this.review, required this.questionnaire,
    required this.report, required this.activity,
  });

  factory Project1Readiness.fromJson(Map<String, dynamic> json) {
    if (json['contract_version'] != 'project1-readiness/1' ||
        json['fielding_authorized'] != false ||
        json['report_release_authorized'] != false ||
        (json['assessment_id'] != null && json['assessment_id'] is! String) ||
        (json['property_id'] != null && json['property_id'] is! String)) {
      throw const FormatException('Unsupported Project1 contract.');
    }
    Project1HeldArtifact artifact(String key) {
      final value = json[key];
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Missing Project1 availability.');
      }
      return Project1HeldArtifact.fromJson(value);
    }
    return Project1Readiness(
      assessmentId: json['assessment_id'] as String?,
      propertyId: json['property_id'] as String?,
      review: artifact('review'), questionnaire: artifact('questionnaire'),
      report: artifact('report'), activity: artifact('activity'),
    );
  }
}
