import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:fyp/features/panorama_viewer/presentation/widgets/mobile_swipe_panorama.dart';

/// Fullscreen inspection of one stitched panorama.
///
/// The Agent must be able to look around the ENTIRE result before uploading
/// it, so the same interactive [MobileSwipePanorama] (swipe all directions,
/// pinch to zoom) is hosted edge-to-edge on black — no cards, no chrome —
/// with a close affordance in the safe area. The bytes are passed in, so no
/// second read or re-decode happens and the fullscreen view shows exactly the
/// image that was previewed.
class PanoramaFullscreenPage extends StatelessWidget {
  const PanoramaFullscreenPage({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('360° full screen'),
      ),
      body: SafeArea(top: false, child: MobileSwipePanorama(bytes: bytes)),
    );
  }
}
