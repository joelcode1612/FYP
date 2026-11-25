/// The synthetic chart preview for section 05: one frozen EE-01 snapshot per
/// measured slot, converted server-side into `chart-spec/1`.
///
/// Why this is a separate type from [ReportMeasurement]
/// ----------------------------------------------------
/// The measurement association says *what evidence exists and whether it may be
/// disclosed*. This says *what a developer may inspect*, and it exists only in
/// a build where the synthetic-preview gate is open. Keeping them apart means a
/// bug in one cannot promote the other: an association never grows a count, and
/// a preview never becomes an admitted finding.
///
/// The server decides eligibility, not this client. A slot arrives either
/// `eligible` with a validated spec, or ineligible with the contract's own
/// refusal code. Nothing here re-derives that decision, and nothing here turns a
/// refusal into an empty chart — an empty chart reads as a measured zero.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';

/// The funnel that produced one slot's numbers. `V` is the only denominator.
class ChartPreviewFunnel {
  const ChartPreviewFunnel({
    required this.qualified,
    required this.shown,
    required this.answered,
    required this.substantive,
  });

  final int qualified;
  final int shown;
  final int answered;
  final int substantive;

  static ChartPreviewFunnel? tryParse(Object? raw) {
    if (raw is! Map) return null;
    int whole(Object? value) => value is num ? value.toInt() : 0;
    return ChartPreviewFunnel(
      qualified: whole(raw['q']),
      shown: whole(raw['s']),
      answered: whole(raw['a']),
      substantive: whole(raw['v']),
    );
  }
}

/// One measured slot, as the preview endpoint answered for it.
class ChartPreviewSlot {
  const ChartPreviewSlot({
    required this.slotId,
    required this.snapshotId,
    required this.cutoff,
    required this.eligible,
    required this.refusalCode,
    required this.spec,
    required this.funnel,
    this.candidates = 1,
  });

  final String slotId;
  final String? snapshotId;
  final String? cutoff;

  /// How many snapshots of this slot the campaign holds.
  ///
  /// More than one means the drawn evidence was *selected* by the server's
  /// published policy, not that it was the only revision. Shown in the scope
  /// line so a reader is never told "the measurement" when there were several.
  final int candidates;

  /// Whether the server could express this slot as a chart at all.
  final bool eligible;

  /// The contract's own refusal code when it could not.
  final String? refusalCode;
  final ChartSpecModel? spec;
  final ChartPreviewFunnel? funnel;

  /// A slot the report may draw as a synthetic diagnostic.
  ///
  /// Deliberately narrow: it must be eligible, it must parse, and its render
  /// state must be the synthetic one. A `WITHHELD_NOT_AUTHORIZED` spec is
  /// eligible but not drawable here, because its counts are not disclosed —
  /// drawing it would be the disclosure the admission block forbids.
  bool get isDrawable => eligible && (spec?.isSyntheticPreview ?? false);

  /// A question that was never presented. It must be described, not charted.
  bool get isNotShown => spec?.renderState == ChartRenderState.notShown;

  /// A slot whose frozen contract requires an approved stimulus that does not
  /// exist. The preview may not manufacture one.
  bool get isMissingStimulus =>
      spec?.renderState == ChartRenderState.unavailableMissingApprovedStimulus;

  /// Why this slot is not drawn, in the reader's terms rather than a code.
  String get stateLine {
    if (!eligible) {
      return 'Not convertible: ${refusalCode ?? 'unknown reason'}.';
    }
    if (isNotShown) {
      return 'Not shown: the routing rules never presented this question, so '
          'there is no distribution to draw. This is not a zero result.';
    }
    if (isMissingStimulus) {
      return 'Withheld: the frozen contract requires an approved stimulus that '
          'does not exist, so the counts cannot be interpreted. A preview does '
          'not manufacture an authorization.';
    }
    if (!isDrawable) {
      return 'Held: this line is not disclosed in a preview.';
    }
    return '';
  }

  static ChartPreviewSlot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final slotId = raw['slot_id']?.toString();
    if (slotId == null || slotId.isEmpty) return null;
    ChartSpecModel? spec;
    final rawSpec = raw['spec'];
    if (rawSpec is Map) {
      try {
        spec = ChartSpecModel.fromJson(Map<String, dynamic>.from(rawSpec));
      } on Object {
        // A spec that will not validate is not drawn. The server's refusal is
        // recorded below instead of being replaced by an empty chart.
        spec = null;
      }
    }
    final eligible = raw['eligible'] == true && spec != null;
    final rawCandidates = raw['candidates'];
    return ChartPreviewSlot(
      slotId: slotId,
      snapshotId: raw['snapshot_id']?.toString(),
      cutoff: raw['cutoff']?.toString(),
      eligible: eligible,
      refusalCode: eligible ? null : (raw['code']?.toString() ?? 'CHART_SPEC_INVALID'),
      spec: spec,
      funnel: ChartPreviewFunnel.tryParse(raw['funnel']),
      candidates: rawCandidates is num && rawCandidates > 1
          ? rawCandidates.toInt()
          : 1,
    );
  }
}

/// The whole answer for one campaign.
class ChartPreviewBundle {
  const ChartPreviewBundle({
    required this.contractVersion,
    required this.campaignId,
    required this.synthetic,
    required this.reportable,
    required this.slots,
    this.selectionPolicy,
  });

  static const contract = 'chart-preview/1';

  final String contractVersion;
  final String campaignId;

  /// Always true for this contract; carried so a client never has to assume it.
  final bool synthetic;

  /// Always false. A preview is never a finding.
  final bool reportable;

  /// How the server chose one snapshot per slot when several existed.
  final String? selectionPolicy;
  final List<ChartPreviewSlot> slots;

  /// The slots that may be drawn as a synthetic diagnostic.
  List<ChartPreviewSlot> get drawable =>
      slots.where((s) => s.isDrawable).toList(growable: false);

  /// Slots whose evidence was selected from more than one stored revision.
  List<ChartPreviewSlot> get multiRevision =>
      slots.where((s) => s.candidates > 1).toList(growable: false);

  static ChartPreviewBundle? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['contract_version'] != contract) return null;
    // Fail closed on the two markers that make this a preview at all. A server
    // that answered `synthetic: false` or `reportable: true` is not speaking
    // this contract, and accepting it would let a preview pose as a finding.
    if (raw['synthetic'] != true || raw['reportable'] != false) return null;
    final slots = <ChartPreviewSlot>[
      for (final entry in (raw['slots'] as List? ?? const []))
        ?ChartPreviewSlot.tryParse(entry),
    ];
    return ChartPreviewBundle(
      contractVersion: contract,
      campaignId: raw['campaign_id']?.toString() ?? '',
      synthetic: true,
      reportable: false,
      selectionPolicy: raw['selection_policy']?.toString(),
      slots: slots,
    );
  }
}
