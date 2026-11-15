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

  /// Indices whose THUMBNAIL url failed. A broken thumbnail must not be
  /// confused with a broken main image, so the two states are independent.
  final Set<int> thumbFailed;

  const GalleryView({
    this.tab = 0,
    this.index = 0,
    this.full = false,
    this.yaw = 50,
    this.pitch = 50,
    this.zoom = 1,
    this.dragging = false,
    this.photoFailed = false,
    this.thumbFailed = const <int>{},
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
    Set<int>? thumbFailed,
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
        thumbFailed: thumbFailed ?? this.thumbFailed,
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
  final void Function(int index) onThumbError;

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
    required this.onThumbError,
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
      attributes: {
        'aria-label': 'Property media gallery',
        // Fullscreen promotes the whole control over the page: make it
        // focusable so keyboard navigation still works even when the
        // thumbnail strip has scrolled out of reach.
        if (view.full) 'tabindex': '0',
      },
      events: {
        'keydown': (event) {
          final key = (event as web.KeyboardEvent).key;
          if ((key == 'Escape' || key == 'Esc') && view.full) {
            onToggleFull();
            return;
          }
          // Arrow/Home/End navigation belongs to the Photos tab only. The
          // 360° tab keeps its own pointer-driven pan/tilt behaviour and is
          // never fed ordinary photographs.
          if (view.tab != 0 || photos.length < 2) return;
          if (key == 'ArrowLeft') {
            event.preventDefault();
            onStep(-1);
          } else if (key == 'ArrowRight') {
            event.preventDefault();
            onStep(1);
          } else if (key == 'Home') {
            event.preventDefault();
            onIndex(0);
          } else if (key == 'End') {
            event.preventDefault();
            onIndex(photos.length - 1);
          }
        },
      },
      [
        div(
          classes: 'sw-gallery__tabs',
          attributes: const {'role': 'tablist', 'aria-label': 'Property media'},
          [
            _tabButton('Photos', 0, '${photos.length} photographs'),
            _tabButton('360° Photo', 1, canPano ? 'View the property in 360°' : 'Not available'),
          ],
        ),
        div(
          classes: 'sw-gallery__stage',
          attributes: {
            'style': '--sw-gallery-h:${height}px',
            'id': 'sw-gallery-stage',
            'role': 'tabpanel',
            'aria-label': view.tab == 0
                ? 'Selected property photograph'
                : '360 degree photograph',
          },
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
        'No photos yet',
        'There are no photos for this property yet.',
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
        Component.fragment([
          // A full-stage placeholder sits UNDER the image. It fills the fixed
          // stage while a photo is decoding, so switching photos never leaves
          // a blank hole or changes the page height. No load-event race: the
          // opaque <img> simply covers it once decoded.
          div(
            classes: 'sw-gallery__placeholder',
            attributes: const {'aria-hidden': 'true'},
            [
              span(classes: 'sw-gallery__placeholder-icon', [
                Component.text('▣'),
              ]),
              span([Component.text('Loading photograph…')]),
            ],
          ),
          Component.element(
            tag: 'img',
            classes: 'sw-gallery__image',
            attributes: {
              'src': url,
              'alt': '$propertyTitle — photograph ${index + 1} of ${photos.length}',
              'referrerpolicy': 'no-referrer',
              // This is always the visible main image, even when it is not
              // index 0, so it must never be lazily loaded.
              'loading': 'eager',
              'decoding': 'async',
            },
            // A broken image link must degrade to a readable message rather
            // than a browser's broken-image glyph.
            events: {'error': (_) => onPhotoError()},
          ),
        ]),
      if (photos.length > 1) ...[
        div(
          classes: 'sw-gallery__count',
          attributes: const {'aria-live': 'polite', 'aria-atomic': 'true'},
          [Component.text('${index + 1} / ${photos.length} Photos')],
        ),
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

  Component _thumbnails(List<String> photos) {
    final selected = view.index.clamp(0, photos.length - 1);
    return div(
      classes: 'sw-gallery__thumbs',
      attributes: const {
        'role': 'tablist',
        'aria-label': 'Select a property photograph',
      },
      [
        for (var i = 0; i < photos.length; i++)
          button(
            classes: 'sw-gallery__thumb${i == selected ? ' is-active' : ''}',
            attributes: {
              'type': 'button',
              'role': 'tab',
              'id': 'sw-gallery-thumb-$i',
              'aria-controls': 'sw-gallery-stage',
              'aria-selected': i == selected ? 'true' : 'false',
              'aria-label': 'Show photograph ${i + 1} of ${photos.length}',
              'title': 'Photograph ${i + 1} of ${photos.length}',
              // Roving focus: one tab stop, then Arrow/Home/End (handled on
              // the gallery root) moves the selection.
              'tabindex': i == selected ? '0' : '-1',
            },
            events: events(onClick: () => onIndex(i)),
            [
              if (view.thumbFailed.contains(i))
                span(
                  classes: 'sw-gallery__thumb-fallback',
                  attributes: const {'aria-hidden': 'true'},
                  [Component.text('▣')],
                )
              else
                Component.element(
                  tag: 'img',
                  attributes: {
                    'src': photos[i],
                    'alt': '',
                    'loading': 'lazy',
                    'referrerpolicy': 'no-referrer',
                  },
                  events: {'error': (_) => onThumbError(i)},
                ),
            ],
          ),
      ],
    );
  }

  // ------------------------------------------------------------------- panorama

  Component _panoramaStage() {
    if (!panorama.isReady) {
      return _emptyStage(
        panorama.status == 'processing' ? '360° photo is being prepared' : 'No 360° photo yet',
        panorama.reason.isEmpty
            ? 'The 360° photo will appear here when it is ready.'
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
