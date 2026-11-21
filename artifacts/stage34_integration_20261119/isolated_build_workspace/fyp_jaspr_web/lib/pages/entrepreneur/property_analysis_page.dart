import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/full_analysis_view.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/assessment_api.dart';
import '../../data/full_analysis_actions.dart';
import '../../data/full_analysis_format.dart';
import '../../layouts/app_layout.dart';

/// The Full Analysis page — the web decision-support drill-down for one
/// catalogue property, at `/entrepreneur/property-analysis?id={id}`.
///
/// It assembles a [FullAnalysis] purely from reads:
///
/// * the catalogue listing (both id universes, through [AppLocator.properties]);
/// * the selected research artifact's metadata, the P/U association score and
///   the feature-coverage diagnostic (`/api/v1/ml/*`, [AppLocator.puPredictions]);
/// * the persisted assessment record, and — only when one exists — its saved
///   SHAP explanation and deterministic business-target matching
///   ([AssessmentApi], assessment-scoped reads).
///
/// **It never calls the POST explanation endpoint.** Reading this page neither
/// computes SHAP nor advances a stage; the validated explanation is shown only
/// if Stage 4 already produced and saved one. Each read is independently
/// guarded, so an unreachable model, a missing artifact or no signed-in session
/// renders an honest unavailable state (see [FullAnalysisBody]) instead of a
/// fabricated number. A null measurement is "Not recorded", never zero.
///
/// The Flutter mobile app does not reach this page: mobile assessment is a
/// separate data-collection workflow with its own session store.
@client
class PropertyAnalysisPage extends StatefulComponent {
  final String id;
  const PropertyAnalysisPage({super.key, required this.id});

  @override
  State<PropertyAnalysisPage> createState() => _PropertyAnalysisPageState();
}

/// The assembled analysis plus why no validated explanation is shown (null when
/// one exists). Kept together so the read-only guard message travels with the
/// data the page renders.
final class _Bundle {
  final FullAnalysis analysis;
  final String? explanationNote;
  const _Bundle(this.analysis, {this.explanationNote});
}

class _PropertyAnalysisPageState extends State<PropertyAnalysisPage> {
  static const AssessmentApi _api = AssessmentApi();

  late Future<_Bundle> _future = _load(component.id);

  /// Selected evidence category (section D). Empty falls through to the first
  /// category in [FullAnalysisBody]; the backend order is authoritative.
  String _selectedCategory = '';

  /// Feature-table search text (section H).
  String _search = '';

  /// Whether the last copy action succeeded, shown briefly on the button.
  bool _copied = false;

  /// Reads every source defensively and joins them into one [FullAnalysis].
  ///
  /// The property is required for the page to render; the ML reads and the
  /// assessment reads are each optional and never abort the others. A thrown
  /// transport error becomes a null piece, which the view turns into an
  /// honest "unavailable" state rather than a number.
  static Future<_Bundle> _load(String id) async {
    if (id.isEmpty) {
      return const _Bundle(
        FullAnalysis(propertyId: ''),
        explanationNote: 'No property was selected.',
      );
    }

    final property = await AppLocator.properties.detail(id);
    if (property == null) {
      return _Bundle(
        FullAnalysis(propertyId: id),
        explanationNote: 'This property could not be retrieved.',
      );
    }

    // Research-ML reads (auth-gated; a visitor gets nulls, not a crash).
    final model = await _guard(AppLocator.puPredictions.modelMetadata);
    final score = await _guard(
      () => AppLocator.puPredictions.getPropertyPrediction(id),
    );
    final coverage = await _guard(
      () => AppLocator.puPredictions.getPropertyCoverage(id),
    );

    // Assessment-scoped reads. A failed by-property read (401 for a visitor,
    // 404 for none) simply leaves record null — the workspace Start button,
    // not this page, creates an assessment.
    final signedIn = AppLocator.isSignedIn;
    AssessmentRecord? record;
    final byProperty = await _api.byProperty(id);
    if (byProperty.ok) record = byProperty.value;
    final assessmentId = record?.assessmentId;
    final requirements = record?.requirements;
    final hasRequirements = requirements != null && requirements.isNotEmpty;

    // Only read the persisted explanation and targets, and only when an
    // assessment exists. Never POST — computing SHAP is Stage 4's job.
    ResearchExplanation? explanation;
    BusinessTargetEvaluation? targets;
    if (assessmentId != null) {
      final explanationResult = await _api.explanation(assessmentId);
      if (explanationResult.ok) explanation = explanationResult.value;
      final targetsResult = await _api.targetMatching(assessmentId);
      if (targetsResult.ok) targets = targetsResult.value;
    }

    final analysis = FullAnalysis(
      propertyId: id,
      property: property,
      model: model,
      score: score,
      coverage: coverage,
      explanation: explanation,
      targets: targets,
      assessmentId: assessmentId,
      hasRequirements: hasRequirements,
    );

    return _Bundle(
      analysis,
      explanationNote: _whyNoExplanation(analysis, signedIn),
    );
  }

  /// The honest reason the explanation section shows no waterfall. Null when a
  /// validated explanation exists (the view then renders it).
  static String? _whyNoExplanation(FullAnalysis analysis, bool signedIn) {
    if (analysis.hasValidShap) return null;
    if (!signedIn) {
      return 'Sign in to read your saved AI explanation and business-target '
          'matching. Loading this page never computes SHAP or advances a '
          'stage.';
    }
    if (analysis.assessmentId == null) {
      return 'No assessment has been started for this property yet. Start one '
          'in the workspace to save your business targets and generate the '
          'validated explanation.';
    }
    final explanation = analysis.explanation;
    if (explanation == null) {
      return 'The AI explanation has not been generated for this assessment '
          'yet. Run Stage 4 in the workspace to compute and save it. Reading '
          'this page never computes SHAP or advances a stage.';
    }
    // Present but did not reconstruct the output within tolerance.
    return 'The saved explanation did not reconstruct the model output within '
        'the validated tolerance, so it is withheld rather than presented as '
        'verified. Regenerate it in the workspace.';
  }

  void _reload() => setState(() => _future = _load(component.id));

  Future<void> _copy(FullAnalysis analysis) async {
    final text = analysis.hasValidShap
        ? faNarrative(analysis).plain
        : 'Sitewise Full Analysis for property ${analysis.propertyId}: no '
              'validated SHAP explanation has been generated yet, so there is '
              'no model explanation to copy.';
    final ok = await copyText(text);
    if (!ok || !mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/property-analysis',
    title: 'Full property analysis',
    eyebrow: 'Location intelligence',
    showPageHead: false,
    child: FutureBuilder<_Bundle>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return div(classes: 'loading', [
            Component.text('Loading property analysis…'),
          ]);
        }
        if (snap.hasError || snap.data == null) {
          return EmptyState(
            title: 'Analysis unavailable',
            body:
                'The property and its analysis could not be retrieved. '
                'Verify your sign-in and connection, then try again.',
            action: ActionButton('Retry', onClick: _reload, icon: 'refresh'),
          );
        }
        final bundle = snap.data!;
        final analysis = bundle.analysis;
        if (analysis.property == null) {
          return EmptyState(
            title: 'Property not available',
            body:
                bundle.explanationNote ??
                'This property could not be retrieved.',
            action: const ActionLink(
              'Back to Explore',
              href: '/entrepreneur/explore',
            ),
          );
        }
        final encodedId = Uri.encodeComponent(analysis.propertyId);
        return FullAnalysisBody(
          analysis: analysis,
          selectedCategory: _selectedCategory,
          onSelectCategory: (key) => setState(() => _selectedCategory = key),
          search: _search,
          onSearch: (value) => setState(() => _search = value),
          copied: _copied,
          onCopy: () => _copy(analysis),
          onPrint: printPage,
          assessmentHref: '/entrepreneur/assessments?id=$encodedId',
          reportHref: '/entrepreneur/report?id=$encodedId',
          signedIn: AppLocator.isSignedIn,
          explanationNote: bundle.explanationNote,
        );
      },
    ),
  );
}

/// Runs one research-ML read and reports failure as a null piece rather than
/// throwing: an unreachable model, a missing artifact or a 401 for a visitor
/// must each leave that section honestly unavailable, not break the page.
Future<T?> _guard<T>(Future<T> Function() read) async {
  try {
    return await read();
  } on Object {
    return null;
  }
}
