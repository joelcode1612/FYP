import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import 'sitewise_network_image.dart';

/// Fullscreen photo viewer for a property gallery.
///
/// Swipe between photos, pinch/drag-zoom the current one, close with the
/// explicit button or the system back gesture. This is only for ordinary
/// photographs — panoramas open [PropertyPanorama] surfaces instead, so an
/// equirectangular image is never flattened into a photo page.
class PropertyPhotoViewer extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  final String title;

  const PropertyPhotoViewer({
    super.key,
    required this.urls,
    required this.initialIndex,
    required this.title,
  });

  /// Pushes the viewer over the current route.
  static Future<void> open(
    BuildContext context, {
    required List<String> urls,
    required int initialIndex,
    required String title,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PropertyPhotoViewer(
          urls: urls,
          initialIndex: initialIndex,
          title: title,
        ),
      ),
    );
  }

  @override
  State<PropertyPhotoViewer> createState() => _PropertyPhotoViewerState();
}

class _PropertyPhotoViewerState extends State<PropertyPhotoViewer> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _page = widget.initialIndex.clamp(0, widget.urls.length - 1);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.urls.length,
            onPageChanged: (index) => setState(() => _page = index),
            itemBuilder: (context, index) {
              // One InteractiveViewer per page: zoom resets when the page is
              // rebuilt, and pinch gestures never fight the swipe gesture.
              return InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: SitewiseNetworkImage(
                  url: widget.urls[index],
                  fit: BoxFit.contain,
                  semanticLabel:
                      '${widget.title} — photo ${index + 1} of ${widget.urls.length}',
                ),
              );
            },
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ),
                  if (widget.urls.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: SitewiseColors.ink.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${_page + 1} / ${widget.urls.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      iconSize: 26,
                      visualDensity: VisualDensity.compact,
                      color: Colors.white,
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Close photo viewer',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
