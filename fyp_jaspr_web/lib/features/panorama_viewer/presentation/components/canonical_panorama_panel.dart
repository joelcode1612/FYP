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
@client
class CanonicalPanoramaPanel extends StatefulComponent {
  /// Operational property id (`fyp.rental_properties.id`), as a string from
  /// the admin route.
  final String propertyId;

  const CanonicalPanoramaPanel({super.key, required this.propertyId});

  @override
  State<CanonicalPanoramaPanel> createState() => _CanonicalPanoramaPanelState();
}

class _CanonicalPanoramaPanelState extends State<CanonicalPanoramaPanel> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _panorama;
  String? _viewUrl;

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
          _error =
              'The viewing URL could not be created for this panorama.';
        }
      });
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

  @override
  Component build(BuildContext context) {
    final pano = _panorama;
    final status = '${pano?['verificationStatus'] ?? ''}';
    return div(classes: 'card card-pad stack', [
      span(classes: 'title', [Component.text('360° panorama (Sitewise)')]),
      p(classes: 'body muted', [
        Component.text(
          'The canonical panorama the capture pipeline stitched on the '
          'backend, served from private storage through a temporary '
          'authorized URL. Publication to buyers still follows the ordinary '
          'verification flow.',
        ),
      ]),
      if (_loading)
        p(classes: 'body muted', [Component.text('Reading the 360° panorama…')])
      else if (_error != null)
        div(classes: 'notice notice-danger', [
          Component.text(_error!),
          ActionButton(
            'Try again',
            variant: 'secondary',
            onClick: () => unawaited(_load()),
          ),
        ])
      else if (pano == null)
        p(classes: 'body', [
          Component.text(
            'No 360° panorama exists for this listing yet. The owner may '
            'still be capturing, or the backend may still be stitching — '
            'reload later.',
          ),
        ])
      else if (_viewUrl != null) ...[
        div(classes: 'stack', [
          if (status.isNotEmpty)
            p(classes: 'body muted', [
              Component.text(
                'Verification status: $status · '
                '${pano['width'] ?? '?'}×${pano['height'] ?? '?'} px',
              ),
            ]),
          div(classes: 'sw-pano__stage', [
            SphericalPanoramaFrame(
              imageUrl: _viewUrl!,
              title: '360 degree panorama stitched by Sitewise. '
                  'Swipe or drag to look around.',
            ),
          ]),
        ]),
      ] else
        p(classes: 'body muted', [
          Component.text('The panorama record exists but cannot be viewed.'),
        ]),
    ]);
  }
}
