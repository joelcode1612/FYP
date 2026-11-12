import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../../core/utils/pano_bytes.dart';

/// Mobile tour viewer: displays a generated panoramic file as a static image.
/// When the image is unavailable, retains the scene navigation controls and
/// the existing tour contract. There is no interactive 360° panning.

class MobileTourViewer extends StatefulWidget {
  final VirtualTour tour;

  const MobileTourViewer({super.key, required this.tour});

  @override
  State<MobileTourViewer> createState() => _MobileTourViewerState();
}

class _MobileTourViewerState extends State<MobileTourViewer> {
  int scene = 0;

  void _go(int i) =>
      setState(() => scene = i.clamp(0, widget.tour.sceneCount - 1));

  /// Cached panorama read: the file is read once per path, so rebuilds from
  /// scene switches and control taps never re-read it. A timeout bounds the
  /// wait; a null result renders the honest retry state instead of a spinner
  /// that never ends.
  String? _cachedPanoPath;
  Future<Uint8List?>? _cachedPanoFuture;

  Future<Uint8List?> _panoFutureFor(String path) {
    if (_cachedPanoPath != path) {
      _cachedPanoPath = path;
      _cachedPanoFuture = readPanoramaBytes(
        path,
      ).timeout(const Duration(seconds: 8), onTimeout: () => null);
    }
    return _cachedPanoFuture!;
  }

  /// Static preview of a generated equirectangular image (if available).
  Widget _panoBox(String path) {
    return Container(
      height: 340,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
        color: Colors.black,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: FutureBuilder<Uint8List?>(
          future: _panoFutureFor(path),
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final bytes = snap.data;
            if (bytes == null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.image_not_supported_outlined,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'Panorama unavailable. Re-generate it from the tour preview.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            return Image.memory(
              bytes,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Icon(
                  Icons.image_not_supported_outlined,
                  color: Colors.white70,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final panoPath = widget.tour.panoramaPath;
    if (panoPath != null) {
      return _panoBox(panoPath);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 340,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [SitewiseColors.ink, Color(0xFF334155)],
            ),
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.photo_library_outlined,
                      size: 64,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        widget.tour.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      'Scene ${scene + 1} of ${widget.tour.sceneCount}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Previous scene',
                  iconSize: 44,
                  icon: const Icon(Icons.chevron_left, color: Colors.white),
                  onPressed: scene > 0 ? () => _go(scene - 1) : null,
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Next scene',
                  iconSize: 44,
                  icon: const Icon(Icons.chevron_right, color: Colors.white),
                  onPressed: scene < widget.tour.sceneCount - 1
                      ? () => _go(scene + 1)
                      : null,
                ),
              ),
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    widget.tour.sceneCount,
                    (i) => Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == scene
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: widget.tour.sceneCount,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (c, i) => ChoiceChip(
              label: Text('Scene ${i + 1}'),
              selected: i == scene,
              onSelected: (_) => _go(i),
            ),
          ),
        ),
      ],
    );
  }
}
