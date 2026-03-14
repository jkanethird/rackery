import 'dart:math';
import 'package:flutter/material.dart';

/// Paints red bounding boxes over a [BoxFit.contain]-scaled image.
///
/// [boxes] are in original image pixel coordinates.
/// [imageSize] is the original image dimensions so that boxes can be scaled
/// to match the rendered layout size.
class BoundingBoxPainter extends CustomPainter {
  final List<Rectangle<int>> boxes;
  final Size imageSize;

  const BoundingBoxPainter({required this.boxes, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (boxes.isEmpty) return;

    final paint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    // BoxFit.contain scales uniformly until the image hits the layout boundary.
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;
    final scale = min(scaleX, scaleY);

    // Letterbox/pillarbox offsets when the image is centered.
    final dx = (size.width - imageSize.width * scale) / 2.0;
    final dy = (size.height - imageSize.height * scale) / 2.0;

    for (final box in boxes) {
      canvas.drawRect(
        Rect.fromLTWH(
          box.left * scale + dx,
          box.top * scale + dy,
          box.width * scale,
          box.height * scale,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes || oldDelegate.imageSize != imageSize;
}
