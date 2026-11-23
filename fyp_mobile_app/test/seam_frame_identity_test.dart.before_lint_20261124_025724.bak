import 'dart:typed_data';
import '../lib/features/capture_360/domain/sphere/graph_cut_seams.dart';

void main() {
  const pixels = 128;
  final best = Int16List.fromList(
    List.generate(pixels, (i) => i % 4 == 0 ? 1 : 0),
  );
  final second = Int16List.fromList(best.map((id) => 1 - id).toList());
  final labels = findSeamLabels(
    width: 16,
    height: 8,
    bestColour: Uint8List(pixels * 3),
    secondColour: Uint8List(pixels * 3)..fillRange(0, pixels * 3, 200),
    bestWeight: Float32List(pixels)..fillRange(0, pixels, 0.8),
    secondWeight: Float32List(pixels)..fillRange(0, pixels, 0.79),
    bestFrame: best,
    secondFrame: second,
    minWeight: 0.001,
    seamCostWeight: 20,
  )!;
  for (var i = 0; i < pixels; i++) {
    if ((labels[i] == 0 ? best[i] : second[i]) != 0)
      throw StateError('Wrong source at pixel $i');
  }
}
