import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import 'provider_models.dart';
import 'provider_ui.dart';
import 'provider_workspace_service.dart';

/// My Listings — every record the signed-in provider may manage.
///
/// One shared screen for Owners and Agents. What differs between them is the
/// data the authorized endpoint returns (ownership vs assignment) and the
/// management block the backend derives per row; the UI never branches on
/// role except where the wording genuinely differs (the header subtitle).
///
/// Filtering and search are client-side over the already-authorized set: the
/// server decides which rows exist, so a filter can never widen access. The
/// filter chips and the Active stat card are computed over the same searched
/// set the list shows, so a count can never disagree with its results.
///
/// Performance honesty: SiteWise does not track views or saves (the backend
/// reports engagement `tracked: false`), so those slots show an explicit
/// unavailable state instead of a fabricated number. Enquiries are real
/// server rows grouped by property — and only when the fetch returned the
/// whole inbox (`returned == total`); a truncated inbox reports unavailable
/// rather than an undercount.
class ProviderListingsMobilePage extends ConsumerStatefulWidget {
  const ProviderListingsMobilePage({
    super.key,
    @visibleForTesting this.loadOverride,
    @visibleForTesting this.enquiriesOverride,
  });

  /// Test seam: replaces [ProviderListingsService.load] so a widget test can
  /// exercise the UI against fixture rows without faking the transport.
  final Future<ProviderWorkspace> Function(AppRole role)? loadOverride;

  /// Test seam: replaces the per-property enquiry grouping.
  final Future<Map<int, int>> Function()? enquiriesOverride;

  @override
  ConsumerState<ProviderListingsMobilePage> createState() =>
      _ProviderListingsMobilePageState();
}

class _ProviderListingsMobilePageState
    extends ConsumerState<ProviderListingsMobilePage> {
  Future<ProviderWorkspace>? _future;

  /// Per-property enquiry counts, or `null` when the counts cannot be trusted
  /// (failed fetch or a truncated inbox). Distinct from the listings future so
  /// a metrics hiccup never hides the listings themselves.
  Future<Map<int, int>?>? _enquiryCounts;

  /// The selected status chip. Kept as the enum, not a label, so renaming a
  /// chip cannot change which rows are shown.
  ProviderListingsFilter _filter = ProviderListingsFilter.all;
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<Map<int, int>?> _loadEnquiryCounts() async {
    if (widget.enquiriesOverride != null) {
      return widget.enquiriesOverride!();
    }
    // Asking for more rows than the inbox default; the completeness check
    // against `metrics.total` below decides whether the grouping is exact.
    final response = await ProviderWorkspaceService.enquiries(limit: 200);
    if (response.enquiries.length < response.metrics.total) {
      return null; // truncated: grouping would undercount some properties
    }
    final counts = <int, int>{};
    for (final enquiry in response.enquiries) {
      counts[enquiry.propertyId] = (counts[enquiry.propertyId] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> _load() async {
    final role = ref.read(authNotifierProvider).user?.role ?? AppRole.owner;
    final request = (widget.loadOverride ?? ProviderListingsService.load)(role);
    final counts = _loadEnquiryCounts();
    if (!mounted) return;
    // Block bodies are required: an arrow-bodied assignment returns the
    // Future itself, and Flutter's setState rejects that with a red screen.
    setState(() {
      _future = request;
      _enquiryCounts = counts;
    });
    await settleRefresh(request);
    await settleRefresh(counts);
  }

  void _open(String route, {Object? arguments}) {
    Navigator.of(context).pushNamed(route, arguments: arguments).then((_) {
      if (mounted) _load();
    });
  }

  void _openDetail(ProviderListing listing) =>
      _open('/provider/property-detail', arguments: listing.id);

  void _openEditor(ProviderListing listing) {
    if (ref.read(authNotifierProvider).user?.role == AppRole.agent) {
      // The agent editing workflow is the change-proposal sheet inside the
      // existing Property Details page — never a second editor.
      _openDetail(listing);
      return;
    }
    // The owner editing workflow is the existing Add Property form resuming
    // the saved draft; the backend still enforces what may change.
    _open('/provider/add-property', arguments: '${listing.id}');
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(authNotifierProvider.select((s) => s.user?.role));
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: _load,
      child: FutureBuilder<ProviderWorkspace>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              _future != null) {
            return providerLoadingView();
          }
          if (snapshot.hasError) {
            final error = snapshot.error!;
            return providerContent(
              children: [
                if (isMfaRequired(error))
                  ProviderMfaGate(onReload: _load)
                else
                  ProviderMessage(
                    title: 'Your listings could not be loaded',
                    body: '$error',
                    onRetry: _load,
                  ),
              ],
            );
          }
          if (!snapshot.hasData) {
            return providerLoadingView();
          }
          return _PageBody(
            scope: snapshot.data!,
            role: role,
            filter: _filter,
            query: _search.text,
            enquiryCounts: _enquiryCounts,
            onFilterChanged: (filter) => setState(() => _filter = filter),
            onSearchChanged: (text) => setState(() {}),
            onRetry: _load,
            onOpenDetail: _openDetail,
            onOpenEditor: _openEditor,
            searchController: _search,
          );
        },
      ),
    );
  }
}

class _PageBody extends StatelessWidget {
  const _PageBody({
    required this.scope,
    required this.role,
    required this.filter,
    required this.query,
    required this.enquiryCounts,
    required this.onFilterChanged,
    required this.onSearchChanged,
    required this.onRetry,
    required this.onOpenDetail,
    required this.onOpenEditor,
    required this.searchController,
  });

  final ProviderWorkspace scope;
  final AppRole? role;
  final ProviderListingsFilter filter;
  final String query;
  final Future<Map<int, int>?>? enquiryCounts;
  final ValueChanged<ProviderListingsFilter> onFilterChanged;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onRetry;
  final ValueChanged<ProviderListing> onOpenDetail;
  final ValueChanged<ProviderListing> onOpenEditor;
  final TextEditingController searchController;

  bool get isAgent => role == AppRole.agent || scope.isAgent;

  @override
  Widget build(BuildContext context) {
    final visible = providerVisibleListings(scope, filter, query);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, providerDockClearance),
      children: [
        _HeaderBanner(isAgent: isAgent),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: providerGutter),
          child: _StatCards(scope: scope),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: providerGutter),
          child: _SearchField(
            controller: searchController,
            onChanged: onSearchChanged,
          ),
        ),
        const SizedBox(height: 10),
        _FilterStrip(
          scope: scope,
          query: query,
          selected: filter,
          onSelect: onFilterChanged,
        ),
        const SizedBox(height: 6),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: providerGutter),
            child: _EmptyState(filter: filter, query: query, onRetry: onRetry),
          )
        else
          ...[
            for (final listing in visible)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  providerGutter,
                  6,
                  providerGutter,
                  6,
                ),
                child: ProviderListingCard(
                  listing: listing,
                  isAgentSession: isAgent,
                  enquiryCounts: enquiryCounts,
                  onOpen: () => onOpenDetail(listing),
                  onEdit: () => onOpenEditor(listing),
                ),
              ),
          ],
      ],
    );
  }
}

/// The gradient banner behind "My Listings".
///
/// Very light blue → white, with two soft decorative circles kept inside a
/// clipped stack so they can never cause horizontal overflow.
class _HeaderBanner extends StatelessWidget {
  const _HeaderBanner({required this.isAgent});

  final bool isAgent;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE3EDFD), SitewiseM3.paper],
          ),
        ),
        child: ClipRect(
          child: Stack(
            children: [
              Positioned(
                right: -46,
                top: -30,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ),
              Positioned(
                right: 64,
                bottom: -60,
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: SitewiseM3.quiet.withValues(alpha: 0.5),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(providerGutter, 18, providerGutter, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'My Listings',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 26,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        color: SitewiseM3.ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      isAgent
                          ? 'Manage properties assigned to you'
                          : 'Manage your owned and assigned properties',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color: SitewiseM3.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The two workspace statistics: Total and Active.
///
/// Both are computed from the loaded workspace — the Active figure IS the
/// Active chip's count, so the summary can never disagree with the filters.
class _StatCards extends StatelessWidget {
  const _StatCards({required this.scope});

  final ProviderWorkspace scope;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            icon: Icons.layers_rounded,
            value: scope.listings.length,
            label: 'Total Listings',
            iconBackground: SitewiseM3.quiet,
            iconColor: SitewiseColors.action,
            cardBackground: const Color(0xFFE9F1FD),
            semantics: 'Total listings: ${scope.listings.length}',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            icon: Icons.check_circle_rounded,
            value: scope.publishedCount,
            label: 'Active Listings',
            iconBackground: const Color(0xFFDCF3E4),
            iconColor: const Color(0xFF16A34A),
            cardBackground: const Color(0xFFEAF7EF),
            semantics: 'Active listings: ${scope.publishedCount}',
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.iconBackground,
    required this.iconColor,
    required this.cardBackground,
    required this.semantics,
  });

  final IconData icon;
  final int value;
  final String label;
  final Color iconBackground;
  final Color iconColor;
  final Color cardBackground;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semantics,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: cardBackground,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: iconBackground,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, size: 21, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$value',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 22,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                      color: SitewiseM3.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      keyboardType: TextInputType.text,
      autocorrect: false,
      enableSuggestions: true,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 13.5,
        color: SitewiseM3.ink,
      ),
      cursorColor: SitewiseColors.action,
      decoration: InputDecoration(
        hintText: 'Search by property name, location, or type',
        hintStyle: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: SitewiseM3.muted,
        ),
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 21,
          color: SitewiseM3.muted,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        filled: true,
        fillColor: providerSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: SitewiseM3.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: SitewiseM3.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: SitewiseColors.action, width: 1.4),
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: SitewiseM3.muted,
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
      ),
    );
  }
}

class _FilterStrip extends StatelessWidget {
  const _FilterStrip({
    required this.scope,
    required this.query,
    required this.selected,
    required this.onSelect,
  });

  final ProviderWorkspace scope;
  final String query;
  final ProviderListingsFilter selected;
  final ValueChanged<ProviderListingsFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final chips = providerListingsChips(scope, query);
    return Semantics(
      label: 'Listing status filters',
      child: SizedBox(
        height: 48,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: providerGutter),
          itemCount: chips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final (filter, label, count) = chips[index];
            final isOn = filter == selected;
            return _FilterPill(
              label: '$label ($count)',
              selected: isOn,
              onTap: () => onSelect(filter),
            );
          },
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Filter $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? SitewiseColors.action : SitewiseM3.surface,
            borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
            border: Border.all(
              color: selected ? SitewiseColors.action : SitewiseM3.line,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? SitewiseM3.surface : SitewiseM3.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty results. The wording distinguishes the three honest reasons a list
/// can be empty: nothing exists yet, the search matched nothing, or the
/// selected state matches nothing.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.filter,
    required this.query,
    required this.onRetry,
  });

  final ProviderListingsFilter filter;
  final String query;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    final (String title, String body, IconData icon) = switch ((
      searching,
      filter,
    )) {
      (true, _) => (
        'No properties match your search',
        'Try a different name, location or property type, or clear the search '
            'to see every listing you can manage.',
        Icons.search_off_rounded,
      ),
      (false, ProviderListingsFilter.all) => (
        'No listings yet',
        'Create a property draft to begin. Nothing is published until an '
            'administrator approves the submission.',
        Icons.storefront_outlined,
      ),
      (_, ProviderListingsFilter.assigned) => (
        'Nothing assigned right now',
        'No property in your portfolio is currently managed by an agent.',
        Icons.assignment_outlined,
      ),
      (_, _) => (
        'No ${filter.label.toLowerCase()} listings',
        'No listing currently sits in this state. Switch back to All to see '
            'the full set.',
        Icons.filter_list_rounded,
      ),
    };
    return ProviderMessage(icon: icon, title: title, body: body, onRetry: onRetry, retryLabel: 'Refresh');
  }
}

/// One property card, shared by Owner and Agent sessions.
class ProviderListingCard extends StatelessWidget {
  const ProviderListingCard({
    super.key,
    required this.listing,
    required this.isAgentSession,
    required this.enquiryCounts,
    required this.onOpen,
    required this.onEdit,
  });

  final ProviderListing listing;
  final bool isAgentSession;

  /// Future of per-property enquiry counts, or null when unavailable.
  final Future<Map<int, int>?>? enquiryCounts;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final canEditOwner = !isAgentSession && listing.locallyEditable;
    final canEdit = isAgentSession || canEditOwner;
    final editHint = isAgentSession
        ? 'Propose a change for this assigned listing'
        : switch (listing.stage) {
            ProviderStage.pending =>
              'Editing is locked while the listing awaits review',
            ProviderStage.approved =>
              'Published listings are locked; ask the administrator for changes',
            _ => 'Edit this listing',
          };
    return Semantics(
      label: '${listing.displayTitle}, $_statusText, ${listing.rentDisplay}',
      button: true,
      child: Container(
        decoration: BoxDecoration(
          color: SitewiseM3.surface,
          borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
          border: Border.all(color: SitewiseM3.line),
          boxShadow: [
            BoxShadow(
              color: SitewiseM3.ink.withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
          child: InkWell(
            borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TopSection(listing: listing),
                  const SizedBox(height: 12),
                  _MetricsRow(
                    listing: listing,
                    enquiryCounts: enquiryCounts,
                  ),
                  const SizedBox(height: 12),
                  _ActionsRow(
                    canEdit: canEdit,
                    editHint: editHint,
                    onOpen: onOpen,
                    onEdit: onEdit,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _statusText => listing.isActive
      ? 'Active'
      : listing.stage == ProviderStage.approved
      ? 'Approved'
      : listing.stage.label;
}

class _TopSection extends StatelessWidget {
  const _TopSection({required this.listing});

  final ProviderListing listing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Thumbnail(imageUrl: listing.imageUrl),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      listing.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 15.5,
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(listing: listing),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  const Icon(
                    Icons.location_on_outlined,
                    size: 14,
                    color: SitewiseM3.muted,
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(
                      listing.address.isEmpty
                          ? 'Address not set'
                          : listing.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        color: SitewiseM3.muted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      listing.rent == null
                          ? listing.rentDisplay
                          : 'RM $_rentWhole',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: SitewiseColors.action,
                      ),
                    ),
                  ),
                  if (listing.rent != null) ...[
                    const SizedBox(width: 3),
                    const Text(
                      '/ month',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: SitewiseM3.muted,
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  const SizedBox(
                    height: 14,
                    child: VerticalDivider(width: 1, color: SitewiseM3.line),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    _typeIcon(listing.propertyType),
                    size: 15,
                    color: SitewiseM3.ink,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      listing.propertyType?.trim().isNotEmpty ?? false
                          ? listing.propertyType!.trim()
                          : 'Type not set',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String get _rentWhole {
    final rent = listing.rent!;
    return rent == rent.roundToDouble()
        ? rent.round().toString()
        : rent.toStringAsFixed(0);
  }
}

IconData _typeIcon(String? type) {
  final value = (type ?? '').trim().toLowerCase();
  if (value.contains('retail') || value.contains('shop')) {
    return Icons.storefront_outlined;
  }
  if (value.contains('office')) return Icons.apartment_outlined;
  if (value.contains('restaurant') ||
      value.contains('cafe') ||
      value.contains('f&b') ||
      value.contains('food')) {
    return Icons.restaurant_outlined;
  }
  if (value.contains('industr') || value.contains('warehouse')) {
    return Icons.warehouse_outlined;
  }
  return Icons.location_city_rounded;
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 92,
        height: 78,
        child: url.isEmpty
            ? _placeholder(Icons.image_outlined)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(Icons.broken_image_outlined),
                // A thumbnail loads eagerly but small; keep the frame filled
                // while the network answers so the card never jumps.
                frameBuilder: (context, child, frame, wasSync) =>
                    wasSync || (frame ?? 0) > 0
                    ? child
                    : _placeholder(null),
              ),
      ),
    );
  }

  Widget _placeholder(IconData? icon) => Container(
    color: providerSoft,
    alignment: Alignment.center,
    child: Icon(
      icon ?? Icons.image_outlined,
      size: 22,
      color: SitewiseM3.muted,
    ),
  );
}

/// The listing status badge beside the title: soft tint, coloured dot and a
/// concise label from the backend's own status vocabulary.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.listing});

  final ProviderListing listing;

  (Color, Color, String) get _style => switch (listing.stage) {
    ProviderStage.pending => (
      SitewiseM3.amberWash,
      SitewiseM3.amber,
      'Pending',
    ),
    ProviderStage.draft => (providerSoft, const Color(0xFF5B6B80), 'Draft'),
    ProviderStage.rejected => (
      SitewiseColors.dangerWash,
      SitewiseColors.danger,
      'Rejected',
    ),
    ProviderStage.unknown => (providerSoft, SitewiseM3.muted, 'Unknown'),
    // Approved: green whether or not it is live yet; the label says which.
    _ => (
      SitewiseM3.greenWash,
      SitewiseM3.green,
      listing.isActive ? 'Active' : 'Approved',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (background, foreground, label) = _style;
    return Semantics(
      label: 'Listing status: $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: foreground,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Views / Enquiries / Saved, plus the management attribution.
///
/// Views and saves are NOT tracked by this backend (`engagement.tracked` is
/// false and no event store exists), so those slots render an explicit
/// unavailable state instead of a fabricated count. Enquiries show the real
/// per-property count only when the inbox fetch returned every row.
class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.listing, required this.enquiryCounts});

  final ProviderListing listing;
  final Future<Map<int, int>?>? enquiryCounts;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: SitewiseM3.line),
          bottom: BorderSide(color: SitewiseM3.line),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Metric(
              icon: Icons.visibility_outlined,
              value: null,
              label: 'Views',
              unavailableReason: 'Views are not tracked by SiteWise yet',
            ),
          ),
          const _MetricDivider(),
          Expanded(
            child: FutureBuilder<Map<int, int>?>(
              future: enquiryCounts,
              builder: (context, snapshot) {
                final counts = snapshot.data;
                final value = counts?[listing.id];
                return _Metric(
                  icon: Icons.chat_bubble_outline_rounded,
                  value: value,
                  label: 'Enquiries',
                  unavailableReason: snapshot.connectionState !=
                          ConnectionState.done
                      ? 'Enquiry count is loading'
                      : 'Enquiry count is unavailable right now',
                );
              },
            ),
          ),
          const _MetricDivider(),
          Expanded(
            child: _Metric(
              icon: Icons.bookmark_border_rounded,
              value: null,
              label: 'Saved',
              unavailableReason: 'Saved counts are not tracked by SiteWise yet',
            ),
          ),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 148),
            child: _ManagementBlock(listing: listing),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.value,
    required this.label,
    required this.unavailableReason,
  });

  final IconData icon;
  final int? value;
  final String label;
  final String unavailableReason;

  @override
  Widget build(BuildContext context) {
    final known = value != null;
    return Semantics(
      label: known ? '$label: $value' : '$label: unavailable — $unavailableReason',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 15, color: known ? SitewiseM3.ink : SitewiseM3.muted),
          const SizedBox(width: 6),
          Text(
            known ? '$value' : '—',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: known ? SitewiseM3.ink : SitewiseM3.muted,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: SitewiseM3.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 26,
    child: VerticalDivider(width: 14, color: SitewiseM3.line),
  );
}

class _ManagementBlock extends StatelessWidget {
  const _ManagementBlock({required this.listing});

  final ProviderListing listing;

  @override
  Widget build(BuildContext context) {
    final management = listing.management ?? ProviderManagement.unknown;
    final (Color pillBackground, Color pillForeground) = management.isAgent
        ? (SitewiseM3.quiet, SitewiseColors.action)
        : (SitewiseM3.quiet, SitewiseColors.action);
    final name = _nameLine(management);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_outline_rounded, size: 13, color: SitewiseColors.action),
            const SizedBox(width: 4),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: pillBackground,
                  borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                ),
                child: Text(
                  management.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: pillForeground,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: SitewiseM3.muted,
          ),
        ),
      ],
    );
  }

  /// The name line under the pill. An owner reading their own portfolio sees
  /// "You (Property Owner)"; an agent-managed row shows the backend-resolved
  /// agent name. A manager the backend could not name is reported as such
  /// rather than filled with a guess.
  String _nameLine(ProviderManagement management) {
    if (management.isOwner) return 'You (Property Owner)';
    final who = (management.name ?? '').trim();
    if (who.isNotEmpty) return who;
    return management.reason ?? 'Manager not named';
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    required this.canEdit,
    required this.editHint,
    required this.onOpen,
    required this.onEdit,
  });

  final bool canEdit;
  final String editHint;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.arrow_forward_rounded, size: 17),
            label: const Text('View details'),
            style: FilledButton.styleFrom(
              backgroundColor: SitewiseColors.action,
              foregroundColor: SitewiseM3.surface,
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              ),
              textStyle: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Tooltip(
            message: canEdit ? '' : editHint,
            triggerMode: TooltipTriggerMode.longPress,
            child: OutlinedButton.icon(
              onPressed: canEdit ? onEdit : null,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit'),
              style: OutlinedButton.styleFrom(
                foregroundColor: SitewiseColors.action,
                disabledForegroundColor: SitewiseM3.muted.withValues(alpha: 0.6),
                side: BorderSide(
                  color: canEdit
                      ? SitewiseColors.action
                      : SitewiseM3.line,
                ),
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                ),
                textStyle: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
