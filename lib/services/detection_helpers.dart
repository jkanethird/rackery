// Rackery - Automatic bird identification and eBird checklist generation.
// Copyright (C) 2026 Joseph J. Kane III
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

part of 'bird_detector.dart';

// ── Shared helpers ─────────────────────────────────────────────────────────

/// Generates overlapping tile rectangles for a given image size.
List<Rectangle<int>> _buildTiles(int origW, int origH) {
  const int tileSize = 1536;
  const int stride = tileSize ~/ 2;

  List<Rectangle<int>> tiles = [Rectangle<int>(0, 0, origW, origH)];

  if (origW > tileSize || origH > tileSize) {
    for (int y = 0; y < origH; y += stride) {
      for (int x = 0; x < origW; x += stride) {
        int cropX = x;
        int cropY = y;

        if (cropX + tileSize > origW) cropX = max(0, origW - tileSize);
        if (cropY + tileSize > origH) cropY = max(0, origH - tileSize);

        int cropW = min(tileSize, origW - cropX);
        int cropH = min(tileSize, origH - cropY);

        tiles.add(Rectangle<int>(cropX, cropY, cropW, cropH));
      }
    }
  }

  return tiles.toSet().toList();
}

/// Builds a [1,H,W,3] int tensor from an img.Image.
List<List<List<List<int>>>> _buildTensor(
  img.Image imageInput,
  int targetW,
  int targetH,
) {
  return List.generate(
    1,
    (_) => List.generate(
      targetH,
      (y) => List.generate(targetW, (x) {
        final pixel = imageInput.getPixel(x, y);
        return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
      }),
    ),
  );
}

/// Allocates fresh TFLite output buffers.
Map<int, Object> _allocateOutputs() => {
  0: List<List<List<double>>>.filled(1, List.filled(25, List.filled(4, 0.0))),
  1: List<List<double>>.filled(1, List.filled(25, 0.0)),
  2: List<List<double>>.filled(1, List.filled(25, 0.0)),
  3: List<double>.filled(1, 0.0),
};

/// Extracts valid bird detections from TFLite inference outputs for one tile.
List<_RawDetection> _extractDetections(
  Map<int, Object> outputs,
  Rectangle<int> tile,
  int origW,
  int origH,
) {
  final locations = outputs[0] as List<List<List<double>>>;
  final classes = outputs[1] as List<List<double>>;
  final scores = outputs[2] as List<List<double>>;
  final counts = outputs[3] as List<double>;

  final int count = counts[0].toInt();
  final List<_RawDetection> detections = [];

  for (int i = 0; i < count; i++) {
    final double score = scores[0][i];
    final int detectedClass = classes[0][i].toInt();

    if (score <= 0.45 || (detectedClass != 16 && detectedClass != 15)) continue;

    final box = locations[0][i];
    final double ymin = box[0].clamp(0.0, 1.0);
    final double xmin = box[1].clamp(0.0, 1.0);
    final double ymax = box[2].clamp(0.0, 1.0);
    final double xmax = box[3].clamp(0.0, 1.0);

    if ((xmin <= 0.02 && tile.left > 0) ||
        (ymin <= 0.02 && tile.top > 0) ||
        (xmax >= 0.98 && tile.right < origW) ||
        (ymax >= 0.98 && tile.bottom < origH)) {
      continue;
    }

    int localW = ((xmax - xmin) * tile.width).toInt();
    int localH = ((ymax - ymin) * tile.height).toInt();
    int globalX = ((xmin * tile.width) + tile.left).toInt();
    int globalY = ((ymin * tile.height) + tile.top).toInt();

    globalX = globalX.clamp(0, origW - 1);
    globalY = globalY.clamp(0, origH - 1);
    localW = localW.clamp(1, origW - globalX);
    localH = localH.clamp(1, origH - globalY);

    final double aspectRatio = localW / localH;
    if (localW < 10 || localH < 10 || aspectRatio > 5.0 || aspectRatio < 0.20) {
      continue;
    }

    detections.add(
      _RawDetection(
        Rectangle<int>(globalX, globalY, localW, localH),
        score,
        tile,
      ),
    );
  }

  return detections;
}

/// Non-maximum suppression: removes duplicate overlapping detections.
List<_RawDetection> _applyNms(List<_RawDetection> rawDetections) {
  rawDetections.sort((a, b) => b.score.compareTo(a.score));

  final List<_RawDetection> kept = [];
  for (var current in rawDetections) {
    bool isDuplicate = false;
    for (var existing in kept) {
      final intersect = existing.box.intersection(current.box);
      if (intersect != null && intersect.width > 0 && intersect.height > 0) {
        final double intersectArea = (intersect.width * intersect.height)
            .toDouble();
        final double area1 = (current.box.width * current.box.height)
            .toDouble();
        final double area2 = (existing.box.width * existing.box.height)
            .toDouble();
        final double iou = intersectArea / (area1 + area2 - intersectArea);
        final double ioMin = intersectArea / min(area1, area2);

        final double cx1 = current.box.left + current.box.width / 2;
        final double cy1 = current.box.top + current.box.height / 2;
        final double cx2 = existing.box.left + existing.box.width / 2;
        final double cy2 = existing.box.top + existing.box.height / 2;

        final double centerDist = sqrt(pow(cx1 - cx2, 2) + pow(cy1 - cy2, 2));
        final double distThreshold =
            (current.box.width +
                existing.box.width +
                current.box.height +
                existing.box.height) /
            8;

        if (iou > 0.30 ||
            ioMin > 0.50 ||
            (iou > 0.10 && centerDist < distThreshold)) {
          isDuplicate = true;
          break;
        }
      }
    }
    if (!isDuplicate) kept.add(current);
  }

  return kept;
}

/// Crops detected birds from the original image, extracts center color, and
/// JPG-encodes each crop.
List<BirdCrop> _cropAndEncode(
  img.Image originalImage,
  List<_RawDetection> detections,
) {
  final List<BirdCrop> crops = [];

  for (final det in detections) {
    // 1. Unpadded crop for accurate color extraction
    final unpadded = img.copyCrop(
      originalImage,
      x: det.box.left,
      y: det.box.top,
      width: det.box.width,
      height: det.box.height,
    );

    final w = unpadded.width;
    final h = unpadded.height;
    final int startX = (w * 0.4).toInt();
    final int startY = (h * 0.4).toInt();
    final int endX = (w * 0.6).toInt();
    final int endY = (h * 0.6).toInt();

    List<double> color = [0.0, 0.0, 0.0];
    if (startX < endX && startY < endY) {
      double sumR = 0, sumG = 0, sumB = 0;
      int count = 0;
      for (int y = startY; y < endY; y++) {
        for (int x = startX; x < endX; x++) {
          final pixel = unpadded.getPixel(x, y);
          sumR += pixel.r.toDouble();
          sumG += pixel.g.toDouble();
          sumB += pixel.b.toDouble();
          count++;
        }
      }
      if (count > 0) {
        color = [sumR / count, sumG / count, sumB / count];
      }
    } else if (w > 0 && h > 0) {
      final centerPixel = unpadded.getPixel(w ~/ 2, h ~/ 2);
      color = [
        centerPixel.r.toDouble(),
        centerPixel.g.toDouble(),
        centerPixel.b.toDouble(),
      ];
    }

    // 2. Padded crop for the UI icon so it doesn't look cut-off or blurry
    final padX = (det.box.width * 0.5).round();
    final padY = (det.box.height * 0.5).round();

    final cropX1 = (det.box.left - padX).clamp(0, originalImage.width - 1);
    final cropY1 = (det.box.top - padY).clamp(0, originalImage.height - 1);
    final cropX2 = (det.box.left + det.box.width + padX).clamp(
      1,
      originalImage.width,
    );
    final cropY2 = (det.box.top + det.box.height + padY).clamp(
      1,
      originalImage.height,
    );

    var padded = img.copyCrop(
      originalImage,
      x: cropX1,
      y: cropY1,
      width: cropX2 - cropX1,
      height: cropY2 - cropY1,
    );

    // Upscale small crops so the bird is large enough to identify in the UI
    if (padded.width < 150 || padded.height < 150) {
      final scale = 150 / max(padded.width, padded.height);
      final newW = (padded.width * scale).round();
      final newH = (padded.height * scale).round();
      padded = img.copyResize(
        padded,
        width: newW,
        height: newH,
        interpolation: img.Interpolation.linear,
      );
    }

    final jpgBytes = Uint8List.fromList(img.encodeJpg(padded, quality: 90));
    crops.add(BirdCrop(jpgBytes, color, det.score, det.box));
  }

  return crops;
}
