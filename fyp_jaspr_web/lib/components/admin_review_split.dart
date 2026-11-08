import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../components/ui.dart';

/// Which queue the split renders. `verification` uses the awaiting-review set
/// (`state.queue`) and defaults to the Pending tab; `listings` uses every
/// property (`state.listings`) and defaults to All.
enum ReviewMode { verification, listings }

/// Master-detail review surface, ported from the source `admin/review.html`.
///
/// Structure is the source's exactly: a `.split` with a `.panel` queue on the
/// left (`.tabs` status filter + `.queue` of `.queue-item`s) and a detail
/// `.panel` on the right (`.evidence` grid, description, photos, verification
/// evidence `.kv`, the regulatory `.owner-note`, and a `.decision-bar`).
///
/// The two admin routes (`/admin/verification`, `/admin/listings`) share this
/// component; only the data source and default tab differ. Local selection and
/// tab state live here so it survives the rebuilds that happen when the admin
/// notifier publishes after an approve/reject; the split watches only the
/// three lists it renders, so unrelated admin transitions do not rebuild it.
class ReviewSplit extends StatefulComponent {
  final ReviewMode mode;

  const ReviewSplit({super.key, required this.mode});

  @override
  State<ReviewSplit> createState() => _ReviewSplitState();
}

/// The lists the split renders, selected as one value so the rebuild trigger
/// mirrors the old Selector scope.
typedef _ReviewData = ({
  List<CommercialProperty> queue,
  List<CommercialProperty> listings,
  List<SitewiseUser> users,
});

class _ReviewSplitState extends State<ReviewSplit> {
  String? _selectedId;
  VerificationStatus? _tab;
  bool _rejecting = false;
  String _reason = '';

  @override
  void initState() {
    super.initState();
    _tab = component.mode == ReviewMode.verification
        ? VerificationStatus.pending
        : null;
  }

  List<CommercialProperty> _itemsOf(_ReviewData data) =>
      component.mode == ReviewMode.verification ? data.queue : data.listings;

  List<CommercialProperty> _visibleOf(_ReviewData data) {
    final list = _itemsOf(data);
    if (_tab == null) return list;
    return list.where((prop) => prop.verification == _tab).toList();
  }

  CommercialProperty? _find(String id, _ReviewData data) {
    try {
      return data.listings.firstWhere((prop) => prop.id == id);
    } on StateError {
      // not in the all-listings set (e.g. removed) — try the queue.
    }
    try {
      return data.queue.firstWhere((prop) => prop.id == id);
    } on StateError {
      return null;
    }
  }

  /// The property shown on the right. Honours an explicit selection even when it
  /// has left the filtered queue (after an approve it stays visible, now
  /// verified), falling back to the first visible item when nothing is picked.
  CommercialProperty? _selectedOf(_ReviewData data) {
    if (_selectedId != null) {
      final picked = _find(_selectedId!, data);
      if (picked != null) return picked;
    }
    final visible = _visibleOf(data);
    return visible.isNotEmpty ? visible.first : null;
  }

  String _ownerText(CommercialProperty prop, _ReviewData data) {
    final owner = _ownerOf(prop, data);
    final who = owner?.name ?? prop.city;
    return '$who · ${prop.rentalDisplay}';
  }

  SitewiseUser? _ownerOf(CommercialProperty prop, _ReviewData data) {
    for (final u in data.users) {
      if (u.id == prop.ownerId) return u;
    }
    return null;
  }

  Future<void> _approve(String id) async {
    await context.read(adminNotifierProvider.notifier).approve(id);
    if (mounted) setState(() {});
  }

  Future<void> _reject(String id) async {
    final reason = _reason.trim();
    if (reason.length < 8) {
      if (mounted) setState(() {});
      return;
    }
    await context.read(adminNotifierProvider.notifier).reject(id, reason);
    if (mounted) {
      setState(() {
        _rejecting = false;
        _reason = '';
      });
    }
  }

  Component _queueItem(CommercialProperty prop, _ReviewData data) {
    final active = _selectedOf(data)?.id == prop.id;
    return button(
      classes: 'queue-item${active ? ' is-active' : ''}',
      attributes: {'type': 'button'},
      events: events(onClick: () => setState(() => _selectedId = prop.id)),
      [
        // `coverImage` is mobile-only and absent from the entity, so the source
        // thumbnail degrades to the `.shot` placeholder (styles.css).
        div(classes: 'shot', [const Icon('image', size: 'sm')]),
        div([
          h4([Component.text(prop.title)]),
          p([Component.text(_ownerText(prop, data))]),
        ]),
        div(classes: 'queue-item__meta', [
          StatusBadge.forVerification(prop.verification),
        ]),
      ],
    );
  }

  Component _ev(String label, String value) => div(classes: 'ev', [
    h5([Component.text(label)]),
    p([Component.text(value)]),
  ]);

  Component _missing(String text) =>
      span(classes: 'v-missing', [Component.text(text)]);

  Component _detail(CommercialProperty prop, _ReviewData data) {
    final owner = _ownerOf(prop, data);
    final ownerLine = owner != null
        ? '${owner.name} · ${owner.email}'
        : prop.ownerId;

    return div(classes: 'panel', [
      div(classes: 'detail-head', [
        div([
          h2([Component.text(prop.title)]),
          p([Component.text(prop.address)]),
        ]),
        div(classes: 'queue-item__meta', [
          StatusBadge.forVerification(prop.verification),
        ]),
      ]),

      // Evidence grid — only the fields the entity actually carries.
      div(classes: 'evidence', [
        _ev('Monthly rent', prop.rentalDisplay),
        _ev('Floor area', '${prop.sizeSqft.toStringAsFixed(0)} sq ft'),
        _ev('Property type', prop.propertyType),
        _ev('Parking / condition', 'Not provided'),
        _ev('Availability', 'Not provided'),
        _ev('Owner', ownerLine),
      ]),

      h3(classes: 'detail-h', [Component.text('Description')]),
      p(classes: 'detail-p', [Component.text('Not provided')]),

      h3(classes: 'detail-h', [Component.text('Photos')]),
      div(classes: 'thumbs', [
        for (var i = 0; i < 3; i++)
          div(classes: 'shot', [const Icon('image', size: 'sm')]),
      ]),
      p(classes: 'detail-p', [
        Component.text(
          'Photos are captured on the mobile app and are not available here. '
          'Submitters attach them to the listing record.',
        ),
      ]),

      h3(classes: 'detail-h', [Component.text('Verification evidence')]),
      dl(classes: 'kv', [
        div([
          dt([Component.text('Verification')]),
          dd([StatusBadge.forVerification(prop.verification)]),
        ]),
        div([
          dt([Component.text('Evidence reference')]),
          dd([_missing('Not provided')]),
        ]),
        div([
          dt([Component.text('Verified at')]),
          dd([
            prop.verification == VerificationStatus.verified
                ? const Component.text('—')
                : _missing('Not verified'),
          ]),
        ]),
      ]),
      p(classes: 'owner-note', [
        Component.text(
          'Regulatory status stays UNKNOWN after a listing review. Approving a '
          'listing verifies what the owner submitted; it does not confirm '
          'licensing, extraction or venting capacity with the local authority.',
        ),
      ]),

      _decisionBar(prop),
      if (_rejecting) _rejectForm(),
    ]);
  }

  Component _decisionBar(CommercialProperty prop) {
    if (prop.verification == VerificationStatus.pending) {
      return div(classes: 'decision-bar', [
        ActionButton(
          'Approve listing',
          onClick: () => unawaited(_approve(prop.id)),
        ),
        ActionButton(
          'Reject with reason',
          variant: 'secondary',
          onClick: () => setState(() => _rejecting = true),
        ),
      ]);
    }
    return div(classes: 'decision-bar', [
      div(classes: 'notice notice--info', [
        Component.text(
          'This listing is ${prop.verification.label}. Publication and removal '
          'are managed through the owner workspace.',
        ),
      ]),
    ]);
  }

  Component _rejectForm() => div(classes: 'reject-form stack', [
    Field(
      labelText: 'Reason shown to the owner',
      hint: 'Minimum 8 characters.',
      child: textarea(
        [],
        attributes: {
          'rows': '3',
          'placeholder': 'Why is this listing being rejected?',
          'aria-label': 'Rejection reason',
        },
        events: events<String>(onInput: (v) => _reason = v),
      ),
    ),
    div(classes: 'row', [
      ActionButton(
        'Confirm reject',
        onClick: () => unawaited(_reject(_selectedId!)),
      ),
      ActionButton(
        'Cancel',
        variant: 'secondary',
        onClick: () => setState(() {
          _rejecting = false;
          _reason = '';
        }),
      ),
    ]),
    if (_reason.trim().length < 8)
      p(classes: 'field__error', [
        Component.text('Add at least 8 characters before rejecting.'),
      ]),
  ]);

  Component _tabs() {
    final defs = <Map<String, Object?>>[
      {'value': VerificationStatus.pending, 'label': 'Pending'},
      {'value': VerificationStatus.verified, 'label': 'Verified'},
      {'value': VerificationStatus.rejected, 'label': 'Rejected'},
      {'value': null, 'label': 'All'},
    ];
    return div(
      classes: 'tabs',
      attributes: {'role': 'tablist'},
      [
        for (final d in defs)
          button(
            classes: 'tab',
            attributes: {
              'type': 'button',
              'role': 'tab',
              'aria-selected': (_tab == d['value']).toString(),
            },
            events: events(
              onClick: () =>
                  setState(() => _tab = d['value'] as VerificationStatus?),
            ),
            [Component.text(d['label'] as String)],
          ),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    final data = context.watch(
      adminNotifierProvider.select(
        (state) => (queue: state.queue, listings: state.listings, users: state.users),
      ),
    );
    final visible = _visibleOf(data);
    final count = visible.length;
    final noun = 'listing';
    final selected = _selectedOf(data);

    return div([
      _tabs(),
      div(classes: 'split', [
        div(classes: 'panel', [
          h2([Component.text('$count ${count == 1 ? noun : '${noun}s'}')]),
          if (visible.isEmpty)
            EmptyState(
              title: 'Queue is empty',
              body: 'Nothing is waiting in this state.',
            )
          else
            div(classes: 'queue', [
              for (final item in visible) _queueItem(item, data),
            ]),
        ]),
        div([
          selected != null
              ? _detail(selected, data)
              : EmptyState(
                  title: 'Select a listing',
                  body: 'Choose a listing on the left to review its evidence.',
                ),
        ]),
      ]),
    ]);
  }
}
