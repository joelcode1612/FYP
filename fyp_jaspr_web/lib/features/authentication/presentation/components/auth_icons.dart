import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Inline SVG icons that match the entrepreneur auth design
/// (`sitewise-entrepreneur/assets/css/auth.css`). Field icons inherit
/// `currentColor` so they pick up the field's ink colour. These replace the
/// design's `<svg>` markup 1:1 so the port is pixel-faithful without pulling
/// the design's `assets/js/*` (which only did client-side validation).
///
/// The brand mark and social logos are exact copies of the design's paths.

Component _strokeSvg(List<String> paths) => svg(
  attributes: {
    'viewBox': '0 0 24 24',
    'width': '17',
    'height': '17',
    'fill': 'none',
    'stroke': 'currentColor',
    'stroke-width': '1.8',
    'stroke-linecap': 'round',
    'stroke-linejoin': 'round',
  },
  [
    for (final d in paths) path(attributes: {'d': d}, []),
  ],
);

Component authIconEmail() => _strokeSvg(['M2.5 5h19v14h-19z', 'M3 7l9 6 9-6']);

Component authIconLock() =>
    _strokeSvg(['M4 10h16v10h-16z', 'M8 10V7a4 4 0 0 1 8 0v3']);

Component authIconLockCheck() => _strokeSvg([
  'M4 10h16v10h-16z',
  'M8 10V7a4 4 0 0 1 8 0v3',
  'M10 15l1.6 1.6L15 13',
]);

Component authIconUser() => _strokeSvg([
  'M8.4 8a3.6 3.6 0 1 0 7.2 0a3.6 3.6 0 1 0 -7.2 0',
  'M4.5 20a7.5 7.5 0 0 1 15 0',
]);

Component authBrandMark() => Component.element(
  tag: 'img',
  classes: 'auth-brand-mark-img',
  attributes: {
    'src': '/assets/sitewise-mark-64.png',
    'alt': 'Sitewise',
    'width': '14',
    'height': '14',
  },
  children: [],
);

Component authSocialFacebook() => svg(
  attributes: {
    'viewBox': '0 0 24 24',
    'width': '19',
    'height': '19',
    'fill': '#1877f2',
  },
  [
    path(
      attributes: {
        'd':
            'M13.5 21v-8h2.7l.4-3.1h-3.1V7.9c0-.9.25-1.5 1.55-1.5h1.65'
            'V3.6c-.3-.04-1.3-.13-2.45-.13-2.43 0-4.1 1.48-4.1 4.2v2.23H7.4V13'
            'h2.75v8h3.35Z',
      },
      [],
    ),
  ],
);

Component authSocialGoogle() => svg(
  attributes: {'viewBox': '0 0 24 24', 'width': '19', 'height': '19'},
  [
    path(
      attributes: {
        'fill': '#4285f4',
        'd':
            'M21.6 12.2c0-.7-.06-1.2-.19-1.8H12v3.4h5.4c-.11.9-.7 2.2-2 3.1'
            'l3.1 2.4c1.9-1.7 3.1-4.3 3.1-7.1Z',
      },
      [],
    ),
    path(
      attributes: {
        'fill': '#34a853',
        'd':
            'M12 22c2.7 0 5-.9 6.6-2.4l-3.1-2.4c-.9.6-2 1-3.5 1a6 6 0 0 1-5.7-4.1'
            'l-3.2 2.5A10 10 0 0 0 12 22Z',
      },
      [],
    ),
    path(
      attributes: {
        'fill': '#fbbc05',
        'd': 'M6.3 14.1a6 6 0 0 1 0-4.2L3.1 7.4a10 10 0 0 0 0 9.2l3.2-2.5Z',
      },
      [],
    ),
    path(
      attributes: {
        'fill': '#ea4335',
        'd':
            'M12 6.1c1.9 0 3.2.8 3.9 1.5l2.8-2.7A9.6 9.6 0 0 0 12 2a10 10 0 0 0-8.9 5.4'
            'l3.2 2.5A6 6 0 0 1 12 6.1Z',
      },
      [],
    ),
  ],
);

Component authSocialApple() => svg(
  attributes: {
    'viewBox': '0 0 24 24',
    'width': '19',
    'height': '19',
    'fill': '#0b0f19',
  },
  [
    path(
      attributes: {
        'd':
            'M16.4 12.7c0-2 1.6-3 1.7-3.05-.9-1.35-2.35-1.53-2.86-1.55'
            '-1.22-.12-2.38.72-3 .72-.62 0-1.57-.7-2.58-.68-1.33.02-2.55.77-3.23 1.96'
            '-1.38 2.4-.35 5.95 1 7.9.66.95 1.44 2.02 2.47 1.98 1-.04 1.37-.64 2.57-.64'
            's1.54.64 2.6.62c1.07-.02 1.75-.97 2.4-1.93.76-1.1 1.07-2.17 1.08-2.23'
            '-.02-.01-2.07-.8-2.15-3.1ZM14.5 6.7c.55-.66.92-1.58.82-2.5'
            '-.79.03-1.75.53-2.32 1.19-.51.58-.95 1.52-.83 2.42.88.07 1.78-.45 2.33-1.11Z',
      },
      [],
    ),
  ],
);
