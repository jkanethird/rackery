part of 'bird_detector.dart';

// ── Abutting box reconciliation ────────────────────────────────────────────

bool _isAbutting(Rectangle<int> a, Rectangle<int> b) {
  final bool intersectX = a.left <= b.right && a.right >= b.left;
  final bool intersectY = a.top <= b.bottom && a.bottom >= b.top;

  double distX = 0;
  if (!intersectX)
    distX = a.right < b.left
        ? (b.left - a.right).toDouble()
        : (a.left - b.right).toDouble();
  double distY = 0;
  if (!intersectY)
    distY = a.bottom < b.top
        ? (b.top - a.bottom).toDouble()
        : (a.top - b.bottom).toDouble();

  double dist = sqrt(distX * distX + distY * distY);
  double threshold = min(a.width, b.width) * 0.15;
  if (threshold < 15) threshold = 15;
  if (threshold > 50) threshold = 50;

  return dist <= threshold;
}

typedef _ReInferCallback =
    Future<List<_RawDetection>> Function(List<Rectangle<int>> customTiles);

Future<List<_RawDetection>> _reconcileAbuttingBoxes(
  List<_RawDetection> initialDetections,
  int origW,
  int origH,
  _ReInferCallback performReInference,
) async {
  List<Set<_RawDetection>> clusters = [];
  for (final d in initialDetections) {
    if (d.sourceTile == null) continue;

    List<int> touchingIndices = [];
    for (int i = 0; i < clusters.length; i++) {
      for (final other in clusters[i]) {
        if (d != other && _isAbutting(d.box, other.box)) {
          touchingIndices.add(i);
          break;
        }
      }
    }

    if (touchingIndices.isEmpty) {
      clusters.add({d});
    } else {
      Set<_RawDetection> merged = {d};
      for (final idx in touchingIndices.reversed) {
        merged.addAll(clusters[idx]);
        clusters.removeAt(idx);
      }
      clusters.add(merged);
    }
  }

  final targetClusters = clusters.where((c) => c.length > 1).toList();
  if (targetClusters.isEmpty) return initialDetections;

  List<Rectangle<int>> customTiles = [];
  for (final cluster in targetClusters) {
    int minX = cluster.map((d) => d.box.left).reduce(min);
    int minY = cluster.map((d) => d.box.top).reduce(min);
    int maxX = cluster.map((d) => d.box.right).reduce(max);
    int maxY = cluster.map((d) => d.box.bottom).reduce(max);

    int w = maxX - minX;
    int h = maxY - minY;

    // Force a perfectly square custom tile to prevent aspect ratio distortion
    // when scaling down to model input size (usually 320x320)
    int maxDim = max(w, h);
    int pad = (maxDim * 0.3).toInt(); // 30% padding
    int size = maxDim + pad * 2;

    int cx = minX + (w ~/ 2) - (size ~/ 2);
    int cy = minY + (h ~/ 2) - (size ~/ 2);

    // Clamp safely to image boundaries
    if (cx < 0) {
      cx = 0;
    } else if (cx + size > origW) {
      cx = max(0, origW - size);
    }

    if (cy < 0) {
      cy = 0;
    } else if (cy + size > origH) {
      cy = max(0, origH - size);
    }

    int cw = min(size, origW - cx);
    int ch = min(size, origH - cy);

    customTiles.add(Rectangle<int>(cx, cy, cw, ch));
  }

  final newDetections = await performReInference(customTiles);

  List<_RawDetection> finalized = List.from(initialDetections);
  for (int i = 0; i < targetClusters.length; i++) {
    final cluster = targetClusters[i];
    final macroBox = Rectangle<int>(
      cluster.map((d) => d.box.left).reduce(min),
      cluster.map((d) => d.box.top).reduce(min),
      cluster.map((d) => d.box.right).reduce(max) -
          cluster.map((d) => d.box.left).reduce(min),
      cluster.map((d) => d.box.bottom).reduce(max) -
          cluster.map((d) => d.box.top).reduce(min),
    );

    final List<_RawDetection> mainReplacements = newDetections.where((d) {
      final inter = macroBox.intersection(d.box);
      if (inter == null) return false;

      // We consider it a "main replacement bird" if it covers a large portion of the macroBox
      // OR if the macroBox covers a large portion of it.
      double interArea = (inter.width * inter.height).toDouble();
      return interArea > 0.4 * (macroBox.width * macroBox.height);
    }).toList();

    // If exactly one bird acts as the main replacement for the entire cluster
    if (mainReplacements.length == 1) {
      for (final oldDet in cluster) {
        finalized.removeWhere((fd) => fd.box == oldDet.box);
      }
      finalized.add(mainReplacements.first);
    }
  }

  return finalized;
}
