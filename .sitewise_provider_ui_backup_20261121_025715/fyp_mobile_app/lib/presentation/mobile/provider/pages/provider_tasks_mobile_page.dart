import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../widgets/m3_kit.dart';
import '../shell/provider_tab_scope.dart';
import 'provider_dashboard_controller.dart';
import 'provider_models.dart' show isMfaRequired;
import 'provider_ui.dart';

/// The Agent task queue — `/provider/tasks`.
///
/// This screen holds no data of its own. It renders
/// [providerDashboardProvider], the same bundle the Agent Home reads, so the
/// "Tasks requiring attention" strip on Home and the list here are two views
/// of one classification — never two rules that can drift apart.
///
/// A task exists only because an assigned property is in a state that asks for
/// something. Nothing is invented: no deadline (SiteWise records none), no
/// viewing appointment, no self-assigned work, and no task created merely
/// because a property was approved. Properties that are locked for review are
/// shown as tracked, with a status view instead of an edit, because the
/// backend refuses edits while an administrator holds the submission.
class ProviderTasksMobilePage extends ConsumerStatefulWidget {
  const ProviderTasksMobilePage({super.key});

  @override
  ConsumerState<ProviderTasksMobilePage> createState() =>
      _ProviderTasksMobilePageState();
}

/// The four filters §4 of the workspace asks for. `all` shows every section at
/// once; the rest narrow to one.
enum _TaskFilter {
  all('All'),
  needsAttention('Needs attention'),
  awaitingReview('Awaiting review'),
  approved('Approved');

  const _TaskFilter(this.label);
  final String label;
}

class _ProviderTasksMobilePageState
    extends ConsumerState<ProviderTasksMobilePage> {
  _TaskFilter _filter = _TaskFilter.all;

  void _reload() => ref.invalidate(providerDashboardProvider);

  /// Tab routes stay inside the shell; anything else is a drill-in. The task
  /// cards point at the existing listing screen, which is where each role's
  /// authorized action already lives.
  void _open(String route, {Object? arguments}) {
    final scope = ProviderTabScope.maybeOf(context);
    if (scope != null && scope.handlesRoute(route)) {
      scope.go(route, arguments: arguments);
      return;
    }
    Navigator.of(context).pushNamed(route, arguments: arguments);
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = ref.watch(providerDashboardProvider);
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: () async => settleRefresh(
        ref.refresh(providerDashboardProvider.future),
      ),
      child: dashboard.when(
        skipLoadingOnRefresh: true,
        loading: providerLoadingView,
        error: (error, _) => providerContent(
          children: [
            if (isMfaRequired(error))
              ProviderMfaGate(onReload: _reload)
            else
              ProviderMessage(
                title: 'Your tasks could not be loaded',
                body:
                    '$error Your assigned properties are unchanged; this is a '
                    'read failure, not a missing submission.',
                onRetry: _reload,
              ),
          ],
        ),
        data: (data) => _TasksBody(
          data: data,
          filter: _filter,
          onFilterChanged: (filter) => setState(() => _filter = filter),
          onOpen: _open,
        ),
      ),
    );
  }
}

class _TasksBody extends StatelessWidget {
  const _TasksBody({
    required this.data,
    required this.filter,
    required this.onFilterChanged,
    required this.onOpen,
  });

  final ProviderDashboardData data;
  final _TaskFilter filter;
  final ValueChanged<_TaskFilter> onFilterChanged;
  final void Function(String route, {Object? arguments}) onOpen;

  List<ProviderAgentTask> _of(ProviderAgentTaskKind kind) =>
      data.agentTasks.where((task) => task.kind == kind).toList();

  /// Whether one bucket is visible under the current filter. An empty bucket
  /// is never shown, so a filter can only ever narrow what the records
  /// actually contain.
  bool _shows(ProviderAgentTaskKind kind, List<ProviderAgentTask> tasks) {
    if (tasks.isEmpty) return false;
    if (filter == _TaskFilter.all) return true;
    return switch (kind) {
      ProviderAgentTaskKind.needsAttention =>
        filter == _TaskFilter.needsAttention,
      ProviderAgentTaskKind.awaitingReview =>
        filter == _TaskFilter.awaitingReview,
      ProviderAgentTaskKind.completed => filter == _TaskFilter.approved,
    };
  }

  @override
  Widget build(BuildContext context) {
    final attention = _of(ProviderAgentTaskKind.needsAttention);
    final awaiting = _of(ProviderAgentTaskKind.awaitingReview);
    final approved = _of(ProviderAgentTaskKind.completed);

    // One assignment list with no property behind it is a different fact from
    // "nothing needs doing": say so, and never fill the gap with invented work.
    if (data.listings.isEmpty) {
      return providerContent(
        children: [
          const _PageHeader(),
          const SizedBox(height: 18),
          ProviderMessage(
            icon: Icons.assignment_outlined,
            title: 'No assigned properties yet',
            body:
                'Tasks come from the properties assigned to this agent account '
                'and what an administrator has recorded against them. Nothing '
                'is assigned yet, so there is nothing to act on.',
          ),
        ],
      );
    }

    final shown = <Widget>[
      if (_shows(ProviderAgentTaskKind.needsAttention, attention))
        _Section(
          title: 'Needs attention',
          caption:
              '${attention.length} '
              '${attention.length == 1 ? 'property' : 'properties'} '
              'assigned to you '
              '${attention.length == 1 ? 'needs' : 'need'} an action.',
          tasks: attention,
          onOpen: onOpen,
        ),
      if (_shows(ProviderAgentTaskKind.awaitingReview, awaiting))
        _Section(
          title: 'Awaiting administrator review',
          caption: 'Locked while an administrator reviews the submission.',
          tasks: awaiting,
          onOpen: onOpen,
        ),
      // Approved properties are completed records, not tasks. They appear in
      // their own section, and only when an assignment actually holds one.
      if (_shows(ProviderAgentTaskKind.completed, approved))
        _Section(
          title: 'Completed',
          caption: 'Approved by an administrator.',
          tasks: approved,
          onOpen: onOpen,
        ),
    ];
    // "Caught up" is a statement about the actionable bucket only, so it is
    // said when nothing needs attention — and the tracked submissions and
    // approved properties below it stay visible, because those are real too.
    final caughtUp = attention.isEmpty &&
        (filter == _TaskFilter.all || filter == _TaskFilter.needsAttention);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 20, 0, providerDockClearance),
      children: [
        const _PageHeader(),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: providerGutter),
          child: _SummaryRow(data: data),
        ),
        const SizedBox(height: 16),
        _FilterStrip(
          data: data,
          selected: filter,
          onSelect: onFilterChanged,
        ),
        const SizedBox(height: 4),
        if (caughtUp) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: providerGutter),
            child: ProviderMessage(
              icon: Icons.task_alt_outlined,
              title: "You're all caught up",
              body: 'No assigned properties need action right now.',
            ),
          ),
          ...shown,
        ] else if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: providerGutter),
            child: ProviderMessage(
              icon: Icons.filter_alt_off_outlined,
              title: 'Nothing in this view',
              body:
                  'No assigned property is currently in this state. Choose All '
                  'to see every task, submission and approved property.',
            ),
          )
        else
          ...shown,
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: providerGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Property tasks', style: SitewiseM3Type.h1),
          const SizedBox(height: 6),
          const Text(
            'Keep your assigned properties ready for review.',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 13,
              height: 1.5,
              color: SitewiseM3.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// The three counts, computed over the same classified list the cards render,
/// so a number here can never disagree with a card below it.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.data});

  final ProviderDashboardData data;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _SummaryTile(
            value: data.needsAttentionCount,
            label: 'Needs attention',
            icon: Icons.edit_note_rounded,
            wash: SitewiseM3.quiet,
            tone: SitewiseColors.action,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryTile(
            value: data.awaitingReviewCount,
            label: 'Awaiting review',
            icon: Icons.hourglass_top_rounded,
            wash: SitewiseM3.amberWash,
            tone: SitewiseM3.amber,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryTile(
            value: data.approvedCount,
            label: 'Approved',
            icon: Icons.check_circle_rounded,
            wash: SitewiseM3.greenWash,
            tone: SitewiseM3.green,
          ),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.value,
    required this.label,
    required this.icon,
    required this.wash,
    required this.tone,
  });

  final int value;
  final String label;
  final IconData icon;
  final Color wash;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 13, 12, 13),
        decoration: BoxDecoration(
          color: SitewiseM3.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: SitewiseM3.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: wash,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 17, color: tone),
            ),
            const SizedBox(height: 9),
            Text(
              '$value',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.05,
                letterSpacing: -0.6,
                color: SitewiseM3.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 10.5,
                height: 1.3,
                fontWeight: FontWeight.w700,
                color: SitewiseM3.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterStrip extends StatelessWidget {
  const _FilterStrip({
    required this.data,
    required this.selected,
    required this.onSelect,
  });

  final ProviderDashboardData data;
  final _TaskFilter selected;
  final ValueChanged<_TaskFilter> onSelect;

  int _count(_TaskFilter filter) => switch (filter) {
    _TaskFilter.all => data.agentTasks.length,
    _TaskFilter.needsAttention => data.needsAttentionCount,
    _TaskFilter.awaitingReview => data.awaitingReviewCount,
    _TaskFilter.approved => data.approvedCount,
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Task filters',
      child: SizedBox(
        height: 48,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: providerGutter),
          itemCount: _TaskFilter.values.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final filter = _TaskFilter.values[index];
            return _FilterPill(
              label: '${filter.label} (${_count(filter)})',
              selected: filter == selected,
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

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.caption,
    required this.tasks,
    required this.onOpen,
  });

  final String title;
  final String caption;
  final List<ProviderAgentTask> tasks;
  final void Function(String route, {Object? arguments}) onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(providerGutter, 18, providerGutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: SitewiseM3Type.h2),
              const SizedBox(height: 3),
              Text(
                caption,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11.5,
                  color: SitewiseM3.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (final task in tasks)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              providerGutter,
              0,
              providerGutter,
              10,
            ),
            child: _TaskCard(task: task, onOpen: onOpen),
          ),
      ],
    );
  }
}

/// One property, what the records say about it, and the action the backend
/// still permits on it.
class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.onOpen});

  final ProviderAgentTask task;
  final void Function(String route, {Object? arguments}) onOpen;

  String get _location {
    final address = task.listing.address.trim();
    return address.isEmpty ? 'Address not recorded' : address;
  }

  String? get _feedbackDate {
    final raw = task.noteAt ?? task.listing.submittedAt;
    return _formatDay(raw);
  }

  @override
  Widget build(BuildContext context) {
    final note = task.note?.trim();
    final hasNote = note != null && note.isNotEmpty;
    final date = _feedbackDate;
    return Semantics(
      button: true,
      label: '${task.category}: ${task.listing.displayTitle}',
      child: M3Card(
        padding: const EdgeInsets.fromLTRB(15, 15, 15, 15),
        onTap: () => onOpen(task.route, arguments: task.listing.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: providerWash,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    task.icon,
                    size: 20,
                    color: SitewiseColors.action,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.listing.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                          color: SitewiseM3.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _location,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 11.5,
                          height: 1.4,
                          color: SitewiseM3.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ProviderStatusPill(stage: task.listing.stage, compact: true),
              ],
            ),
            const SizedBox(height: 11),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                M3Tag(
                  label: task.category,
                  positive: task.kind == ProviderAgentTaskKind.completed,
                ),
                if (task.kind == ProviderAgentTaskKind.awaitingReview &&
                    date != null)
                  _MetaChip(
                    icon: Icons.event_available_outlined,
                    label: 'Submitted $date',
                  ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              task.instruction,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12.5,
                height: 1.5,
                color: SitewiseM3.ink,
              ),
            ),
            if (hasNote) ...[
              const SizedBox(height: 11),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                decoration: BoxDecoration(
                  color: providerSoft,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: SitewiseM3.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 14,
                          color: SitewiseM3.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          date == null
                              ? 'Administrator feedback'
                              : 'Administrator feedback · $date',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                            color: SitewiseM3.muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      note,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        height: 1.5,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (task.actionLabel != null) ...[
              const SizedBox(height: 13),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () =>
                      onOpen(task.route, arguments: task.listing.id),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(task.actionLabel!),
                  style: FilledButton.styleFrom(
                    backgroundColor: SitewiseColors.action,
                    foregroundColor: SitewiseM3.surface,
                    minimumSize: const Size.fromHeight(46),
                    textStyle: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                    ),
                  ),
                ),
              ),
            ] else if (task.kind != ProviderAgentTaskKind.completed) ...[
              // The listing is locked or the state refuses an edit: the record
              // stays visible, the action does not.
              const SizedBox(height: 11),
              const Row(
                children: [
                  Icon(Icons.lock_outline_rounded, size: 15, color: SitewiseM3.muted),
                  SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'Editing is closed for this verification state.',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 11.5,
                        color: SitewiseM3.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        border: Border.all(color: SitewiseM3.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: SitewiseM3.muted),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: SitewiseM3.muted,
            ),
          ),
        ],
      ),
    );
  }
}

const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// A recorded date in the workspace's words, or null when no record carries
/// one — a card then drops the line instead of showing a placeholder.
String? _formatDay(String? iso) {
  final parsed = iso == null ? null : DateTime.tryParse(iso);
  if (parsed == null) return null;
  return '${parsed.day} ${_monthNames[parsed.month - 1]} ${parsed.year}';
}
