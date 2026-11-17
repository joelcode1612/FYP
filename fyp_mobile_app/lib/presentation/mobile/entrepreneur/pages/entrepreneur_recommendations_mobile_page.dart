import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';
import '../../widgets/mobile_property_gallery.dart';
import '../../widgets/mobile_property_image.dart';

/// Entrepreneur discovery — **Recommendations** (mobile).
///
/// Replaces the old "Listing" tab. The five-destination navigation is
/// unchanged: Home · Recommendations · Assess · Favourites · Profile.
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
              return RecommendationCard(
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
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .3,
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
              const SizedBox(height: 6),
              _requirementsGrid(prefs),
              if (prefs.businessType.trim().isEmpty &&
                  prefs.preferredLocation.trim().isEmpty &&
                  prefs.maxBudgetRm <= 0 &&
                  prefs.minSizeSqft <= 0) ...[
                const SizedBox(height: 8),
                const Text(
                  'No requirements set yet — every eligible listing is '
                  'shown. Tap Edit to set your business, location, budget '
                  'and space.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: SitewiseColors.text,
                  ),
                ),
              ],
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
                  fontSize: 15,
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
          // Entrepreneur-facing wording only. The internal model identifier
          // and version stay in `state.recommendationModel` for diagnostics
          // and are deliberately never rendered here.
          Text(
            model.available
                ? 'Ranked by how well each property fits your requirements.'
                : 'Ordered by requirement fit — the research score is '
                      'unavailable for this browse.',
            style: const TextStyle(
              fontSize: 14,
              height: 1.35,
              color: SitewiseColors.muted,
            ),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  /// The four requirements, each as a labelled value. Values stay readable
  /// even when nothing is configured ("Any location" is a statement, not an
  /// empty gap).
  Widget _requirementsGrid(BusinessPreferences prefs) {
    Widget field(String label, String value) => _RequirementField(
      label: label,
      value: value,
    );
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: field(
                'Business',
                prefs.businessType.trim().isEmpty
                    ? 'Any F&B business'
                    : prefs.businessType.trim(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: field(
                'Location',
                prefs.preferredLocation.trim().isEmpty
                    ? 'Anywhere'
                    : prefs.preferredLocation.trim(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: field(
                'Budget',
                prefs.maxBudgetRm > 0
                    ? 'Up to ${_ringgitPerMonth(prefs.maxBudgetRm)}'
                    : 'Any budget',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: field(
                'Minimum space',
                prefs.minSizeSqft > 0
                    ? 'From ${_squareFeet(prefs.minSizeSqft)}'
                    : 'Any size',
              ),
            ),
          ],
        ),
      ],
    );
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
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: SitewiseColors.muted,
            ),
          ),
        const SizedBox(height: 6),
        const Text(
          'Requirement fit is not a probability of business success. The PU '
          'research score is a separate model and is shown separately.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
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
    // Server first: the Favourites tab reads the account's saved list, so a
    // purely local toggle would look saved here and be missing there.
    final failure = await ref
        .read(appNotifierProvider.notifier)
        .persistSaved(id, wantSaved: wantSaved);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failure ??
              (wantSaved
                  ? 'Added to favourites.'
                  : 'Removed from favourites.'),
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

/// One labelled requirement cell inside the header card.
class _RequirementField extends StatelessWidget {
  final String label;
  final String value;

  const _RequirementField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: SitewiseColors.muted,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.ink,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

/// One ranked result: full-width 16:9 media (swipeable photo gallery with
/// rank, bookmark, counter and a 360° action only when the backend verified
/// a ready panorama), clearly separated rent/area metrics, the requirement
/// verdict in plain wording, and the three aligned actions. Tapping the
/// card body opens the insight sheet.
class RecommendationCard extends StatelessWidget {
  final RankedProperty item;
  final bool isSaved;
  final bool isCompared;
  final bool isSelected;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onCompare;

  const RecommendationCard({
    super.key,
    required this.item,
    required this.isSaved,
    required this.isCompared,
    required this.isSelected,
    required this.onOpen,
    required this.onSave,
    required this.onCompare,
  });

  void _openPanorama(BuildContext context) {
    final url = item.panoramaUrl;
    if (url == null) return;
    Navigator.of(context).pushNamed(
      '/entrepreneur/panorama',
      arguments: {'url': url, 'title': item.property.title},
    );
  }

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MobilePropertyGallery(
                  property: prop,
                  urls: prop.imageUrls,
                  rankBadge: _RankBadge(rank: match.rank),
                  bookmarkButton: _IconToggle(
                    icon: isSaved ? Icons.bookmark : Icons.bookmark_border,
                    active: isSaved,
                    label: isSaved
                        ? 'Remove from favourites'
                        : 'Save property',
                    onTap: onSave,
                  ),
                  // Only a backend-verified ready panorama earns this action.
                  // An ordinary wide photo is never presented as 360°.
                  tourAction: item.hasPanorama
                      ? _PanoramaAction(
                          onTap: () => _openPanorama(context),
                          label: prop.title,
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        prop.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          height: 1.3,
                          color: SitewiseColors.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (prop.city.isNotEmpty) prop.city,
                          if (prop.state.isNotEmpty) prop.state,
                          if (prop.propertyType.isNotEmpty) prop.propertyType,
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          color: SitewiseColors.text,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _Metric(
                              label: 'Monthly rent',
                              value: _ringgitPerMonth(prop.rentalRm),
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 42,
                            color: SitewiseColors.border,
                          ),
                          Expanded(
                            child: _Metric(
                              label: 'Floor area',
                              value: _squareFeet(prop.sizeSqft),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _RequirementVerdict(match: match),
                      if (match.matched.isNotEmpty ||
                          match.unmatched.isNotEmpty) ...[
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
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: _CardActionButton(
                              label: 'View Details',
                              icon: Icons.arrow_forward_rounded,
                              primary: true,
                              onTap: () => Navigator.of(context).pushNamed(
                                '/entrepreneur/property-detail',
                                arguments: prop.id,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: _CardActionButton(
                              label: 'Insights',
                              icon: Icons.insights_rounded,
                              onTap: onOpen,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: _CardActionButton(
                              label: isCompared ? 'In compare' : 'Compare',
                              icon: isCompared
                                  ? Icons.check_circle_outline
                                  : Icons.compare_arrows_rounded,
                              onTap: onCompare,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Emphasised value over its label — rent and floor area read as two
/// clearly separated metrics, never squeezed into one grey line.
class _Metric extends StatelessWidget {
  final String label;
  final String value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: SitewiseColors.muted,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
              height: 1.25,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// The recommendation result in understandable wording. Colour never carries
/// the meaning alone — every state pairs a distinct icon with a full
/// sentence, and "nothing to verify" says exactly what is missing instead
/// of showing a bare `no criteria` pill.
class _RequirementVerdict extends StatelessWidget {
  final RecommendationMatch match;

  const _RequirementVerdict({required this.match});

  @override
  Widget build(BuildContext context) {
    final verifiable = match.verifiableCount > 0;
    final (icon, color) = verifiable
        ? (Icons.verified_rounded, SitewiseColors.success)
        : (Icons.info_outline_rounded, SitewiseColors.muted);
    return Semantics(
      label: verifiable
          ? 'Meets ${match.matchedCount} of ${match.verifiableCount} '
              'of your requirements'
          : 'Requirement fit is not available yet',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              verifiable
                  ? 'Meets ${match.matchedCount} of ${match.verifiableCount} '
                        'of your requirements.'
                  : 'Fit not verified yet — set your business requirements '
                        'to see how well this listing matches them.',
              style: TextStyle(
                fontSize: 14,
                height: 1.35,
                fontWeight: verifiable ? FontWeight.w700 : FontWeight.w500,
                color: verifiable
                    ? SitewiseColors.ink
                    : SitewiseColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `360° View` pill over the media. Rendered ONLY when the backend reported
/// a ready, verified panorama for this property.
class _PanoramaAction extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const _PanoramaAction({required this.onTap, required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open 360° panorama view of $label',
      child: Material(
        color: SitewiseColors.ink.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: const SizedBox(
            height: 44,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.threesixty_rounded,
                    size: 19,
                    color: Colors.white,
                  ),
                  SizedBox(width: 6),
                  Text(
                    '360° View',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One aligned card action, at least 44dp tall. Labels scale down instead
/// of clipping when the system text size grows.
class _CardActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback onTap;

  const _CardActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = primary ? SitewiseColors.action : SitewiseColors.ink;
    return SizedBox(
      height: 46,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor:
              primary ? SitewiseColors.action : SitewiseColors.surface,
          foregroundColor: color,
          side: primary
              ? null
              : const BorderSide(color: SitewiseColors.borderStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.standard,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 17),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// `RM 7,500/mo` — thousands grouped, no dangling decimals.
String _ringgitPerMonth(double amount) {
  final rounded = amount.round();
  final digits = rounded.abs().toString();
  final grouped = StringBuffer(rounded < 0 ? '-RM ' : 'RM ');
  for (var i = 0; i < digits.length; i++) {
    grouped.write(digits[i]);
    final remaining = digits.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) grouped.write(',');
  }
  grouped.write('/mo');
  return grouped.toString();
}

/// `1,760 sq ft` with the same grouping.
String _squareFeet(double size) {
  final rounded = size.round();
  final digits = rounded.abs().toString();
  final grouped = StringBuffer(rounded < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    grouped.write(digits[i]);
    final remaining = digits.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) grouped.write(',');
  }
  grouped.write(' sq ft');
  return grouped.toString();
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
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: .7,
        color: SitewiseColors.muted,
      ),
    ),
  );
}

class _RankBadge extends StatelessWidget {
  final int rank;

  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xCC0B0F19),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      '#$rank',
      semanticsLabel: 'Rank $rank',
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        color: Colors.white,
      ),
    ),
  );
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
                fontSize: 12,
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
        // 44x44: the accessibility floor for a touch target.
        child: SizedBox(
          width: 44,
          height: 44,
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
