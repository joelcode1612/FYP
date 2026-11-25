// SITEWISE_PROPERTY_DETAIL_REFERENCE_UI_V1
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/components/mobile_property_image.dart';
import 'package:fyp/shared/presentation/components/property_photo_viewer.dart';
import 'package:fyp/shared/presentation/components/sitewise_network_image.dart';

/// Full-width 16:9 property media for a recommendation card.
///
/// * Many photos → a swipeable `PageView` with a `1 / 5` counter; a tap
///   opens the fullscreen viewer at the page in view.
/// * One photo → the same 16:9 surface, no counter, still tappable.
/// * No photo URLs at all → the deterministic painted shoplot via
///   [MobilePropertyImage], exactly as before (demo rows have no URLs).
///
/// Panoramas are NEVER rendered here as flat photos: the equirectangular
/// image only opens through the dedicated 360° viewer, reached by the
/// [tourAction] overlay the card supplies. Loading and error states stay
/// inside each page ([SitewiseNetworkImage] retries with backoff and offers
/// a manual retry), so one broken URL cannot blank the gallery.
///
/// The card composes its overlays (rank, bookmark, 360° chip) on top of the
/// returned Stack so they never scroll with the pages.
class MobilePropertyGallery extends StatefulWidget {
  final CommercialProperty property;

  /// Verified display-photo URLs, primary first. May be empty.
  final List<String> urls;

  /// Alias accepted by the property-detail hero (`photoUrls:`); merged with
  /// [urls] when [urls] is empty.
  final List<String>? photoUrls;

  /// Fixed box height (detail hero). Null keeps the 16:9 aspect ratio.
  final double? height;

  /// Static corner label (e.g. `360° tour`) — a caption, never the tappable
  /// panorama action ([tourAction] is that).
  final String? badge;

  /// Top-left overlay (recommendation rank).
  final Widget? rankBadge;

  /// Top-right overlay (bookmark toggle).
  final Widget? bookmarkButton;

  /// Bottom-left overlay (the 360° chip). Only supply when the backend
  /// reported a *ready* panorama — never for an ordinary wide photo.
  final Widget? tourAction;

  final double aspectRatio;

  /// Opt-in detail-only photo controls; recommendation cards are unchanged.
  final bool detailControls;
  final BorderRadius borderRadius;

  const MobilePropertyGallery({
    super.key,
    required this.property,
    this.urls = const [],
    this.photoUrls,
    this.height,
    this.badge,
    this.rankBadge,
    this.bookmarkButton,
    this.tourAction,
    this.aspectRatio = 16 / 9,
    this.detailControls = false,
    this.borderRadius = const BorderRadius.vertical(
      top: Radius.circular(14),
    ),
  });

  @override
  State<MobilePropertyGallery> createState() => _MobilePropertyGalleryState();
}

class _MobilePropertyGalleryState extends State<MobilePropertyGallery> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<String> get _photos {
    final source = widget.urls.isNotEmpty
        ? widget.urls
        : (widget.photoUrls ?? const []);
    return [for (final url in source) if (url.trim().isNotEmpty) url.trim()];
  }

  void _openViewer() {
    PropertyPhotoViewer.open(
      context,
      urls: _photos,
      initialIndex: _page,
      title: widget.property.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = _photos;
    Widget surface;
    if (photos.isEmpty) {
      // Painted identity for records without any photo URL.
      surface = MobilePropertyImage(
        property: widget.property,
        borderRadius: widget.borderRadius,
      );
    } else {
      surface = PageView.builder(
        controller: _controller,
        itemCount: photos.length,
        physics: photos.length > 1
            ? const PageScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        onPageChanged: (index) => setState(() => _page = index),
        itemBuilder: (context, index) {
          return Semantics(
            image: true,
            label:
                '${widget.property.title} — photo ${index + 1} of ${photos.length}',
            child: SitewiseNetworkImage(
              url: photos[index],
              fit: BoxFit.cover,
              placeholder: const _GalleryPlaceholder(),
            ),
          );
        },
      );
    }
    final tapped = GestureDetector(onTap: _openViewer, child: surface);
    final media = widget.height != null
        ? SizedBox(height: widget.height, child: tapped)
        : AspectRatio(aspectRatio: widget.aspectRatio, child: tapped);
    final bottomLeft = widget.tourAction != null
        ? Positioned(bottom: 10, left: 10, child: widget.tourAction!)
        : (widget.badge != null
              ? Positioned(bottom: 10, left: 10, child: _LabelChip(widget.badge!))
              : null);

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Stack(
        children: [
          media,
          if (widget.rankBadge != null)
            Positioned(top: 8, left: 8, child: widget.rankBadge!),
          if (widget.bookmarkButton != null)
            Positioned(top: 4, right: 4, child: widget.bookmarkButton!),
          ?bottomLeft,
          if (widget.detailControls && photos.isNotEmpty) ...[
            Positioned(top: 10, right: 10, child: _CounterChip(
              current: _page.clamp(0, photos.length - 1).toInt() + 1,
              total: photos.length, onTap: _openViewer)),
            Positioned(bottom: 8, right: 8, child: Material(
              color: SitewiseColors.surface, borderRadius: BorderRadius.circular(12),
              child: IconButton(tooltip: 'Open full screen photos',
                onPressed: _openViewer, icon: const Icon(Icons.fullscreen_rounded,
                  color: SitewiseColors.ink),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
            )),
            if (photos.length > 1 && photos.length <= 10 && widget.tourAction == null)
              Positioned(bottom: 18, left: 64, right: 64, child: IgnorePointer(
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < photos.length; i++)
                    Container(width: 8, height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(shape: BoxShape.circle,
                        color: i == _page ? SitewiseColors.action : Colors.white70,
                        border: Border.all(color: Colors.white, width: 1))),
                ]),
              )),
          ],
          if (!widget.detailControls && photos.length > 1)
            Positioned(
              bottom: 10,
              right: 10,
              child: _CounterChip(
                current: _page + 1,
                total: photos.length,
                onTap: _openViewer,
              ),
            ),
        ],
      ),
    );
  }
}

/// Static caption chip over the media (e.g. `360° tour` on the detail hero).
class _LabelChip extends StatelessWidget {
  final String text;

  const _LabelChip(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: SitewiseColors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.threesixty_rounded,
            size: 14,
            color: SitewiseColors.action,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: SitewiseColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Branded loading surface so a slow network keeps the 16:9 box stable.
class _GalleryPlaceholder extends StatelessWidget {
  const _GalleryPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SitewiseColors.infoWash,
      alignment: Alignment.center,
      child: Semantics(
        label: 'Loading photo',
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation(SitewiseColors.action),
          ),
        ),
      ),
    );
  }
}

/// `1 / 5` pill; doubles as the fullscreen-viewer touch target.
class _CounterChip extends StatelessWidget {
  final int current;
  final int total;
  final VoidCallback onTap;

  const _CounterChip({
    required this.current,
    required this.total,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Photo $current of $total. Open fullscreen gallery.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: SitewiseColors.ink.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$current / $total',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
