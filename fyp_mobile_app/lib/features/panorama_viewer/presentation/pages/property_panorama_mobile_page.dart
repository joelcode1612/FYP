import 'dart:typed_data';
import 'dart:ui' show instantiateImageCodec;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:panorama_viewer/panorama_viewer.dart';

import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/core/utils/pano_bytes.dart';

/// Immersive 360° viewer for ONE server-verified property panorama.
///
/// The URL only ever comes from the backend's `ready` panorama state — a
/// completed stitching job behind a verified subject link — so this page
/// never guesses whether an image is panoramic, and an ordinary wide photo
/// can never land here. The image is rendered through the existing
/// spherical-projection viewer (equirectangular → sphere, drag to look
/// around, pinch to zoom); it is never shown as a flat photograph.
///
/// Handles the honest failure states: loading, unreachable or expired URL,
/// unreadable bytes, and an unsupported format — each with a visible way
/// back (Close/Back) and a retry where retrying makes sense.
class PropertyPanoramaMobilePage extends StatefulWidget {
  final String panoramaUrl;
  final String propertyTitle;

  const PropertyPanoramaMobilePage({
    super.key,
    required this.panoramaUrl,
    this.propertyTitle = '',
  });

  @override
  State<PropertyPanoramaMobilePage> createState() =>
      _PropertyPanoramaMobilePageState();
}

enum _LoadState { loading, ready, failed }

class _PropertyPanoramaMobilePageState
    extends State<PropertyPanoramaMobilePage> {
  _LoadState _state = _LoadState.loading;
  Uint8List? _bytes;
  String _failure = '';

  static const _timeout = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _state = _LoadState.loading;
      _failure = '';
    });
    final url = widget.panoramaUrl.trim();
    try {
      final uri = Uri.tryParse(url);
      Uint8List? bytes;
      if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
        // Supabase signed URLs expire — a 400/403 here is the honest
        // "link expired" state, retried by re-opening from the card.
        final response = await http.get(uri).timeout(_timeout);
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          bytes = response.bodyBytes;
        } else if (response.statusCode == 401 || response.statusCode == 403) {
          bytes = null;
          _failure =
              'This panorama link has expired. Close and reopen it from the '
              'property card for a fresh link.';
        } else {
          bytes = null;
          _failure =
              'The panorama file could not be reached '
              '(server said ${response.statusCode}).';
        }
      } else {
        bytes = await readPanoramaBytes(
          url,
        ).timeout(_timeout, onTimeout: () => null);
        if (bytes == null) {
          _failure = 'The panorama file is missing from this device.';
        }
      }
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _state = _LoadState.failed;
          if (_failure.isEmpty) {
            _failure = 'The panorama file could not be loaded.';
          }
        });
        return;
      }
      // Decode once up front: an unsupported/corrupt format must land in the
      // honest failure state, not inside the GL viewer.
      final codec = await instantiateImageCodec(bytes);
      if (codec.frameCount == 0) {
        if (!mounted) return;
        setState(() {
          _state = _LoadState.failed;
          _failure = 'This panorama format is not supported on this device.';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _state = _LoadState.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.failed;
        _failure = 'A network problem stopped the panorama from loading.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SitewiseColors.ink,
      appBar: AppBar(
        backgroundColor: SitewiseColors.ink,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, size: 26),
          tooltip: 'Close 360° view',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '360° view',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            if (widget.propertyTitle.isNotEmpty)
              Text(
                widget.propertyTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.78),
                ),
              ),
          ],
        ),
      ),
      body: switch (_state) {
        _LoadState.loading => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation(SitewiseColors.accent),
              ),
              const SizedBox(height: 14),
              const Text(
                'Loading the 360° view…',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
        _LoadState.failed => _failureView(),
        _LoadState.ready => _viewerView(),
      },
    );
  }

  Widget _viewerView() {
    return Semantics(
      label:
          '360° panorama of ${widget.propertyTitle.isEmpty ? 'this property' : widget.propertyTitle}. '
          'Drag to look around. Pinch to zoom.',
      child: Stack(
        fit: StackFit.expand,
        children: [
          PanoramaViewer(
            child: Image.memory(_bytes!, filterQuality: FilterQuality.low),
          ),
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.open_with_rounded,
                      size: 15,
                      color: Colors.white70,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Drag to look around · pinch to zoom',
                      style: TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _failureView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.image_not_supported_outlined,
              size: 40,
              color: Colors.white70,
            ),
            const SizedBox(height: 12),
            Text(
              _failure,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    foregroundColor: SitewiseColors.accent,
                  ),
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(96, 44),
                    backgroundColor: SitewiseColors.action,
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
