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

  const BoundingBoxPainter({
    required this.boxes,
    this.names,
    required this.imageSize,
  });

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
        double yOffset = rect.bottom - tp.height;
        if (tp.height > rect.height * 0.5) {
          // If the box is extremely short, push the name caption outside below it
          yOffset = rect.bottom + 2.0;
        }
        tp.paint(canvas, Offset(rect.left, yOffset));
      }
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes ||
      oldDelegate.names != names ||
      oldDelegate.imageSize != imageSize;
}

class DrawingBoxPainter extends CustomPainter {
  final Offset start;
  final Offset end;

  DrawingBoxPainter(this.start, this.end);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(start, end);
    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, paint);

    final borderPaint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(rect, borderPaint);
  }

  @override
  bool shouldRepaint(DrawingBoxPainter oldDelegate) {
    return oldDelegate.start != start || oldDelegate.end != end;
  }
}
