import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import '../data/app_locator.dart';
import 'ui.dart';

/// The review workspace's right-hand content: everything the backend's
/// `/staff/properties/{id}/verification` detail returns, rendered once and
/// reused by both surfaces that load it — the review split's detail column
/// (`/admin/listings`) and the standalone `/admin/listing-detail` page.
///
/// Decisions dispatch through [adminNotifierProvider] so the busy flag, the
/// success notice and the automatic queue/detail refresh stay in the shared
/// controller. Documents stream through the authenticated download endpoint
/// (`AppLocator.propertyVerificationRepo`) — never a public URL.
/// Param-less shell so the `@client` codegen accepts this component (it only
/// supports primitive constructor params); the detail arrives through
/// [adminNotifierProvider] and renders via [_VerificationDetailBody].
@client
class VerificationDetailView extends StatefulComponent {
  const VerificationDetailView({super.key});

  @override
  State<VerificationDetailView> createState() =>
      _VerificationDetailViewShellState();
}

class _VerificationDetailViewShellState extends State<VerificationDetailView> {
  @override
  Component build(BuildContext context) {
    final detail = context.watch(
      adminNotifierProvider.select((state) => state.reviewDetail),
    );
    if (detail == null) return Component.fragment([]);
    return _VerificationDetailBody(
      key: ValueKey('verification-detail-${detail.property.propertyId}'),
      detail: detail,
    );
  }
}

/// The rendering body. Not `@client` — it is instantiated by the shell above
/// with the already-loaded [VerificationDetail]; the [ValueKey] resets its
/// note-form state whenever a different property is opened.
class _VerificationDetailBody extends StatefulComponent {
  final VerificationDetail detail;

  const _VerificationDetailBody({super.key, required this.detail});

  @override
  State<_VerificationDetailBody> createState() =>
      _VerificationDetailBodyState();
}

class _VerificationDetailBodyState extends State<_VerificationDetailBody> {
  /// The dimension whose reject / request-information form is open, if any.
  VerificationDimension? _formFor;

  /// `'reject'` or `'information'` — the two note-taking decisions.
  String _formMode = 'reject';
  String _note = '';
  final Set<String> _busyDocs = {};
  String? _downloadError;

  @override
  Component build(BuildContext context) {
    final detail = component.detail;
    final verification = detail.verification;

    return div(classes: 'panel stack', [
      _head(detail),
      _facts(detail),
      if ((detail.property.description ?? '').trim().isNotEmpty) ...[
        h3(classes: 'detail-h', [Component.text('Description')]),
        p(classes: 'detail-p', [Component.text(detail.property.description!)]),
      ],
      _documents(detail),
      for (final dimension in VerificationDimension.values)
        _dimensionCard(dimension, verification),
      _history(detail),
    ]);
  }

  // --- Sections -------------------------------------------------------------

  Component _head(VerificationDetail detail) {
    final property = detail.property;
    final verification = detail.verification;
    return div(classes: 'detail-head', [
      div([
        h2([Component.text(property.title)]),
        p([
          Component.text(
            _addressLine(property.address, property.city, property.state),
          ),
        ]),
        if (detail.owner != null)
          p(classes: 'small muted', [
            Component.text(
              'Submitted by ${detail.owner!.fullName} · ${detail.owner!.email}',
            ),
          ]),
      ]),
      div(classes: 'queue-item__meta stack', [
        for (final dimension in VerificationDimension.values)
          _statusPill(verification.statuses.statusOf(dimension)),
        if (verification.publicationEligible)
          const Pill('Publication-eligible', tone: 'success'),
      ]),
    ]);
  }

  Component _facts(VerificationDetail detail) {
    final property = detail.property;
    String money(double? value) =>
        value == null ? 'Not provided' : 'RM${value.toStringAsFixed(0)}';
    String area(double? value) =>
        value == null ? '—' : '${value.toStringAsFixed(0)} sq ft';

    return div(classes: 'evidence', [
      _ev('Monthly rent', money(property.monthlyRent)),
      _ev('Built-up area', area(property.builtUpAreaSqft)),
      _ev('Land area', area(property.landAreaSqft)),
      _ev('Property type', property.propertyType ?? 'Not provided'),
      _ev('Record status', property.status ?? '—'),
      _ev('Company', property.companyName ?? 'Not provided'),
    ]);
  }

  Component _documents(VerificationDetail detail) {
    final documents = detail.documents;
    return div(classes: 'stack', [
      h3(classes: 'detail-h', [Component.text('Evidence documents')]),
      if (documents.isEmpty)
        p(classes: 'detail-p muted', [
          Component.text(
            'No documents attached. The owner uploads deeds, letters and '
            'photos from the submitter workspace.',
          ),
        ])
      else
        div(classes: 'stack', [
          for (final doc in documents) _documentRow(doc),
        ]),
      if (_downloadError != null)
        p(classes: 'field__error', [Component.text(_downloadError!)]),
    ]);
  }

  Component _documentRow(VerificationDocument doc) {
    final busy = _busyDocs.contains(doc.documentId);
    final dimension = doc.verificationType?.label ?? 'General';
    return div(classes: 'card row', [
      span([const Icon('description', size: 'sm')]),
      div(classes: 'grow', [
        h4([Component.text(doc.originalFilename)]),
        p(classes: 'small muted', [
          Component.text(
            '$dimension · ${doc.documentType} · ${doc.mimeType} · '
            '${_fmtSize(doc.fileSize)}'
            '${doc.uploadedAt == null ? '' : ' · ${_fmtDate(doc.uploadedAt)}'}',
          ),
        ]),
      ]),
      if (!doc.isActive)
        const Pill('Superseded', tone: 'neutral')
      else
        ActionButton(
          busy ? 'Fetching…' : 'Download',
          onClick: busy ? null : () => unawaited(_download(doc)),
          variant: 'secondary',
          icon: 'download',
        ),
    ]);
  }

  Component _dimensionCard(
    VerificationDimension dimension,
    PropertyVerification verification,
  ) {
    final status = verification.statuses.statusOf(dimension);
    final busy = context.watch(
      adminNotifierProvider.select((state) => state.busyAction),
    );
    final propertyId = '${verification.propertyId}';
    final note = _latestReason(dimension, status, component.detail.history);

    return div(classes: 'card stack', [
      div(classes: 'row', [
        span(classes: 'grow title', [Component.text(dimension.label)]),
        _statusPill(status),
      ]),
      switch (status) {
        PropertyVerificationStatus.notSubmitted => p(classes: 'body muted', [
          Component.text(
            'The owner has not submitted this dimension yet. It cannot be '
            'reviewed until a submission arrives.',
          ),
        ]),
        PropertyVerificationStatus.pending => p(classes: 'body muted', [
          Component.text(
            'Submitted and waiting. Start the review to record that this '
            'dimension is being examined.',
          ),
        ]),
        PropertyVerificationStatus.underReview => p(classes: 'body muted', [
          Component.text(
            'Under review. Approving verifies this dimension; rejecting or '
            'requesting information sends the reason back to the owner.',
          ),
        ]),
        PropertyVerificationStatus.verified => p(classes: 'body', [
          Component.text(_verifiedLine(verification)),
        ]),
        PropertyVerificationStatus.rejected => p(classes: 'body', [
          const Component.text('Rejected — awaiting the owner\'s resubmission.'),
        ]),
        PropertyVerificationStatus.informationRequested => p(classes: 'body', [
          const Component.text(
            'Information requested — awaiting the owner\'s response.',
          ),
        ]),
      },
      if (note != null) div(classes: 'owner-note', [Component.text(note)]),
      if (_formFor == dimension)
        _noteForm(dimension)
      else
        _decisionBar(dimension, status, propertyId, busy != null),
    ]);
  }

  Component _decisionBar(
    VerificationDimension dimension,
    PropertyVerificationStatus status,
    String propertyId,
    bool busy,
  ) {
    final notifier = context.read(adminNotifierProvider.notifier);
    void dispatch(String kind) {
      switch (kind) {
        case 'start':
          unawaited(notifier.startDimensionReview(propertyId, dimension));
        case 'approve':
          unawaited(notifier.approveDimension(propertyId, dimension));
      }
    }

    final actions = switch (status) {
      PropertyVerificationStatus.pending => [
        ActionButton(
          busy ? 'Starting…' : 'Start review',
          onClick: busy ? null : () => dispatch('start'),
          icon: 'visibility',
        ),
      ],
      PropertyVerificationStatus.underReview => [
        ActionButton(
          busy ? 'Approving…' : 'Approve',
          onClick: busy ? null : () => dispatch('approve'),
          icon: 'check',
        ),
        ActionButton(
          'Reject with reason',
          variant: 'secondary',
          onClick: busy
              ? null
              : () => setState(() {
                _formFor = dimension;
                _formMode = 'reject';
                _note = '';
              }),
        ),
        ActionButton(
          'Request information',
          variant: 'secondary',
          onClick: busy
              ? null
              : () => setState(() {
                _formFor = dimension;
                _formMode = 'information';
                _note = '';
              }),
        ),
      ],
      _ => const <Component>[],
    };

    if (actions.isEmpty) return Component.fragment([]);
    return div(classes: 'decision-bar', actions);
  }

  Component _noteForm(VerificationDimension dimension) {
    final rejecting = _formMode == 'reject';
    final tooShort = rejecting && _note.trim().length < 8;
    final empty = _note.trim().isEmpty;
    final invalid = rejecting ? tooShort : empty;
    final notifier = context.read(adminNotifierProvider.notifier);
    final propertyId = '${component.detail.property.propertyId}';

    return div(classes: 'reject-form stack', [
      Field(
        labelText: rejecting
            ? 'Reason shown to the owner'
            : 'What the owner must provide',
        hint: rejecting ? 'Minimum 8 characters.' : 'Be specific and actionable.',
        child: textarea(
          [],
          attributes: {
            'rows': '3',
            'placeholder': rejecting
                ? 'Why is this dimension being rejected?'
                : 'What evidence or correction is needed?',
            'aria-label': rejecting ? 'Rejection reason' : 'Information request',
          },
          events: events<String>(onInput: (v) => _note = v),
        ),
      ),
      div(classes: 'row', [
        ActionButton(
          rejecting ? 'Confirm reject' : 'Send request',
          onClick: invalid
              ? null
              : () {
                final note = _note.trim();
                unawaited(
                  (rejecting
                          ? notifier.rejectDimension(propertyId, dimension, note)
                          : notifier.requestInformation(
                              propertyId,
                              dimension,
                              note,
                            ))
                      .whenComplete(() {
                    if (mounted) {
                      setState(() {
                        _formFor = null;
                        _note = '';
                      });
                    }
                  }),
                );
              },
        ),
        ActionButton(
          'Cancel',
          variant: 'secondary',
          onClick: () => setState(() {
            _formFor = null;
            _note = '';
          }),
        ),
      ]),
      if (invalid)
        p(classes: 'field__error', [
          Component.text(
            rejecting
                ? 'Add at least 8 characters before rejecting.'
                : 'Describe what the owner must provide.',
          ),
        ]),
    ]);
  }

  Component _history(VerificationDetail detail) {
    final events = detail.history.reversed.toList();
    return div(classes: 'stack', [
      h3(classes: 'detail-h', [Component.text('Audit history')]),
      if (events.isEmpty)
        const EmptyState(
          title: 'No events yet',
          body: 'Submissions, decisions and evidence uploads appear here.',
        )
      else
        div(classes: 'stack', [
          for (final event in events) _historyRow(event),
        ]),
    ]);
  }

  Component _historyRow(VerificationReviewEvent event) {
    final decision =
        (event.previousStatus ?? '—') != (event.newStatus ?? '—') &&
        event.newStatus != null;
    return div(classes: 'card row', [
      span([const Icon('history', size: 'sm')]),
      div(classes: 'grow', [
        h4([Component.text(event.label)]),
        p(classes: 'small muted', [
          Component.text(
            [
              if (event.verificationType != null) event.verificationType!.label,
              if (event.createdAt != null) _fmtDate(event.createdAt),
              if (decision)
                '${event.previousStatus?.replaceAll('_', ' ')} → '
                    '${event.newStatus!.replaceAll('_', ' ')}',
              if (event.adminUserId != null) 'by ${event.adminUserId}',
            ].join(' · '),
          ),
        ]),
        if (event.reason != null && event.reason!.isNotEmpty)
          p(classes: 'body', [Component.text(event.reason!)]),
      ]),
    ]);
  }

  // --- Actions --------------------------------------------------------------

  Future<void> _download(VerificationDocument doc) async {
    setState(() {
      _busyDocs.add(doc.documentId);
      _downloadError = null;
    });
    try {
      final bytes = await AppLocator.propertyVerificationRepo.downloadDocument(
        doc.documentId,
      );
      if (!mounted) return;
      _saveBytes(Uint8List.fromList(bytes), doc.originalFilename, doc.mimeType);
    } on StateError catch (error) {
      if (mounted) {
        setState(() {
          _downloadError = error.message.isNotEmpty
              ? error.message
              : 'The document could not be downloaded.';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _downloadError = 'The document could not be downloaded.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyDocs.remove(doc.documentId);
        });
      }
    }
  }

  /// Hands the received bytes to the browser's download flow. Runs on the
  /// client only — the component is `@client` and this is called from a click
  /// handler.
  void _saveBytes(Uint8List bytes, String filename, String mime) {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    final url = web.URL.createObjectURL(blob);
    web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..click();
    web.URL.revokeObjectURL(url);
  }

  // --- Helpers --------------------------------------------------------------

  /// The note the dimension is currently sitting on: the latest reject reason
  /// or information request, surfaced only while the dimension still holds
  /// that state — mirrors the backend's `_requested_corrections` rule.
  String? _latestReason(
    VerificationDimension dimension,
    PropertyVerificationStatus status,
    List<VerificationReviewEvent> history,
  ) {
    if (status != PropertyVerificationStatus.rejected &&
        status != PropertyVerificationStatus.informationRequested) {
      return null;
    }
    for (final event in history.reversed) {
      if (event.verificationType != dimension) continue;
      final isNote = event.action.endsWith('_rejected') ||
          event.action.endsWith('_information_requested');
      if (isNote && event.reason != null && event.reason!.isNotEmpty) {
        return event.reason;
      }
    }
    return null;
  }

  static String _verifiedLine(PropertyVerification verification) {
    final by = verification.reviewedBy == null
        ? ''
        : ' by ${verification.reviewedBy}';
    final at = verification.updatedAt == null
        ? ''
        : ' · ${_fmtDate(verification.updatedAt)}';
    return 'Verified$by$at.';
  }

  Component _statusPill(PropertyVerificationStatus status) => Pill(
    status.label,
    tone: switch (status) {
      PropertyVerificationStatus.verified => 'success',
      PropertyVerificationStatus.pending => 'warning',
      PropertyVerificationStatus.underReview => 'action',
      PropertyVerificationStatus.rejected => 'danger',
      PropertyVerificationStatus.informationRequested => 'warning',
      PropertyVerificationStatus.notSubmitted => 'neutral',
    },
  );

  Component _ev(String label, String value) => div(classes: 'ev', [
    h5([Component.text(label)]),
    p([Component.text(value)]),
  ]);

  static String _addressLine(String? address, String? city, String? state) {
    final parts = [address, city, state].whereType<String>().where(
      (part) => part.trim().isNotEmpty,
    );
    return parts.isEmpty ? 'No address provided' : parts.join(', ');
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  static String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final flat = iso.replaceFirst('T', ' ');
    return flat.length > 16 ? flat.substring(0, 16) : flat;
  }
}
