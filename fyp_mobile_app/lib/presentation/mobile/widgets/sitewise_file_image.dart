import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/utils/pano_bytes.dart';
import '../../../core/theme/sitewise_theme.dart';

/// Local-file image (captured frame, generated panorama) with rebuild-safe
/// loading: the file is read ONCE per path and the bytes are held by this
/// widget's state, so parent rebuilds (stepper changes, dialog opens, every
/// frame of an animation) never re-read the file or rebuild the decode.
///
/// A missing or unreadable file renders an honest, neutral unavailable panel
/// with a manual retry — never a spinner that spins forever and never a raw
/// filesystem error.
class SitewiseFileImage extends StatefulWidget {
  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? unavailable;
  final String? semanticLabel;

  const SitewiseFileImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.unavailable,
    this.semanticLabel,
  });

  @override
  State<SitewiseFileImage> createState() => _SitewiseFileImageState();
}

class _SitewiseFileImageState extends State<SitewiseFileImage> {
  /// One read attempt per widget instance; recreated only by [retry]. The
  /// path changing (retake replaced the file) restarts the load.
  Future<Uint8List?>? _future;

  /// Distinguishes "still loading" from "gone for good" once the future
  /// completes with null.
  bool _settledUnavailable = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant SitewiseFileImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _start();
  }

  void _start() {
    _settledUnavailable = false;
    // Guard against a file that never answers: readPanoramaBytes itself is
    // try/catch-safe, but a hung filesystem call must not pin a spinner.
    _future = readImageBytes(widget.path).timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
  }

  void _retry() {
    if (!mounted) return;
    setState(_start);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return widget.placeholder ?? const _LoadingBox();
          }
          final bytes = snap.data;
          if (bytes == null) {
            _settledUnavailable = true;
            return widget.unavailable ?? _unavailableBox();
          }
          return Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            semanticLabel: widget.semanticLabel,
            errorBuilder: (context, error, stackTrace) {
              _settledUnavailable = true;
              return widget.unavailable ?? _unavailableBox();
            },
          );
        },
      ),
    );
  }

  Widget _unavailableBox() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: _retry,
    child: Container(
      color: SitewiseColors.surface,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.image_not_supported_outlined,
            size: 26,
            color: SitewiseColors.muted,
          ),
          const SizedBox(height: 6),
          Text(
            _settledUnavailable
                ? 'Image unavailable. Tap to retry'
                : 'Image not found on this device.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
          ),
        ],
      ),
    ),
  );
}

class _LoadingBox extends StatelessWidget {
  const _LoadingBox();

  @override
  Widget build(BuildContext context) => Container(
    color: SitewiseColors.surface,
    alignment: Alignment.center,
    child: const SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}
