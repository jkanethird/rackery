import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Parameters for [annotateAndEncode], passed via [compute] isolation.
class AnnotationParams {
  final img.Image image;
  final List<Rectangle<int>> boxes;
  final int originalWidth;
  final int originalHeight;

  AnnotationParams(
    this.image,
    this.boxes,
    this.originalWidth,
    this.originalHeight,
  );
}

/// Top-level function (required for [compute] isolation): annotates the image
/// with red bounding boxes and encodes it to JPEG for the vision model.
List<int> annotateAndEncode(AnnotationParams params) {
  img.Image source = params.image;
  final boxes = params.boxes;
  img.Image region;

  if (boxes.length == 1) {
    // For a single detected bird, crop with 50% padding so the bird
    // is the prominent subject but has enough habitat/environment context.
    final box = boxes.first;
    final padX = (box.width * 0.5).round();
    final padY = (box.height * 0.5).round();

    final cropX1 = (box.left - padX).clamp(0, source.width - 1);
    final cropY1 = (box.top - padY).clamp(0, source.height - 1);
    final cropX2 = (box.left + box.width + padX).clamp(1, source.width);
    final cropY2 = (box.top + box.height + padY).clamp(1, source.height);

    region = img.copyCrop(
      source,
      x: cropX1,
      y: cropY1,
      width: cropX2 - cropX1,
      height: cropY2 - cropY1,
    );

    // Upscale small crops so the bird is large enough to identify
    if (region.width < 640 || region.height < 640) {
      final scale = 640 / max(region.width, region.height);
      final newW = (region.width * scale).round();
      final newH = (region.height * scale).round();
      region = img.copyResize(region, width: newW, height: newH);
    }
  } else {
    // For multi-bird clusters use the full image so all boxes are visible.
    region = source;
    drawBoxes(region, boxes);
  }

  // Downscale to at most 1024px on longest edge to fit vision model positional limits
  if (region.width > 1024 || region.height > 1024) {
    final scale = 1024 / max(region.width, region.height);
    region = img.copyResize(
      region,
      width: (region.width * scale).round(),
      height: (region.height * scale).round(),
    );
  }

  return img.encodeJpg(region, quality: 90);
}

/// Draws thick red bounding boxes on [image] for each entry in [boxes].
void drawBoxes(img.Image image, List<Rectangle<int>> boxes) {
  final red = img.ColorRgb8(255, 50, 50);
  for (final box in boxes) {
    for (int t = 0; t < 12; t++) {
      img.drawRect(
        image,
        x1: (box.left - t).clamp(0, image.width - 1),
        y1: (box.top - t).clamp(0, image.height - 1),
        x2: (box.left + box.width + t).clamp(0, image.width - 1),
        y2: (box.top + box.height + t).clamp(0, image.height - 1),
        color: red,
      );
    }
  }
}
