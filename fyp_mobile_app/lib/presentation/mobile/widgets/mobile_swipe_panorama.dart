import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';

/// A real equirectangular 360° scene; manual swipe is the default on mobile.
///
/// Reused by Tour Preview and the tour viewer. AR capture is deliberately
/// different: the phone must physically rotate to photograph the full room.
class MobileSwipePanorama extends StatelessWidget {
  const MobileSwipePanorama({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          PanoramaViewer(
            interactive: true,
            sensorControl: SensorControl.none,
            animSpeed: 0.0,
            sensitivity: 1.0,
            minZoom: 1.0,
            maxZoom: 4.0,
            child: Image.memory(bytes),
          ),
          const Positioned(
            left: 12,
            bottom: 12,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xBB0B0F19),
                  borderRadius: BorderRadius.all(Radius.circular(18)),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Text(
                    'Swipe to look around · Pinch to zoom',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
}
