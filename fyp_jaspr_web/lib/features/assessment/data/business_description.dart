/// The confirmed business description the report's section 02 shows.
///
/// Source: `GET /api/v1/assessments/{id}/business-description` (RP-13). The
/// backend reads the persisted Business Context packet, re-derives it and
/// re-verifies its hash before answering, so what arrives here is either a
/// verified, version-bound description or an explicit state saying why there
/// is none.
///
/// Three rules this model enforces rather than trusts:
///
/// 1. **No invention.** A row with no text and no code is dropped at parse
///    time, so the UI cannot print a placeholder as if it were an answer.
/// 2. **No silent upgrade.** `AVAILABLE` is the only status that yields rows.
///    Every other status renders the report's held state.
/// 3. **Provenance is mandatory.** An `AVAILABLE` payload without a context id,
///    confirmation id and revision is rejected: a description that cannot name
///    the confirmation it came from must not be shown as confirmed.
library;

/// One declared field, with the M2 answer it was projected from.
class BusinessDescriptionRow {
  const BusinessDescriptionRow({
    required this.key,
    required this.label,
    required this.text,
    required this.code,
    required this.source,
  });

  /// Packet section key, e.g. `product_categories`.
  final String key;

  /// The report's own heading for the field.
  final String label;

  /// The entrepreneur's free-text value, when the field has one.
  final String? text;

  /// The instrument's option caption for a coded answer, when there is one.
  /// Kept separate from [text] so a code is never presented as prose the
  /// entrepreneur wrote.
  final String? code;

  /// `item_key` / `item_version_id` / `answer_revision_id` / `source_hash` /
  /// `confirmation_id` — the answer this field was read from.
  final Map<String, dynamic> source;

  factory BusinessDescriptionRow.fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    return BusinessDescriptionRow(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      text: _clean(json['text']),
      code: _clean(json['code']),
      source: source is Map ? source.cast<String, dynamic>() : const {},
    );
  }

  /// True when this row has something to show.
  bool get hasValue => text != null || code != null;

  static String? _clean(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// The confirmed business description, or the reason there is none.
class BusinessDescription {
  const BusinessDescription({
    required this.status,
    required this.reasonCode,
    required this.detail,
    required this.source,
    required this.rows,
    required this.uncertainty,
    required this.limitations,
    required this.evidenceClass,
  });

  /// `AVAILABLE` | `NO_M2_LINK` | `NO_CONFIRMED_BUSINESS_CONTEXT` |
  /// `BUSINESS_CONTEXT_HELD` | `UNAVAILABLE`.
  final String status;
  final String? reasonCode;
  final String? detail;

  /// Context id, confirmation id, revision, packet hash, concept version.
  final Map<String, dynamic> source;

  final List<BusinessDescriptionRow> rows;

  /// The entrepreneur's own confirmed uncertainty, when the packet carries one.
  final ({String id, String text})? uncertainty;

  /// The packet's limitations, verbatim. Never paraphrased here.
  final List<String> limitations;

  /// `ENTREPRENEUR_CONFIRMED` — a declaration, not independent verification.
  final String? evidenceClass;

  bool get isAvailable => status == 'AVAILABLE' && rows.isNotEmpty;

  /// True when the assessment simply has nothing confirmed yet, as opposed to
  /// a context that exists but could not be verified. The two read differently
  /// in the report, because they call for different actions.
  bool get isNotYetConfirmed =>
      status == 'NO_M2_LINK' || status == 'NO_CONFIRMED_BUSINESS_CONTEXT';

  factory BusinessDescription.fromJson(Map<String, dynamic> json) {
    if (json['contract_version'] != 'report-business-description/1') {
      throw const FormatException('Unrecognized business description contract.');
    }
    final status = json['status'] as String? ?? 'UNAVAILABLE';
    final rows = <BusinessDescriptionRow>[
      for (final row in (json['rows'] as List<dynamic>? ?? const []))
        if (row is Map) BusinessDescriptionRow.fromJson(row.cast<String, dynamic>()),
    ].where((row) => row.hasValue).toList();

    final source = (json['source'] as Map?)?.cast<String, dynamic>() ?? const {};

    if (status == 'AVAILABLE') {
      // A description that cannot name its confirmation is not a confirmed
      // description. Reject it rather than render it under a "confirmed" label.
      final complete = source['context_id'] is String &&
          source['confirmation_id'] is String &&
          source['assessment_revision'] is int &&
          source['packet_hash'] is String;
      if (!complete) {
        throw const FormatException(
          'Business description is missing its confirmation provenance.',
        );
      }
    }

    final uncertainty = json['uncertainty'];
    return BusinessDescription(
      status: status,
      reasonCode: json['reason_code'] as String?,
      detail: json['detail'] as String?,
      source: source,
      rows: status == 'AVAILABLE' ? rows : const [],
      uncertainty: uncertainty is Map && uncertainty['text'] is String
          ? (
              id: '${uncertainty['id'] ?? ''}',
              text: uncertainty['text'] as String,
            )
          : null,
      limitations: [
        for (final item in (json['limitations'] as List<dynamic>? ?? const []))
          if (item is String && item.isNotEmpty) item,
      ],
      evidenceClass: json['evidence_class'] as String?,
    );
  }
}
