/// The questionnaire-measurement association the report's section 05 shows.
///
/// Source: the `measurement` key of `GET /api/v1/assessments/{id}/report`
/// (`report-measurement/1`), resolved server-side as
/// marketplace assessment → M2 assessment → CQ campaign → frozen snapshot.
///
/// Why this exists rather than a chart
/// -----------------------------------
/// Section 05 reserves R03 for the concept-intent distribution, and the report
/// used to render the specification's default notice — *"no admitted
/// measurement line exists for this assessment"* — for every assessment,
/// including one that owns seven frozen snapshots. That sentence is true about
/// admission and false about existence, and a reader cannot tell the two apart.
/// This model carries the distinction: [evidenceExists] says whether a
/// measurement is associated, [isHeld] says whether it may be disclosed.
///
/// Three rules enforced here, not trusted from the server:
///
/// 1. **No counts.** [countsDisclosed] must be `false` for this section to be
///    shown as a held association. The payload carries no count, no percentage
///    and no option list at all; if a future server started sending them, this
///    model would still render the held state, because it has nowhere to put
///    them.
/// 2. **No promotion.** [isHeld] is derived from the server's status, and
///    `HELD` never becomes renderable here. Only [detailReadable] — a server
///    assertion that stays `false` while no A10 admission adapter is adopted —
///    permits fetching measurement detail.
/// 3. **Identity is mandatory for `available`.** An available association that
///    cannot name its campaign and snapshot is rejected at parse time: a
///    measurement that cannot say which frozen cohort it describes must not be
///    presented as this assessment's.
library;

/// One frozen snapshot's identity. No measurement value appears here.
class MeasurementSlot {
  const MeasurementSlot({
    required this.slotId,
    required this.snapshotId,
    required this.questionVersion,
    required this.cutoff,
    required this.admissionState,
  });

  /// Question slot, e.g. `Q05`.
  final String slotId;

  /// The frozen snapshot this slot's latest evidence lives in.
  final String snapshotId;

  /// Instrument version the snapshot was measured against.
  final String? questionVersion;

  /// The snapshot's own cutoff — the instant its cohort was frozen at. Two
  /// cutoffs of one slot are two cohorts, not two revisions of one finding.
  final DateTime? cutoff;

  /// `REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE` while admission is held.
  final String? admissionState;

  static MeasurementSlot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final slotId = raw['slot_id']?.toString();
    final snapshotId = raw['snapshot_id']?.toString();
    if (slotId == null || slotId.isEmpty) return null;
    if (snapshotId == null || snapshotId.isEmpty) return null;
    return MeasurementSlot(
      slotId: slotId,
      snapshotId: snapshotId,
      questionVersion: raw['question_version']?.toString(),
      cutoff: DateTime.tryParse(raw['cutoff']?.toString() ?? ''),
      admissionState: raw['admission_state']?.toString(),
    );
  }
}

/// The snapshot section 05 is about (Q05 / R03), with its full identity.
class MeasurementIdentity {
  const MeasurementIdentity({
    required this.m2AssessmentId,
    required this.campaignId,
    required this.releaseId,
    required this.slotId,
    required this.snapshotId,
    required this.questionVersion,
    required this.cutoff,
    required this.fingerprint,
    required this.contextHash,
    required this.admissionState,
  });

  final String m2AssessmentId;
  final String campaignId;
  final String? releaseId;
  final String? slotId;
  final String? snapshotId;
  final String? questionVersion;
  final DateTime? cutoff;

  /// EE-01 snapshot fingerprint — the identity a re-read must reproduce.
  final String? fingerprint;

  /// Readback context hash; the join key to any explanation.
  final String? contextHash;
  final String? admissionState;

  static MeasurementIdentity? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m2 = raw['m2_assessment_id']?.toString();
    final campaign = raw['campaign_id']?.toString();
    if (m2 == null || m2.isEmpty) return null;
    if (campaign == null || campaign.isEmpty) return null;
    return MeasurementIdentity(
      m2AssessmentId: m2,
      campaignId: campaign,
      releaseId: raw['release_id']?.toString(),
      slotId: raw['slot_id']?.toString(),
      snapshotId: raw['snapshot_id']?.toString(),
      questionVersion: raw['question_version']?.toString(),
      cutoff: DateTime.tryParse(raw['cutoff']?.toString() ?? ''),
      fingerprint: raw['fingerprint']?.toString(),
      contextHash: raw['context_hash']?.toString(),
      admissionState: raw['admission_state']?.toString(),
    );
  }
}

/// The report's `measurement` section.
class ReportMeasurement {
  const ReportMeasurement({
    required this.contractVersion,
    required this.available,
    required this.status,
    required this.reasonCode,
    required this.reason,
    required this.countsDisclosed,
    required this.detailReadable,
    required this.identity,
    required this.slots,
    required this.admissionState,
    required this.reportReleaseAuthorized,
  });

  static const contract = 'report-measurement/1';

  /// States the server may report. Kept as constants so a typo in a comparison
  /// is a compile error rather than a silently false branch.
  static const statusHeld = 'HELD';
  static const statusNoM2Link = 'NO_M2_LINK';
  static const statusNoCampaign = 'NO_CAMPAIGN';
  static const statusUnavailable = 'UNAVAILABLE';
  static const statusNotResolved = 'NOT_RESOLVED';

  final String contractVersion;

  /// True when a measurement is associated with this assessment — held or not.
  final bool available;

  /// One of the `status*` constants.
  final String status;

  /// The server's own code, e.g. `REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE`.
  final String? reasonCode;

  /// A sentence the report can print verbatim; never invented client-side.
  final String reason;

  /// Always `false` for this section. Present so the report can assert it.
  final bool countsDisclosed;

  /// Whether measurement detail may be fetched. `false` while admission is held.
  final bool detailReadable;

  final MeasurementIdentity? identity;
  final List<MeasurementSlot> slots;
  final String? admissionState;
  final bool reportReleaseAuthorized;

  /// Evidence is associated with this assessment.
  bool get evidenceExists => available && status == statusHeld;

  /// Evidence exists but may not be disclosed. This is the only reachable
  /// state today, and the one section 05 must describe accurately.
  bool get isHeld => evidenceExists && !detailReadable;

  /// The slot section 05 is about, when the server named one.
  String? get focusSlot => identity?.slotId;

  /// A short, printable description of the frozen cohort, e.g.
  /// `Q05 · cutoff 25 Nov 2026 18:00`. Null when the server named no cutoff.
  String? get cohortLabel {
    final slot = identity?.slotId;
    final cutoff = identity?.cutoff;
    if (slot == null) return null;
    if (cutoff == null) return slot;
    final local = cutoff.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '$slot · cutoff ${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static ReportMeasurement? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, dynamic>();
    if (json['contract_version'] != contract) return null;
    final status = json['status']?.toString();
    if (status == null || status.isEmpty) return null;
    final slots = <MeasurementSlot>[
      for (final entry in (json['slots'] as List? ?? const []))
        ?MeasurementSlot.tryParse(entry),
    ];
    final admission = json['admission'];
    return ReportMeasurement(
      contractVersion: contract,
      available: json['available'] == true,
      status: status,
      reasonCode: json['reason_code']?.toString(),
      reason: json['reason']?.toString() ?? '',
      countsDisclosed: json['counts_disclosed'] == true,
      detailReadable: json['detail_readable'] == true,
      identity: MeasurementIdentity.tryParse(json['identity']),
      slots: slots,
      admissionState:
          admission is Map ? admission['state']?.toString() : null,
      reportReleaseAuthorized:
          admission is Map && admission['report_release_authorized'] == true,
    );
  }
}

/// One category cell of an `ee01-diagnostic/1` snapshot.
///
/// Only reachable through the measurement endpoint, which refuses synthetic
/// evidence with `403 SYNTHETIC_DATA_NOT_REPORTABLE` today. It exists so the
/// authorised read has a typed shape when admission lands — and so the refusal
/// path is the only path that can currently be executed.
class MeasurementCell {
  const MeasurementCell({
    required this.code,
    required this.count,
    required this.denominator,
    required this.percentage,
    required this.diagnosticPercentage,
    required this.status,
  });

  final String code;
  final int count;
  final int denominator;

  /// `null` unless the snapshot is genuinely renderable. Never coerced to zero.
  final double? percentage;

  /// The uncalibrated diagnostic index. Never an authorised estimate.
  final double? diagnosticPercentage;
  final String? status;

  static MeasurementCell? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final code = raw['code']?.toString();
    if (code == null || code.isEmpty) return null;
    double? number(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('${value ?? ''}');
    int whole(Object? value) => value is num ? value.toInt() : 0;
    return MeasurementCell(
      code: code,
      count: whole(raw['x']),
      denominator: whole(raw['v']),
      percentage: number(raw['percentage']),
      diagnosticPercentage: number(raw['diagnostic_percentage']),
      status: raw['status']?.toString(),
    );
  }
}

/// A frozen `ee01-diagnostic/1` snapshot, as the measurement endpoint returns it.
class MeasurementSnapshot {
  const MeasurementSnapshot({
    required this.contractVersion,
    required this.slotId,
    required this.status,
    required this.scope,
    required this.cutoff,
    required this.qualified,
    required this.shown,
    required this.answered,
    required this.substantive,
    required this.cells,
  });

  static const contract = 'ee01-diagnostic/1';

  /// Derived codes are computed from base categories and must never be added
  /// to a base-category total. Named here so a caller cannot forget.
  static const derivedCodes = {'TOP_TWO_STATED_INTEREST'};

  final String contractVersion;
  final String slotId;
  final String status;
  final String scope;
  final DateTime? cutoff;

  /// `Q` — qualified units. `S` — shown. `A` — answered (incl. refused and
  /// invalid). `V` — substantive answers, the only denominator the categories
  /// are counted against.
  final int qualified;
  final int shown;
  final int answered;
  final int substantive;

  final List<MeasurementCell> cells;

  /// Base categories only — the derived top-two line is excluded, because
  /// adding it would double-count the two categories it is computed from.
  List<MeasurementCell> get baseCells =>
      cells.where((c) => !derivedCodes.contains(c.code)).toList();

  /// Sum of base-category counts. A display check, not a measurement: it must
  /// equal [substantive] for a single-select item and may exceed it for a
  /// multi-select one.
  int get baseCategoryCount =>
      baseCells.fold(0, (total, cell) => total + cell.count);

  static MeasurementSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, dynamic>();
    if (json['contract_version'] != contract) return null;
    final slot = json['slot_id']?.toString();
    final status = json['status']?.toString();
    if (slot == null || status == null) return null;
    int whole(Object? value) => value is num ? value.toInt() : 0;
    return MeasurementSnapshot(
      contractVersion: contract,
      slotId: slot,
      status: status,
      scope: json['scope']?.toString() ?? '',
      cutoff: DateTime.tryParse(json['cutoff']?.toString() ?? ''),
      qualified: whole(json['q']),
      shown: whole(json['s']),
      answered: whole(json['a']),
      substantive: whole(json['v']),
      cells: [
        for (final entry in (json['cells'] as List? ?? const []))
          ?MeasurementCell.tryParse(entry),
      ],
    );
  }
}
