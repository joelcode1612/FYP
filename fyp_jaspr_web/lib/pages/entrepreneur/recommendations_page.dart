import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web recommendations ("Your shortlist"), laid out as the source's
/// `recommendations.html`.
///
/// ```text
/// .page-head   "Recommendations" · "Your shortlist" · criteria line
/// .rec-item    rank tile · title + why bullets · score
/// ```
///
/// The source renders one **row** per recommendation — rank, property, score —
/// with the model's reasons inline. The previous version wrapped a full
/// `.pcard` in a 3-column grid and appended a separate `.why` block, which
/// duplicated the card's own actions and buried the score.
@client
class RecommendationsPage extends StatefulComponent {
  const RecommendationsPage({super.key});

  @override
  State<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends State<RecommendationsPage> {
  late final EntrepreneurCubit vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newEntrepreneurCubit();
    unawaited(vm.loadRecommendations());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AppCubit, AppState>(
      cubit: AppLocator.appCubit,
      builder: (context, _) {
        final appCubit = AppLocator.appCubit;
        return CubitBuilder<EntrepreneurCubit, EntrepreneurState>(
          cubit: vm,
          builder: (context, _) {
            return AppLayout(
              role: AppRole.entrepreneur,
              currentRoute: '/entrepreneur/recommendations',
              title: 'Your shortlist',
              eyebrow: 'Recommendations',
              subtitle:
                  '${vm.prefs.businessType} · up to '
                  'RM${vm.prefs.maxBudgetRm.toStringAsFixed(0)} · min '
                  '${vm.prefs.minSizeSqft.toStringAsFixed(0)} sq ft. Ranked '
                  'sites with the reasoning behind each one.',
              actions: const [
                ActionLink(
                  'Edit preferences',
                  href: '/entrepreneur/preferences',
                  variant: 'secondary',
                ),
              ],
              child: vm.loading
                  ? const _Loading()
                  : vm.recommendations.isEmpty
                  ? const _Empty()
                  : div(classes: 'stack stack--md', [
                      for (var i = 0; i < vm.recommendations.length; i++)
                        _row(appCubit, vm.recommendations[i], i),
                      p(classes: 'disclaimer', [
                        Component.text(
                          'A suitability score is a relative decision-support '
                          'indicator. It is not a probability of business '
                          'success, a revenue or customer-volume forecast, '
                          'regulatory approval, or a guarantee of any kind.',
                        ),
                      ]),
                    ]),
            );
          },
        );
      },
    );
  }

  Component _row(AppCubit appCubit, PropertyRecommendation r, int index) {
    final id = r.property.id;
    final prop = r.property;
    return div(classes: 'rec-item', [
      // Rank tile.
      span(classes: 'rec-rank', [Component.text('${index + 1}')]),

      // Title, meta, and the model's own explanation bullets.
      div(classes: 'stack stack--sm', [
        h3(classes: 'title', [
          AppLink(
            to: '/entrepreneur/property-detail?id=$id',
            children: [Component.text(prop.title)],
          ),
        ]),
        p(classes: 'small', [
          Component.text(
            '${prop.address}, ${prop.city} · ${prop.rentalDisplay} · '
            '${prop.sizeSqft.toStringAsFixed(0)} sq ft · ${prop.propertyType}',
          ),
        ]),
        div(classes: 'chips', [
          StatusBadge(
            'Verification: ${prop.verification.label.toLowerCase()}',
            tone: toneForVerification(prop.verification),
          ),
          if (prop.hasTour) const StatusBadge('360° tour', tone: 'action'),
        ]),
        // `whyRecommended` is the model's own text — nothing here is generated
        // by the UI, and there are no SHAP values to show because the model does
        // not return any.
        if (r.whyRecommended.isNotEmpty)
          div(classes: 'why', [
            span(classes: 'overline', [Component.text('Why recommended')]),
            for (final bullet in r.whyRecommended)
              div(classes: 'why__item', [
                Icon('check', size: 'sm'),
                span([Component.text(bullet)]),
              ]),
          ]),
        div(classes: 'actions-row', [
          ActionLink(
            'View details',
            href: '/entrepreneur/property-detail?id=$id',
            variant: 'primary',
          ),
          ActionButton(
            appCubit.isSaved(id) ? 'Saved' : 'Save',
            variant: 'secondary',
            icon: appCubit.isSaved(id) ? 'bookmark' : 'bookmark_border',
            onClick: () => appCubit.toggleSaved(id),
          ),
          ActionButton(
            appCubit.isCompared(id) ? 'In compare' : 'Compare',
            variant: 'secondary',
            icon: 'compare_arrows',
            onClick: () => appCubit.toggleCompared(id),
          ),
          ActionLink(
            'Why this score',
            href: '/entrepreneur/explanation?property=$id',
            variant: 'secondary',
          ),
        ]),
      ]),

      // Score.
      div(classes: 'rec-score', [
        strong([Component.text(prop.suitabilityScore.toStringAsFixed(0))]),
        span([Component.text('Suitability')]),
      ]),
    ]);
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Ranking properties…'),
  ]);
}

class _Empty extends StatelessComponent {
  const _Empty();

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'No recommendations yet',
    body:
        'Recommendations are generated from your saved preferences. Set them '
        'first, then run a search so there is something to rank.',
    action: const ActionLink(
      'Set your preferences',
      href: '/entrepreneur/preferences',
      variant: 'primary',
    ),
  );
}
