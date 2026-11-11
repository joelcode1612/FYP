import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';
import '../../widgets/mobile_property_image.dart';

/// Entrepreneur discovery — **Recommendations** (mobile).
///
/// Replaces the old "Listing" tab. The five-destination navigation is
/// unchanged: Home · Recommendations · Assess · Spaces · Profile.
///
/// All ranking comes from `POST /api/v1/recommendations/search` through the
/// shared [EntrepreneurNotifier]; this screen never sorts or filters locally
/// and never holds the whole catalogue. Pages are appended from the server's
/// cursor, and only the built rows exist in the widget tree
/// (`ListView.builder`).
///
/// Two honest states are load-bearing here:
///
///  * a requirement the catalogue cannot answer is shown as **not verified**,
///    not as failed;
///  * the PU research score is presented as its own model. It is never folded
///    into the requirement-fit figure, and "unavailable" is stated rather than
///    shown as zero.
class EntrepreneurRecommendationsMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurRecommendationsMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurRecommendationsMobilePage> createState() =>
      _EntrepreneurRecommendationsMobilePageState();
}

class _EntrepreneurRecommendationsMobilePageState
    extends ConsumerState<EntrepreneurRecommendationsMobilePage> {
  final ScrollController _scroll = ScrollController();
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // The notifier publishes synchronously; kicking it from initState would
    // modify the provider while the tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _seeded) return;
      _seeded = true;
      final prefs = ref.read(businessPreferencesProvider);
      ref
          .read(entrepreneurNotifierProvider.notifier)
          .searchRecommendations(request: _initialRequest(prefs));
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Fetches the next page shortly before the list bottom is reached, so the
  /// user does not have to tap "Load more" on every page — but a tap still
  /// works, and the notifier deduplicates concurrent requests.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining > 480) return;
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    if (!notifier.recommendationHasMore || notifier.recommendationRefreshing) {
      return;
    }
    notifier.loadMoreRecommendations();
  }

  /// A brand-new account has no saved requirements: deriving a request from
  /// placeholder defaults would attach "within RM25,000" to every card as if
  /// the user had asked for it. Unconfigured accounts get a plain browse.
  RecommendationSearchRequest _initialRequest(BusinessPreferences prefs) {
    final configured =
        prefs.businessType.trim().isNotEmpty ||
        prefs.preferredLocation.trim().isNotEmpty ||
        prefs.preferredAreas.isNotEmpty;
    return configured
        ? RecommendationSearchRequest.fromPreferences(prefs)
        : const RecommendationSearchRequest();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(entrepreneurNotifierProvider);
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    final saved = ref.watch(appNotifierProvider.select((app) => app.saved));
    final compared = ref.watch(
      appNotifierProvider.select((app) => app.compared),
    );

    // The five-tab host keeps this page alive, so a preference edit on Profile
    // never re-ran the search: the tab kept the previous ranking until the app
    // restarted. `onPreferencesUpdated` invalidates the provider, so listening
    // to it is the re-entry signal — and it fires only on a real edit, not on
    // every rebuild.
    ref.listen<BusinessPreferences>(businessPreferencesProvider, (
      previous,
      next,
    ) {
      if (previous == null) return;
      notifier.searchRecommendations(request: _initialRequest(next));
    });

    return MobileAppShell(
      title: 'Recommendations',
      currentRoute: '/entrepreneur/recommendations',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: () => notifier.searchRecommendations(),
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          // header + rows + (footer | empty | loading | error)
          itemCount: 1 + state.ranked.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _header(state, notifier);
            final rowIndex = index - 1;
            if (rowIndex < state.ranked.length) {
              final item = state.ranked[rowIndex];
              return _RecommendationCard(
                item: item,
                isSaved: saved.contains(item.id),
                isCompared: compared.contains(item.id),
                isSelected: item.id == state.selectedRankedId,
                onOpen: () => _openInsight(item),
                onSave: () => _toggleSaved(item.id),
                onCompare: () =>
                    ref.read(appNotifierProvider.notifier).toggleCompared(item.id),
              );
            }
            return _footer(state, notifier);
          },
        ),
      ),
    );
  }

  // -- header ---------------------------------------------------------------

  Widget _header(EntrepreneurState state, EntrepreneurNotifier notifier) {
    final prefs = state.preferences;
    final total = state.recommendationTotal;
    final model = state.recommendationModel;
    final criteria = _criteriaSummary(prefs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const M3ScreenHeading(
          eyebrow: 'Find a space that fits your vision',
          title: 'Recommendations',
          lead: 'Ranked commercial properties for your business.',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: SitewiseColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SitewiseColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Your requirements',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .4,
                        color: SitewiseColors.muted,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(
                      '/entrepreneur/ai-recommendations',
                    ),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                    label: const Text('AI matches'),
                    style: TextButton.styleFrom(
                      foregroundColor: SitewiseColors.action,
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _openFilters(state),
                    icon: const Icon(Icons.tune_rounded, size: 16),
                    label: const Text('Edit'),
                    style: TextButton.styleFrom(
                      foregroundColor: SitewiseColors.action,
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                criteria,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: SitewiseColors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                total == null
                    ? 'Ranked properties'
                    : '$total ${total == 1 ? 'property' : 'properties'}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                ),
              ),
            ),
            if (state.recommendationRefreshing)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        if (model != null) ...[
          const SizedBox(height: 4),
          Text(
            model.available
                ? 'Experimental preference match'
                      '${model.version == null ? '' : ' · ${model.version}'}'
                : 'Ordered by requirement fit — model score unavailable',
            style: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  String _criteriaSummary(BusinessPreferences prefs) {
    if (prefs.businessType.trim().isEmpty &&
        prefs.preferredLocation.trim().isEmpty &&
        prefs.maxBudgetRm <= 0) {
      return 'No requirements set — showing every published catalogue '
          'property. Tap Edit to rank by budget, size and location.';
    }
    return [
      if (prefs.businessType.trim().isNotEmpty) prefs.businessType,
      if (prefs.preferredLocation.trim().isNotEmpty) prefs.preferredLocation,
      if (prefs.maxBudgetRm > 0)
        'up to RM${prefs.maxBudgetRm.toStringAsFixed(0)}/mo',
      if (prefs.minSizeSqft > 0)
        'min ${prefs.minSizeSqft.toStringAsFixed(0)} sq ft',
    ].join(' · ');
  }

  // -- footer states --------------------------------------------------------

  Widget _footer(EntrepreneurState state, EntrepreneurNotifier notifier) {
    if (state.recommendationLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
      );
    }
    if (state.recommendationError != null) {
      return _ErrorBlock(
        message: state.recommendationError!,
        onRetry: () => notifier.searchRecommendations(),
      );
    }
    if (state.ranked.isEmpty) {
      return M3EmptyState(
        icon: Icons.search_off_rounded,
        title: state.recommendationRequest.isBrowseOnly
            ? 'No properties available'
            : 'Nothing matches these requirements',
        message: state.recommendationRequest.isBrowseOnly
            ? 'The catalogue returned no listings. This is a data condition, '
                  'not a filter problem.'
            : 'Widen the budget or reduce the minimum floor area, then search '
                  'again.',
        actionLabel: 'Clear filters',
        onAction: () => notifier.applyRecommendationRequest(
          const RecommendationSearchRequest(),
        ),
      );
    }
    return Column(
      children: [
        const SizedBox(height: 8),
        if (state.recommendationHasMore)
          TextButton(
            onPressed: state.recommendationRefreshing
                ? null
                : () => notifier.loadMoreRecommendations(),
            child: Text(
              state.recommendationRefreshing ? 'Loading…' : 'Load more',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.action,
              ),
            ),
          )
        else
          const Text(
            'End of results',
            style: TextStyle(fontSize: 11, color: SitewiseColors.muted),
          ),
        const SizedBox(height: 6),
        const Text(
          'Requirement fit is not a probability of business success. The PU '
          'research score is a separate model and is shown separately.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.5,
            height: 1.5,
            color: SitewiseColors.muted,
          ),
        ),
      ],
    );
  }

  // -- actions --------------------------------------------------------------

  Future<void> _toggleSaved(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final wantSaved = !ref.read(appNotifierProvider).saved.contains(id);
    // Server first: the Saved tab reads the account's shortlist, so a purely
    // local toggle would look saved here and then be missing there.
    final failure = await ref
        .read(appNotifierProvider.notifier)
        .persistSaved(id, wantSaved: wantSaved);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failure ??
              (wantSaved
                  ? 'Saved to your shortlist.'
                  : 'Removed from saved.'),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openInsight(RankedProperty item) {
    ref.read(entrepreneurNotifierProvider.notifier).selectRanked(item.id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _InsightSheet(item: item),
    );
  }

  Future<void> _openFilters(EntrepreneurState state) async {
    final request = await showModalBottomSheet<RecommendationSearchRequest>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _FilterSheet(
        initial: state.recommendationRequest,
        facets: state.recommendationFacets,
      ),
    );
    if (request == null || !mounted) return;
    ref
        .read(entrepreneurNotifierProvider.notifier)
        .applyRecommendationRequest(request);
  }
}

/// One ranked result: photograph, facts, requirement chips and the two
/// toggles. Tapping the card opens the insight sheet.
class _RecommendationCard extends StatelessWidget {
  final RankedProperty item;
  final bool isSaved;
  final bool isCompared;
  final bool isSelected;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onCompare;

  const _RecommendationCard({
    required this.item,
    required this.isSaved,
    required this.isCompared,
    required this.isSelected,
    required this.onOpen,
    required this.onSave,
    required this.onCompare,
  });

  @override
  Widget build(BuildContext context) {
    final prop = item.property;
    final match = item.match;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isSelected
                    ? SitewiseColors.action
                    : SitewiseColors.border,
                width: isSelected ? 1.6 : 1,
              ),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    MobilePropertyImage(
                      property: prop,
                      height: 140,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _RankBadge(rank: match.rank),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _IconToggle(
                        icon: isSaved ? Icons.bookmark : Icons.bookmark_border,
                        active: isSaved,
                        label: isSaved ? 'Remove from saved' : 'Save property',
                        onTap: onSave,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Text(
                  prop.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    height: 1.3,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (prop.city.isNotEmpty) prop.city,
                    if (prop.state.isNotEmpty) prop.state,
                    if (prop.propertyType.isNotEmpty) prop.propertyType,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: SitewiseColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _Fact(
                      label: 'Rent',
                      value: 'RM ${prop.rentalRm.toStringAsFixed(0)}/mo',
                    ),
                    const SizedBox(width: 16),
                    _Fact(
                      label: 'Floor area',
                      value: '${prop.sizeSqft.toStringAsFixed(0)} sq ft',
                    ),
                    const Spacer(),
                    _FitBadge(match: match),
                  ],
                ),
                if (match.matched.isNotEmpty || match.unmatched.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final reason in match.matched.take(3))
                        _ReasonChip(label: reason.label, met: true),
                      for (final reason in match.unmatched.take(2))
                        _ReasonChip(label: reason.label, met: false),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                // The action row is width-bounded: "Insight" + "In compare" +
                // "Details" is a hair wider than a 390dp phone at some text
                // scales, so the two icon actions live in an Expanded Wrap and
                // drop to a second line instead of overflowing the card.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          _InlineAction(
                            icon: Icons.insights_rounded,
                            label: 'Insight',
                            onTap: onOpen,
                          ),
                          _InlineAction(
                            icon: isCompared
                                ? Icons.check_circle_outline
                                : Icons.compare_arrows_rounded,
                            label: isCompared ? 'In compare' : 'Compare',
                            onTap: onCompare,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pushNamed(
                        '/entrepreneur/property-detail',
                        arguments: prop.id,
                      ),
                      child: const Text(
                        'Details',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: SitewiseColors.action,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full intelligence for one listing: requirement-by-requirement verdict,
/// listing facts, then the PU model kept visibly separate.
class _InsightSheet extends StatelessWidget {
  final RankedProperty item;

  const _InsightSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    final prop = item.property;
    final match = item.match;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .82,
      maxChildSize: .95,
      minChildSize: .5,
      builder: (context, controller) => ListView(
        // Stable key: the sheet is lazily built, so tests (and any future
        // scroll-to-section affordance) need a deterministic handle on it.
        key: const ValueKey('insight-sheet-scroll'),
        controller: controller,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SitewiseColors.borderStrong,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            prop.title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              height: 1.3,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [prop.address, prop.city, prop.state]
                .where((v) => v.isNotEmpty)
                .join(', '),
            style: const TextStyle(
              fontSize: 12,
              height: 1.45,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          MobilePropertyImage(
            property: prop,
            height: 170,
            borderRadius: BorderRadius.circular(14),
          ),
          const SizedBox(height: 16),
          _SectionLabel(
            match.available ? 'Recommendation match' : 'Requirement fit',
          ),
          if (match.fitSummary != null)
            Text(
              match.fitSummary!,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
          if (!match.available && match.reason != null) ...[
            const SizedBox(height: 4),
            Text(
              match.reason!,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: SitewiseColors.muted,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (match.matched.isNotEmpty)
            _RequirementGroup(
              title: 'Met',
              items: match.matched,
              color: SitewiseColors.success,
            ),
          if (match.unmatched.isNotEmpty)
            _RequirementGroup(
              title: 'Not met',
              items: match.unmatched,
              color: SitewiseColors.danger,
            ),
          if (match.unverified.isNotEmpty)
            _RequirementGroup(
              title: 'Cannot be verified from the catalogue',
              items: match.unverified,
              color: SitewiseColors.muted,
            ),
          if (match.matched.isEmpty &&
              match.unmatched.isEmpty &&
              match.unverified.isEmpty)
            const Text(
              'No requirements were applied — this is a plain catalogue '
              'browse. Set your requirements to rank by fit.',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: SitewiseColors.muted,
              ),
            ),
          const SizedBox(height: 16),
          const _SectionLabel('Listing facts'),
          _SheetRow('Monthly rental', 'RM ${prop.rentalRm.toStringAsFixed(0)}'),
          _SheetRow('Floor area', '${prop.sizeSqft.toStringAsFixed(0)} sq ft'),
          _SheetRow('Property type', prop.propertyType),
          _SheetRow(
            'Research index',
            item.suitabilityAvailable
                ? '${item.catalogSuitabilityScore!.toStringAsFixed(1)} / 100'
                : 'Not available',
          ),
          const SizedBox(height: 16),
          // Separate model, separate block, never merged into the fit figure.
          const _SectionLabel('PU research association'),
          Text(
            item.puAvailable == true
                ? 'PU association: ${item.puScore?.toStringAsFixed(1) ?? '—'} '
                      '(research index, not a success probability).'
                : 'The PU research model returned no association score for this '
                      'property. It is a separate research model and is never '
                      'folded into the requirement-fit result above.',
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 18),
          M3PrimaryButton(
            label: 'View property',
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).pushNamed(
                '/entrepreneur/property-detail',
                arguments: prop.id,
              );
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pushNamed(
                '/entrepreneur/assessment-setup',
                arguments: prop.id,
              );
            },
            icon: const Icon(Icons.assignment_outlined, size: 18),
            label: const Text('Assess this property'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: SitewiseColors.action,
              side: const BorderSide(color: SitewiseColors.borderStrong),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Requirement search form. Returns the request to run, or null on dismiss.
class _FilterSheet extends StatefulWidget {
  final RecommendationSearchRequest initial;
  final RecommendationFacets? facets;

  const _FilterSheet({required this.initial, this.facets});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final TextEditingController _budget = TextEditingController(
    text: widget.initial.maxRentalRm?.toStringAsFixed(0) ?? '',
  );
  late final TextEditingController _minSize = TextEditingController(
    text: widget.initial.minSizeSqft?.toStringAsFixed(0) ?? '',
  );
  late final TextEditingController _query = TextEditingController(
    text: widget.initial.query ?? '',
  );
  late String _state = widget.initial.preferredState ?? '';
  late String _type = widget.initial.propertyType ?? '';

  @override
  void dispose() {
    _budget.dispose();
    _minSize.dispose();
    _query.dispose();
    super.dispose();
  }

  void _apply() {
    Navigator.of(context).pop(
      RecommendationSearchRequest(
        preferredState: _state.isEmpty ? null : _state,
        propertyType: _type.isEmpty ? null : _type,
        maxRentalRm: double.tryParse(_budget.text.trim()),
        minSizeSqft: double.tryParse(_minSize.text.trim()),
        query: _query.text.trim().isEmpty ? null : _query.text.trim(),
        pageSize: 20,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final facets = widget.facets;
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 22,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SitewiseColors.borderStrong,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Your requirements',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'These are sent to the server, which filters and ranks. Nothing '
              'is sorted on this device.',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: SitewiseColors.muted,
              ),
            ),
            const SizedBox(height: 16),
            if (facets != null && facets.states.isNotEmpty) ...[
              const _SectionLabel('Preferred state'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final option in [
                    const FacetOption(value: ''),
                    ...facets.states,
                  ])
                    _ChoiceChip(
                      label: option.value.isEmpty ? 'Any' : option.value,
                      selected: option.value == _state,
                      onTap: () => setState(() => _state = option.value),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (facets != null && facets.propertyTypes.isNotEmpty) ...[
              const _SectionLabel('Property type'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final option in [
                    const FacetOption(value: ''),
                    ...facets.propertyTypes,
                  ])
                    _ChoiceChip(
                      label: option.value.isEmpty ? 'Any' : option.value,
                      selected: option.value == _type,
                      onTap: () => setState(() => _type = option.value),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            _SheetField(
              label: 'Monthly budget (RM)',
              controller: _budget,
              hint: 'e.g. 8000',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            _SheetField(
              label: 'Minimum floor area (sq ft)',
              controller: _minSize,
              hint: 'e.g. 1200',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            _SheetField(
              label: 'Search',
              controller: _query,
              hint: 'Area, title or property id',
            ),
            const SizedBox(height: 18),
            M3PrimaryButton(label: 'Find properties', onTap: _apply),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                const RecommendationSearchRequest(),
              ),
              child: const Text(
                'Clear all requirements',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: SitewiseColors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -- small building blocks ---------------------------------------------------

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        letterSpacing: .7,
        color: SitewiseColors.muted,
      ),
    ),
  );
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: .6,
          color: SitewiseColors.muted,
        ),
      ),
      Text(
        value,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          color: SitewiseColors.ink,
        ),
      ),
    ],
  );
}

class _RankBadge extends StatelessWidget {
  final int rank;

  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xCC0B0F19),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      '#$rank',
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        color: Colors.white,
      ),
    ),
  );
}

class _FitBadge extends StatelessWidget {
  final RecommendationMatch match;

  const _FitBadge({required this.match});

  @override
  Widget build(BuildContext context) {
    final hasCriteria = match.verifiableCount > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: hasCriteria
            ? SitewiseColors.infoWash
            : SitewiseColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SitewiseColors.borderStrong),
      ),
      child: Column(
        children: [
          Text(
            hasCriteria
                ? '${match.matchedCount}/${match.verifiableCount}'
                : '—',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            ),
          ),
          Text(
            hasCriteria ? 'met' : 'no criteria',
            style: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              letterSpacing: .3,
              color: SitewiseColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasonChip extends StatelessWidget {
  final String label;
  final bool met;

  const _ReasonChip({required this.label, required this.met});

  @override
  Widget build(BuildContext context) {
    final color = met ? SitewiseColors.success : SitewiseColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: met ? SitewiseColors.successWash : SitewiseColors.dangerWash,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(met ? Icons.check_rounded : Icons.close_rounded, size: 12, color: color),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _InlineAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 15, color: SitewiseColors.action),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.action,
            ),
          ),
        ],
      ),
    ),
  );
}

class _IconToggle extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;

  const _IconToggle({
    required this.icon,
    required this.active,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: const Color(0xCCFFFFFF),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        // 48x48 touch target.
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 19,
            color: active ? SitewiseColors.action : SitewiseColors.ink,
          ),
        ),
      ),
    ),
  );
}

class _RequirementGroup extends StatelessWidget {
  final String title;
  final List<RequirementMatch> items;
  final Color color;

  const _RequirementGroup({
    required this.title,
    required this.items,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: .4,
            color: color,
          ),
        ),
        const SizedBox(height: 3),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  item.isMet
                      ? Icons.check_rounded
                      : item.isUnmet
                      ? Icons.close_rounded
                      : Icons.help_outline_rounded,
                  size: 13,
                  color: color,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    item.label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: SitewiseColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _SheetRow extends StatelessWidget {
  final String label;
  final String value;

  const _SheetRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
          ),
        ),
        Text(
          value.isEmpty ? 'Not recorded' : value,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
      ],
    ),
  );
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(999),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? SitewiseColors.action : SitewiseColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? SitewiseColors.action : SitewiseColors.borderStrong,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: selected ? Colors.white : SitewiseColors.ink,
        ),
      ),
    ),
  );
}

class _SheetField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;

  const _SheetField({
    required this.label,
    required this.controller,
    required this.hint,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: .3,
          color: SitewiseColors.muted,
        ),
      ),
      const SizedBox(height: 5),
      TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 13, color: SitewiseColors.ink),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: SitewiseColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 13,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: SitewiseColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: SitewiseColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: SitewiseColors.action, width: 1.6),
          ),
        ),
      ),
    ],
  );
}

class _ErrorBlock extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBlock({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: Column(
      children: [
        Icon(Icons.cloud_off_rounded, size: 30, color: SitewiseColors.muted),
        const SizedBox(height: 8),
        const Text(
          'Could not load recommendations',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.45,
            color: SitewiseColors.muted,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 17),
          label: const Text('Retry'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(140, 44),
            foregroundColor: SitewiseColors.action,
            side: const BorderSide(color: SitewiseColors.borderStrong),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );
}
