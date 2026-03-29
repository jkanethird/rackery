import 'dart:math';
import 'package:flutter/material.dart';

/// Paints red bounding boxes over a [BoxFit.contain]-scaled image.
///
/// [boxes] are in original image pixel coordinates.
/// [imageSize] is the original image dimensions so that boxes can be scaled
/// to match the rendered layout size.
class BoundingBoxPainter extends CustomPainter {
  final List<Rectangle<int>> boxes;
  final List<String>? names;
  final Size imageSize;

  const BoundingBoxPainter({required this.boxes, this.names, required this.imageSize});

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

    for (int i = 0; i < boxes.length; i++) {
      final box = boxes[i];
      final rect = Rect.fromLTWH(
        box.left * scale + dx,
        box.top * scale + dy,
        box.width * scale,
        box.height * scale,
      );
      
      canvas.drawRect(rect, paint);
      
      if (names != null && i < names!.length) {
        final tp = TextPainter(
          text: TextSpan(
            text: ' ${names![i]} ',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.black54,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        tp.paint(canvas, Offset(rect.left, rect.bottom - tp.height));
      }
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes || 
      oldDelegate.names != names || 
      oldDelegate.imageSize != imageSize;
}
