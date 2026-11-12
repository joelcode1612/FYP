import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/web.dart' as web;

/// A completed stitched panorama, or the reason there is none.
///
/// The application has **no** stitching pipeline and no completed-panorama
/// store, so in practice this is [PanoramaMedia.unavailable] today. The type
/// exists so the gallery never has to guess: a panorama is only rendered when
/// a caller can supply a genuinely finished, accessible file.
class PanoramaMedia {
  /// A browser-accessible equirectangular image URL; empty when unavailable.
  /// Availability is carried by [status] rather than nullability, so a caller
  /// cannot accidentally render an empty `src`.
  final String url;

  /// `ready` | `processing` | `unavailable`
  final String status;

  /// Plain-English reason shown when there is nothing to render.
  final String reason;

  /// A finished, accessible equirectangular panorama.
  const PanoramaMedia.ready(this.url)
      : status = 'ready',
        reason = '';

  /// A stitching job exists but has not produced a usable file yet.
  const PanoramaMedia.processing(this.reason)
      : url = '',
        status = 'processing';

  /// No panorama exists for this property at all.
  const PanoramaMedia.unavailable(this.reason)
      : url = '',
        status = 'unavailable';

  bool get isReady => status == 'ready' && url.trim().isNotEmpty;
}

/// Everything the gallery displays, as one immutable value.
///
/// The gallery is a [StatelessComponent]: Jaspr's `@client` boundary only
/// accepts primitive parameters, and the page is already the client component
/// that owns interaction state. Keeping the view in one object means the page
/// updates a single field per interaction instead of nine.
class GalleryView {
  /// 0 = photos, 1 = 360°.
  final int tab;
  final int index;
  final bool full;

  /// Panorama pan/tilt/zoom, in percent of the source and a 1.0-3.0 scale.
  final double yaw;
  final double pitch;
  final double zoom;
  final bool dragging;

  /// Set when the current photo's `src` failed to load.
  final bool photoFailed;

  const GalleryView({
    this.tab = 0,
    this.index = 0,
    this.full = false,
    this.yaw = 50,
    this.pitch = 50,
    this.zoom = 1,
    this.dragging = false,
    this.photoFailed = false,
  });

  GalleryView copyWith({
    int? tab,
    int? index,
    bool? full,
    double? yaw,
    double? pitch,
    double? zoom,
    bool? dragging,
    bool? photoFailed,
  }) =>
      GalleryView(
        tab: tab ?? this.tab,
        index: index ?? this.index,
        full: full ?? this.full,
        yaw: yaw ?? this.yaw,
        pitch: pitch ?? this.pitch,
        zoom: zoom ?? this.zoom,
        dragging: dragging ?? this.dragging,
        photoFailed: photoFailed ?? this.photoFailed,
      );
}

/// The property's media: normal photographs and, in the same control, a 360°
/// panorama when one is genuinely finished.
///
/// ```text
/// .sw-gallery
///   .sw-gallery__tabs   Photos | 360° Photo
///   .sw-gallery__stage  one photo, or the panorama viewer, or an empty state
///   .sw-gallery__thumbs thumbnail strip
/// ```
///
/// The panorama viewer is a pan/tilt/zoom control over an equirectangular
/// source: horizontal drag maps to yaw, vertical drag to pitch, and zoom scales
/// the projection. It is deliberately **not** a fake tour — when
/// [PanoramaMedia.isReady] is false the tab shows the supplied reason.
class CombinedMediaGallery extends StatelessComponent {
  final List<String> photoUrls;
  final String propertyTitle;
  final PanoramaMedia panorama;
  final GalleryView view;

  /// Stage height in pixels; the stylesheet overrides it responsively.
  final int height;

  final void Function(int tab) onTab;
  final void Function(int index) onIndex;
  final void Function(int delta) onStep;
  final void Function() onToggleFull;
  final void Function() onPhotoError;

  /// Pointer interactions. Coordinates are viewport pixels; the page keeps the
  /// drag origin and converts them to yaw/pitch.
  final void Function(double x, double y) onDragStart;
  final void Function(double x, double y) onDragMove;
  final void Function() onDragEnd;
  final void Function(double zoom) onZoom;
  final void Function() onResetView;

  const CombinedMediaGallery({
    super.key,
    required this.photoUrls,
    required this.propertyTitle,
    required this.panorama,
    required this.view,
    required this.onTab,
    required this.onIndex,
    required this.onStep,
    required this.onToggleFull,
    required this.onPhotoError,
    required this.onDragStart,
    required this.onDragMove,
    required this.onDragEnd,
    required this.onZoom,
    required this.onResetView,
    this.height = 430,
  });

  List<String> get _photos => [
        for (final url in photoUrls)
          if (url.trim().isNotEmpty) url,
      ];

  @override
  Component build(BuildContext context) {
    final photos = _photos;
    final canPano = panorama.isReady;

    return div(
      classes: 'sw-gallery${view.full ? ' is-full' : ''}',
      [
        div(
          classes: 'sw-gallery__tabs',
          attributes: const {'role': 'tablist', 'aria-label': 'Property media'},
          [
            _tabButton('Photos', 0, '${photos.length} photographs'),
            _tabButton('360° Photo', 1, canPano ? 'Stitched panorama' : 'Not available'),
          ],
        ),
        div(
          classes: 'sw-gallery__stage',
          attributes: {'style': '--sw-gallery-h:${height}px'},
          [if (view.tab == 0) _photoStage(photos) else _panoramaStage()],
        ),
        if (view.tab == 0 && photos.length > 1) _thumbnails(photos),
        if (view.tab == 1 && canPano) _panoramaTools(),
      ],
    );
  }

  Component _tabButton(String label, int index, String hint) {
    final active = view.tab == index;
    return button(
      classes: 'sw-gallery__tab${active ? ' is-active' : ''}',
      attributes: {
        'type': 'button',
        'role': 'tab',
        'aria-selected': active ? 'true' : 'false',
        'aria-label': '$label — $hint',
      },
      events: events(onClick: () => onTab(index)),
      [Component.text(label)],
    );
  }

  // ---------------------------------------------------------------- photographs

  Component _photoStage(List<String> photos) {
    if (photos.isEmpty) {
      return _emptyStage(
        'No photograph recorded',
        'This listing has no photographs yet. Nothing is substituted.',
      );
    }
    final index = view.index.clamp(0, photos.length - 1);
    final url = photos[index];

    return Component.fragment([
      if (view.photoFailed)
        _emptyStage(
          'This photograph could not be loaded',
          'The image link is unavailable. Try another photo, or reload the page.',
        )
      else
        Component.element(
          tag: 'img',
          classes: 'sw-gallery__image',
          attributes: {
            'src': url,
            'alt': '$propertyTitle — photograph ${index + 1} of ${photos.length}',
            'referrerpolicy': 'no-referrer',
            'loading': index == 0 ? 'eager' : 'lazy',
          },
          // A broken image link must degrade to a readable message rather than
          // a browser's broken-image glyph.
          events: {'error': (_) => onPhotoError()},
        ),
      if (photos.length > 1) ...[
        div(classes: 'sw-gallery__count', [
          Component.text('${index + 1} / ${photos.length}'),
        ]),
        _navButton('‹', 'Previous photograph', -1, 'prev'),
        _navButton('›', 'Next photograph', 1, 'next'),
      ],
      button(
        classes: 'sw-gallery__full',
        attributes: {
          'type': 'button',
          'aria-pressed': view.full ? 'true' : 'false',
          'aria-label': view.full ? 'Exit fullscreen' : 'View photograph fullscreen',
        },
        events: events(onClick: onToggleFull),
        [Component.text(view.full ? '✕' : '⤢')],
      ),
    ]);
  }

  Component _navButton(String glyph, String label, int delta, String side) => button(
        classes: 'sw-gallery__nav sw-gallery__nav--$side',
        attributes: {'type': 'button', 'aria-label': label},
        events: events(onClick: () => onStep(delta)),
        [Component.text(glyph)],
      );

  Component _thumbnails(List<String> photos) => div(
        classes: 'sw-gallery__thumbs',
        attributes: const {'role': 'tablist', 'aria-label': 'Photographs'},
        [
          for (var i = 0; i < photos.length; i++)
            button(
              classes: 'sw-gallery__thumb${i == view.index ? ' is-active' : ''}',
              attributes: {
                'type': 'button',
                'role': 'tab',
                'aria-selected': i == view.index ? 'true' : 'false',
                'aria-label': 'Show photograph ${i + 1}',
              },
              events: events(onClick: () => onIndex(i)),
              [
                Component.element(
                  tag: 'img',
                  attributes: {
                    'src': photos[i],
                    'alt': '',
                    'loading': 'lazy',
                    'referrerpolicy': 'no-referrer',
                  },
                ),
              ],
            ),
        ],
      );

  // ------------------------------------------------------------------- panorama

  Component _panoramaStage() {
    if (!panorama.isReady) {
      return _emptyStage(
        panorama.status == 'processing' ? 'Panorama still being stitched' : 'No 360° photo yet',
        panorama.reason.isEmpty
            ? 'A stitched panorama appears here only once its processing has '
                'genuinely finished and the file is accessible.'
            : panorama.reason,
      );
    }

    return Component.fragment([
      div(
        classes: 'sw-pano__stage${view.dragging ? ' is-dragging' : ''}',
        attributes: {
          'role': 'img',
          'aria-label': '360 degree photograph of $propertyTitle. '
              'Drag to look around, or use the zoom controls.',
          'style': 'background-image:url("${panorama.url}");'
              'background-size:${(view.zoom * 100).toStringAsFixed(0)}% auto;'
              'background-position:${view.yaw.toStringAsFixed(2)}% '
              '${view.pitch.toStringAsFixed(2)}%;',
        },
        events: {
          'pointerdown': (event) {
            final pointer = event as web.PointerEvent;
            onDragStart(pointer.clientX.toDouble(), pointer.clientY.toDouble());
          },
          'pointermove': (event) {
            if (!view.dragging) return;
            final pointer = event as web.PointerEvent;
            onDragMove(pointer.clientX.toDouble(), pointer.clientY.toDouble());
          },
          'pointerup': (_) => onDragEnd(),
          'pointercancel': (_) => onDragEnd(),
          'pointerleave': (_) => onDragEnd(),
        },
        const [],
      ),
      div(classes: 'sw-pano__hint', [Component.text('Drag to look around')]),
      button(
        classes: 'sw-gallery__full',
        attributes: {
          'type': 'button',
          'aria-pressed': view.full ? 'true' : 'false',
          'aria-label': view.full ? 'Exit fullscreen' : 'View panorama fullscreen',
        },
        events: events(onClick: onToggleFull),
        [Component.text(view.full ? '✕' : '⤢')],
      ),
    ]);
  }

  Component _panoramaTools() => div(classes: 'sw-pano__tools', [
        button(
          classes: 'sw-pano__tool',
          attributes: {'type': 'button', 'aria-label': 'Zoom in'},
          events: events(onClick: () => onZoom(view.zoom + 0.25)),
          [Component.text('+')],
        ),
        button(
          classes: 'sw-pano__tool',
          attributes: {'type': 'button', 'aria-label': 'Zoom out'},
          events: events(onClick: () => onZoom(view.zoom - 0.25)),
          [Component.text('−')],
        ),
        button(
          classes: 'sw-pano__tool sw-pano__tool--wide',
          attributes: {'type': 'button'},
          events: events(onClick: onResetView),
          [Component.text('Reset view')],
        ),
        span(classes: 'sw-pano__zoom', [
          Component.text('${(view.zoom * 100).round()}%'),
        ]),
      ]);

  // ------------------------------------------------------------------ empty

  Component _emptyStage(String title, String body) => div(
        classes: 'sw-gallery__empty',
        [
          div(
            classes: 'sw-gallery__empty-icon',
            attributes: const {'aria-hidden': 'true'},
            [Component.text(view.tab == 1 ? '360' : '▣')],
          ),
          strong([Component.text(title)]),
          p([Component.text(body)]),
        ],
      );
}
