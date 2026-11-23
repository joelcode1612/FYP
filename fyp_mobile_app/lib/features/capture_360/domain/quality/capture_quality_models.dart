import 'dart:convert';

/// Verdict for one saved photograph after quality verification.
///
/// Three honest outcomes, never an automatic action:
///
/// * [accepted] — every enabled check passed within its thresholds.
/// * [warning]  — the photograph is *usable* but at least one evidence-based
///   quality check sits outside its comfortable range (soft blur, strong
///   shadows, low feature overlap). The photograph stays saved and uploaded;
///   only the user decides whether to retake it.
/// * [invalid]  — the capture is genuinely unusable as an image: the bytes do
///   not decode as a JPEG or the geometry is broken. The file is still never
///   deleted; the finding tells the user a retake is required.
enum QualityVerdict {
  accepted('accepted'),
  warning('warning'),
  invalid('invalid');

  const QualityVerdict(this.wireName);

  /// The value stored inside `session.json`'s per-frame `quality_json` blob.
  final String wireName;

  static QualityVerdict fromWire(String? value) {
    for (final verdict in QualityVerdict.values) {
      if (verdict.wireName == value) return verdict;
    }
    return QualityVerdict.accepted;
  }
}

/// How strong one finding is.
///
/// [critical] findings produce an [QualityVerdict.invalid] verdict; [warning]
/// findings produce [QualityVerdict.warning]; [info] findings are recorded
/// evidence that never changes the verdict (e.g. "this scene is a plain
/// wall, sharpness cannot be judged").
enum QualitySeverity { info, warning, critical }

/// The individual checks the analyzer runs. The wire name is stable — it is
/// what the backend and the session file key findings on — so adding a new
/// check never renames an old one.
enum QualityCheckId {
  jpegIntegrity('jpeg_integrity'),
  dimensions('dimensions'),
  resolution('resolution'),
  sharpness('sharpness'),
  blur('blur'),
  exposure('exposure'),
  orientationMetadata('orientation_metadata'),
  neighborOverlap('neighbor_overlap');

  const QualityCheckId(this.wireName);

  final String wireName;

  static QualityCheckId? fromWire(String? value) {
    for (final id in QualityCheckId.values) {
      if (id.wireName == value) return id;
    }
    return null;
  }
}

/// One measured result of one check, with the evidence numbers that produced
/// it. Every message is a complete sentence for the capture UI; the evidence
/// map is what a reviewer (or a threshold tune) needs to judge the call.
class QualityFinding {
  const QualityFinding({
    required this.check,
    required this.severity,
    required this.code,
    required this.message,
    this.evidence = const <String, double>{},
  });

  final QualityCheckId check;
  final QualitySeverity severity;

  /// Stable machine code, e.g. `blur_low_sharpness`, `exposure_underexposed`.
  final String code;

  final String message;

  /// The measured values behind this finding (e.g. `laplacian_variance`).
  final Map<String, double> evidence;

  Map<String, Object?> toJson() => <String, Object?>{
    'check': check.wireName,
    'severity': severity.name,
    'code': code,
    'message': message,
    'evidence': evidence,
  };

  static QualityFinding fromJson(Map<String, Object?> json) {
    final severityName = json['severity'] as String?;
    final severity = QualitySeverity.values.firstWhere(
      (s) => s.name == severityName,
      orElse: () => QualitySeverity.info,
    );
    final evidence = <String, double>{};
    final rawEvidence = json['evidence'];
    if (rawEvidence is Map) {
      for (final entry in rawEvidence.entries) {
        final value = entry.value;
        if (value is num) evidence['${entry.key}'] = value.toDouble();
      }
    }
    return QualityFinding(
      check: QualityCheckId.fromWire(json['check'] as String?) ??
          QualityCheckId.jpegIntegrity,
      severity: severity,
      code: '${json['code'] ?? 'unknown'}',
      message: '${json['message'] ?? ''}',
      evidence: evidence,
    );
  }
}

/// The complete quality verdict for one saved photograph.
///
/// Stored as JSON in the session store's per-frame row (`quality_json`), so
/// the capture UI, the preview and the cloud backup all read the same report
/// without re-running any pixel work.
class FrameQualityReport {
  const FrameQualityReport({
    required this.targetId,
    required this.verdict,
    required this.findings,
    required this.analyzedAtMs,
    required this.analyzerVersion,
    required this.thresholdsVersion,
  });

  /// Bumped whenever the analyzer's measurements change meaning.
  static const int kAnalyzerVersion = 1;

  final int targetId;
  final QualityVerdict verdict;
  final List<QualityFinding> findings;

  /// Epoch milliseconds (UTC) — matches the session store's timestamp format.
  final int analyzedAtMs;
  final int analyzerVersion;

  /// The [CaptureQualityThresholds.fingerprint] in force, so a report can
  /// always be traced to the exact thresholds that produced it.
  final String thresholdsVersion;

  static FrameQualityReport accepted(
    int targetId,
    String thresholdsVersion, {
    List<QualityFinding> findings = const <QualityFinding>[],
  }) =>
      FrameQualityReport(
        targetId: targetId,
        verdict: QualityVerdict.accepted,
        findings: findings,
        analyzedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        analyzerVersion: kAnalyzerVersion,
        thresholdsVersion: thresholdsVersion,
      );

  bool get hasWarnings => verdict != QualityVerdict.accepted;

  bool get isInvalid => verdict == QualityVerdict.invalid;

  /// The headline for a banner: the strongest finding, else null.
  QualityFinding? get headline {
    for (final severity in const <QualitySeverity>[
      QualitySeverity.critical,
      QualitySeverity.warning,
    ]) {
      for (final finding in findings) {
        if (finding.severity == severity) return finding;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'target_id': targetId,
    'verdict': verdict.wireName,
    'findings': <Object?>[for (final finding in findings) finding.toJson()],
    'analyzed_at_ms': analyzedAtMs,
    'analyzer_version': analyzerVersion,
    'thresholds_version': thresholdsVersion,
  };

  String encode() => jsonEncode(toJson());

  static FrameQualityReport fromJson(Map<String, Object?> json) {
    final findings = <QualityFinding>[];
    final raw = json['findings'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          findings.add(
            QualityFinding.fromJson(entry.cast<String, Object?>()),
          );
        }
      }
    }
    return FrameQualityReport(
      targetId: (json['target_id'] as num?)?.toInt() ?? 0,
      verdict: QualityVerdict.fromWire(json['verdict'] as String?),
      findings: findings,
      analyzedAtMs: (json['analyzed_at_ms'] as num?)?.toInt() ?? 0,
      analyzerVersion: (json['analyzer_version'] as num?)?.toInt() ?? 0,
      thresholdsVersion: '${json['thresholds_version'] ?? ''}',
    );
  }

  /// Parses the `quality_json` column value; `null` when absent/corrupt.
  static FrameQualityReport? tryDecode(String? qualityJson) {
    if (qualityJson == null || qualityJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(qualityJson);
      if (decoded is! Map) return null;
      return FrameQualityReport.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }
}
