/// The six fixed research objectives the governed instrument is built around.
///
/// Why this list lives in the client
/// --------------------------------
/// Section A of the Stage 3 review names the objectives that apply to *every*
/// assessment, whether or not a proposal ever cites them. The server already
/// owns that set — `TOPIC_TO_OBJECTIVE` in
/// `backend/src/sitewise/project1/issue_resolution.py` maps the M2V2-09 topic
/// codes onto `O1`–`O6` — but no route exposes it, and inventing a new endpoint
/// to render six static strings would add a transport for a constant.
///
/// So the set is mirrored here, and the mirror is deliberately narrow: it is a
/// copy of the registry, not a second definition. If the server's mapping ever
/// changes, this file must change with it. [topic] is carried verbatim so the
/// mismatch is greppable — searching the repository for `SEGMENT_INTEREST`
/// finds both copies.
///
/// What this list is *not*
/// -----------------------
/// It is not evidence that any objective has been measured. The server records
/// `TOPIC_MAPPING_STATUS = 'PROPOSED_NOT_ADOPTED'`, so the mapping from topic
/// code to objective id is still a candidate. The interface therefore states
/// "inclusion does not establish measurement validity" beside the grid rather
/// than presenting the six as settled science.
library;

/// One fixed objective: its registry id, the M2V2-09 topic it derives from, and
/// a one-line description of what it measures.
final class FixedObjective {
  /// The registry id, `O1`–`O6`. Used verbatim in cards, chips and summaries.
  final String id;

  /// The M2V2-09 option code this objective derives from, verbatim.
  final String topic;

  /// Reader-facing name, e.g. "Concept interest".
  final String label;

  /// One sentence naming the construct. Kept short: it is a tile subtitle, not
  /// a definition, and the measurement library remains the authority.
  final String describes;

  const FixedObjective({
    required this.id,
    required this.topic,
    required this.label,
    required this.describes,
  });
}

/// `O1`–`O6`, in registry order.
///
/// Order is meaningful: it is the order the instrument's sections are numbered
/// in, so the grid reads the same way as the questionnaire it precedes.
const List<FixedObjective> fixedResearchObjectives = <FixedObjective>[
  FixedObjective(
    id: 'O1',
    topic: 'CONCEPT_INTEREST',
    label: 'Concept interest',
    describes: 'Whether the confirmed concept appeals to the people it targets.',
  ),
  FixedObjective(
    id: 'O2',
    topic: 'PRODUCT_PREFERENCE',
    label: 'Product preference',
    describes: 'Which product attributes the target customer actually prefers.',
  ),
  FixedObjective(
    id: 'O3',
    topic: 'PRICE_ACCEPTABILITY',
    label: 'Price acceptability',
    describes: 'What price the target customer will accept for the concept.',
  ),
  FixedObjective(
    id: 'O4',
    topic: 'SERVICE_PREFERENCE',
    label: 'Service preference',
    describes: 'Which service mode the target customer prefers, and why.',
  ),
  FixedObjective(
    id: 'O5',
    topic: 'EXPERIENCE_PREFERENCE',
    label: 'Experience preference',
    describes: 'Which in-venue experience the target customer prefers.',
  ),
  FixedObjective(
    id: 'O6',
    topic: 'SEGMENT_INTEREST',
    label: 'Segment interest',
    describes: 'Which customer segments are interested, and how they differ.',
  ),
];

/// The fixed objective a registry id names, or `null` when the id is not one of
/// the six (an `O7`, or a `proposal:<uuid>` objective).
///
/// Callers use this to label a proposal that happens to be bound to a fixed
/// objective; an unknown id is not an error, because additional objectives are
/// keyed by proposal id rather than by registry id.
FixedObjective? fixedObjectiveById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final objective in fixedResearchObjectives) {
    if (objective.id == id) return objective;
  }
  return null;
}
