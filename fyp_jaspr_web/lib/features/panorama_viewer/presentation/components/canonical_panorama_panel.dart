import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/authentication/data/auth_browser.dart';
import 'package:sitewise_jaspr_web/features/panorama_viewer/presentation/components/spherical_panorama_frame.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Staff panel: the canonical 360° panorama the backend stitched for this
/// listing (spec §14 — the Jaspr viewer on the same canonical record).
///
/// The metadata and the temporary viewing URL come from the SAME authorized
/// endpoints the mobile viewer uses (`/api/v1/360/...`), so the web viewer
/// never reads a second data source. The panorama only appears when the
/// backend actually stored one — an in-progress or failed job surfaces as
/// "no panorama yet", never as a placeholder image. Signed URLs expire, so a
/// panel that fails on an old link reloads the metadata and mints a fresh
/// one.
// Mounted inside the client-side verification detail view.
class CanonicalPanoramaPanel extends StatefulComponent {
  /// Operational property id (`fyp.rental_properties.id`), as a string from
  /// the admin route.
  final String propertyId;
  final bool evidenceOnly;
  final String? expectedPanoramaId;
  final void Function()? onEvidenceReady;

  const CanonicalPanoramaPanel({
    super.key,
    required this.propertyId,
    this.evidenceOnly = false,
    this.expectedPanoramaId,
    this.onEvidenceReady,
  });

  @override
  State<CanonicalPanoramaPanel> createState() => _CanonicalPanoramaPanelState();
}

class _CanonicalPanoramaPanelState extends State<CanonicalPanoramaPanel> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _panorama;
  String? _viewUrl;
  // Administrative review state. A rejection collects a reason first; every
  // action reloads the metadata so the panel always shows the backend's
  // actual status, never an optimistic guess.
  bool _busy = false;
  bool _rejecting = false;
  bool _expandedViewer = false;
  String _reason = '';

  int? get _listingId => int.tryParse(component.propertyId);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final listingId = _listingId;
    if (listingId == null) {
      setState(() {
        _loading = false;
        _error =
            'This property id is not numeric; the 360° panorama cannot be '
            'resolved.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _viewUrl = null;
    });
    try {
      final meta = await WebAuth.requestDetailed(
        '/api/v1/360/properties/$listingId/panorama',
      );
      if (!mounted) return;
      if (meta['ok'] != true) {
        final status = meta['status'];
        if (status is int && status == 404) {
          // The honest "not captured / still processing" state: the backend
          // has no canonical panorama row for this listing yet.
          setState(() {
            _loading = false;
            _panorama = null;
          });
          return;
        }
        setState(() {
          _loading = false;
          _error = _message(meta, 'The 360° panorama state could not be read.');
        });
        return;
      }
      final row = meta['body'] as Map<String, dynamic>;
      final panoramaId = row['panoramaId'];
      if (component.evidenceOnly &&
          panoramaId != component.expectedPanoramaId) {
        setState(() {
          _loading = false;
          _error =
              'The submitted panorama changed. Reload the property review.';
        });
        return;
      }
      if (panoramaId is! String || panoramaId.isEmpty) {
        setState(() {
          _loading = false;
          _error =
              'The backend returned a panorama record without an id, so no '
              'view can be opened for it.';
        });
        return;
      }
      final view = await WebAuth.requestDetailed(
        '/api/v1/360/panoramas/$panoramaId/view',
      );
      if (!mounted) return;
      if (view['ok'] != true) {
        setState(() {
          _loading = false;
          _panorama = row;
          _error = _message(view, 'The viewing URL could not be created.');
        });
        return;
      }
      final body = view['body'] as Map<String, dynamic>;
      final url = body['viewUrl'];
      setState(() {
        _loading = false;
        _panorama = row;
        if (url is String && url.isNotEmpty) {
          _viewUrl = url;
        } else {
          _error = 'The viewing URL could not be created for this panorama.';
        }
      });
      if (_viewUrl != null) component.onEvidenceReady?.call();
    } on Object catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'The 360° panorama state could not be read: $err';
      });
    }
  }

  static String _message(Map<String, dynamic> result, String fallback) {
    final message = result['message'];
    return message is String && message.isNotEmpty ? message : fallback;
  }

  // ------------------------------------------------------------- admin actions

  Future<void> _act(String action, {Map<String, dynamic>? body}) async {
    final panoramaId = '${_panorama?['panoramaId'] ?? ''}';
    if (_busy || panoramaId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await WebAuth.requestDetailed(
        '/api/v1/360/admin/panoramas/$panoramaId/$action',
        method: 'POST',
        body: body ?? const <String, dynamic>{},
      );
      if (!mounted) return;
      if (result['ok'] != true) {
        setState(() {
          _busy = false;
          _error = _message(
            result,
            'The ${action == 'review' ? 'review decision' : action} could '
            'not be recorded.',
          );
        });
        return;
      }
      setState(() {
        _busy = false;
        _rejecting = false;
        _reason = '';
      });
      await _load();
    } on Object catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'The action failed: $err';
      });
    }
  }

  Component _reviewActions(Map<String, dynamic> pano) {
    final status = '${pano['verificationStatus'] ?? ''}';
    final published = pano['publishedAt'] != null;
    final children = <Component>[];
    switch (status) {
      case 'pending':
        children.add(
          ActionButton(
            'Approve panorama',
            variant: 'primary',
            onClick: _busy
                ? null
                : () => unawaited(
                    _act('review', body: const {'decision': 'approved'}),
                  ),
          ),
        );
        if (_rejecting) {
          children.add(
            SearchInput(
              placeholder: 'Rejection reason (required)',
              ariaLabel: 'Panorama rejection reason',
              onInput: (value) => setState(() => _reason = value),
            ),
          );
          children.add(
            ActionButton(
              'Confirm rejection',
              variant: 'danger-outline',
              onClick: (_busy || _reason.trim().isEmpty)
                  ? null
                  : () => unawaited(
                      _act(
                        'review',
                        body: {
                          'decision': 'rejected',
                          'reason': _reason.trim(),
                        },
                      ),
                    ),
            ),
          );
        } else {
          children.add(
            ActionButton(
              'Reject panorama',
              variant: 'danger-outline',
              onClick: _busy ? null : () => setState(() => _rejecting = true),
            ),
          );
        }
      case 'approved':
        children.add(
          published
              ? ActionButton(
                  'Unpublish',
                  variant: 'danger-outline',
                  onClick: _busy ? null : () => unawaited(_act('unpublish')),
                )
              : ActionButton(
                  'Publish to buyers',
                  variant: 'primary',
                  onClick: _busy ? null : () => unawaited(_act('publish')),
                ),
        );
      case 'rejected':
        final reason = '${pano['reviewReason'] ?? ''}';
        if (reason.isNotEmpty) {
          children.add(
            p(classes: 'body muted', [
              Component.text('Rejection reason: $reason'),
            ]),
          );
        }
        children.add(
          ActionButton(
            'Re-review (approve)',
            variant: 'secondary',
            onClick: _busy
                ? null
                : () => unawaited(
                    _act('review', body: const {'decision': 'approved'}),
                  ),
          ),
        );
    }
    return div(
      classes: 'admin-pano-review__actions${_rejecting ? ' is-rejecting' : ''}',
      children,
    );
  }

  @override
  Component build(BuildContext context) {
    final pano = _panorama;
    final status = '${pano?['verificationStatus'] ?? ''}';
    final statusLabel = switch (status) {
      'pending' => 'Pending review',
      'approved' => 'Approved',
      'rejected' => 'Rejected',
      '' => 'Not available',
      _ => status,
    };
    final statusClass = switch (status) {
      'approved' => 'is-approved',
      'rejected' => 'is-rejected',
      'pending' => 'is-pending',
      _ => 'is-neutral',
    };
    return section(classes: 'card admin-pano-review', [
      div(classes: 'admin-pano-review__header', [
        div(classes: 'admin-pano-review__heading', [
          span(classes: 'admin-pano-review__eyebrow', [
            Component.text('Inspection evidence'),
          ]),
          h2(classes: 'admin-pano-review__title', [
            Component.text('360° property inspection'),
          ]),
          p(classes: 'admin-pano-review__copy', [
            Component.text(
              'Review the submitted interior panorama before recording a decision.',
            ),
          ]),
        ]),
        if (!_loading && pano != null)
          span(classes: 'admin-pano-review__status $statusClass', [
            Component.text(statusLabel),
          ]),
      ]),
      if (_loading)
        div(classes: 'admin-pano-review__empty', [
          p([Component.text('Loading inspection panorama…')]),
        ])
      else if (_error != null)
        div(classes: 'notice notice-danger stack', [
          Component.text(_error!),
          ActionButton(
            'Try again',
            variant: 'secondary',
            onClick: () => unawaited(_load()),
          ),
        ])
      else if (pano == null)
        div(classes: 'admin-pano-review__empty', [
          span(classes: 'title', [Component.text('No panorama available')]),
          p(classes: 'admin-pano-review__copy', [
            Component.text(
              'A capture has not been submitted or panorama processing is not complete.',
            ),
          ]),
          ActionButton(
            'Refresh',
            variant: 'secondary',
            onClick: () => unawaited(_load()),
          ),
        ])
      else if (_viewUrl != null) ...[
        div(classes: 'admin-pano-review__toolbar', [
          p(classes: 'admin-pano-review__copy', [
            Component.text(
              'Drag to look around. Use the viewer controls to zoom or reset.',
            ),
          ]),
          ActionButton(
            _expandedViewer ? 'Reduce viewer' : 'Expand viewer',
            variant: 'secondary',
            onClick: () => setState(() => _expandedViewer = !_expandedViewer),
          ),
        ]),
        div(
          classes:
              'admin-pano-review__stage${_expandedViewer ? ' is-expanded' : ''}',
          [
            SphericalPanoramaFrame(
              imageUrl: _viewUrl!,
              title:
                  '360 degree property inspection. Drag or use arrow keys to look around.',
            ),
          ],
        ),
        div(classes: 'admin-pano-review__meta', [
          div(classes: 'admin-pano-review__fact', [
            span(classes: 'admin-pano-review__label', [
              Component.text('Resolution'),
            ]),
            span(classes: 'admin-pano-review__value', [
              Component.text(
                '${pano['width'] ?? '?'} × ${pano['height'] ?? '?'} px',
              ),
            ]),
          ]),
          div(classes: 'admin-pano-review__fact', [
            span(classes: 'admin-pano-review__label', [
              Component.text('Publication'),
            ]),
            span(classes: 'admin-pano-review__value', [
              Component.text(
                pano['publishedAt'] != null ? 'Published' : 'Not published',
              ),
            ]),
          ]),
        ]),
        if (!component.evidenceOnly)
          div(classes: 'admin-pano-review__decision', [
            div(classes: 'admin-pano-review__heading', [
              span(classes: 'title', [Component.text('Panorama review')]),
              p(classes: 'admin-pano-review__copy', [
                Component.text(
                  'This decision is separate from listing and ownership verification.',
                ),
              ]),
            ]),
            if (!component.evidenceOnly) _reviewActions(pano),
          ]),
      ] else
        div(classes: 'admin-pano-review__empty', [
          p([
            Component.text(
              'The panorama exists but its viewing link is unavailable.',
            ),
          ]),
          ActionButton(
            'Refresh',
            variant: 'secondary',
            onClick: () => unawaited(_load()),
          ),
        ]),
    ]);
  }
}
