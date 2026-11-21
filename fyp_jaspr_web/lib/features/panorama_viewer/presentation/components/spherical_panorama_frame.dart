import 'package:jaspr/jaspr.dart';

/// Only a browser-accessible URL can be passed to the Three.js panorama frame.
/// A capture-device path is intentionally not rewritten into a fake web URL.
String? browserPanoramaUrl(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return null;
  final parsed = Uri.tryParse(raw);
  if (parsed == null) return null;
  if ((parsed.scheme == 'http' || parsed.scheme == 'https') &&
      parsed.host.isNotEmpty) {
    return raw;
  }
  return raw.startsWith('/') && !raw.startsWith('//') ? raw : null;
}

/// An isolated real spherical panorama. It is deliberately reusable in
/// Property Details, Entrepreneur Tours, and Owner Tour Preview.
class SphericalPanoramaFrame extends StatelessComponent {
  final String imageUrl;
  final String title;

  const SphericalPanoramaFrame({
    super.key,
    required this.imageUrl,
    required this.title,
  });

  @override
  Component build(BuildContext context) => Component.element(
        tag: 'iframe',
        classes: 'sw-pano__iframe',
        attributes: {
          // Fragment, not query: signed-storage URLs do not reach server logs.
          'src': '/sitewise_sphere_panorama.html#image=${Uri.encodeComponent(imageUrl)}',
          'title': title,
          'loading': 'eager',
          'referrerpolicy': 'no-referrer',
          'allowfullscreen': 'true',
          'style': 'display:block;width:100%;height:100%;border:0;'
              'background:#0b0f19;touch-action:none;',
        },
      );
}
