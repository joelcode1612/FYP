import 'assessment_draft.dart';

/// Non-authoritative, deterministic, entrepreneur-source-linked UI notices.
/// This is NOT the BDJ scientific review engine, a risk scorer or report generator.
class ReviewNote {
  const ReviewNote({required this.title, required this.basis,
    required this.limitation, required this.nextAction, required this.sourceIds});
  final String title;
  final String basis;
  final String limitation;
  final String nextAction;
  final List<String> sourceIds;
}

List<ReviewNote> makeDemoReviewNotes(AssessmentDraft draft) {
  final notes = <ReviewNote>[];
  if (draft.description.trim().isEmpty) {
    notes.add(const ReviewNote(
      title: 'Description not provided (recommended)',
      basis: 'No description was entered in M2-04.',
      limitation: 'A blank recommended field is not evidence of a poor business plan.',
      nextAction: 'You can add your own description if you want.',
      sourceIds: ['M2-04'],
    ));
  }
  if (draft.multi('M2-07').contains('Students') &&
      draft.single('M2-08') == 'General assumption') {
    notes.add(const ReviewNote(
      title: 'Customer assumption worth exploring',
      basis: 'You selected Students (M2-07) and General assumption (M2-08).',
      limitation: 'These answers do not establish actual student demand.',
      nextAction: 'Consider what evidence could test your intended customer group.',
      sourceIds: ['M2-07', 'M2-08'],
    ));
  }
  final forecast = draft.single('M2-O-01');
  if (forecast.isNotEmpty && forecast != 'Not estimated') {
    notes.add(ReviewNote(
      title: 'Weekday customers: entrepreneur forecast',
      basis: 'You estimated $forecast customers on a typical weekday (M2-O-01).',
      limitation: 'An estimate is not observed demand, measured footfall or revenue.',
      nextAction: 'Keep this as a planning assumption until separately verified.',
      sourceIds: const ['M2-O-01'],
    ));
  }
  final breakEven = draft.single('M2-14');
  if (breakEven.isNotEmpty && breakEven != 'Not estimated') {
    notes.add(ReviewNote(
      title: 'Break-even timeline is an assumption',
      basis: 'You selected $breakEven in M2-14.',
      limitation: 'M2 does not supply sufficient fixed-cost, unit-cost and price inputs for a calculated break-even.',
      nextAction: 'Investigate calculation prerequisites in a separately governed financial workflow.',
      sourceIds: const ['M2-14'],
    ));
  }
  if (draft.multi('M2-17').contains('Rent/occupancy costs')) {
    notes.add(const ReviewNote(
      title: 'Occupancy cost information requested',
      basis: 'You selected Rent/occupancy costs as missing information (M2-17).',
      limitation: 'This does not establish that rent is unaffordable.',
      nextAction: 'Review relevant quotations or qualified cost evidence when available.',
      sourceIds: ['M2-17'],
    ));
  }
  if (draft.multi('M2-16').contains('A prior survey I ran')) {
    notes.add(const ReviewNote(
      title: 'A survey was declared, not verified',
      basis: 'You selected A prior survey I ran (M2-16).',
      limitation: 'Its sample, questionnaire, responses and methodology have not been reviewed.',
      nextAction: 'Keep its status DECLARED_HELD until the appropriate evidence review.',
      sourceIds: ['M2-16'],
    ));
  }
  return List.unmodifiable(notes);
}
