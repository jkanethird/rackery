import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

void _drawBoxes(img.Image image, List<Rectangle<int>> boxes) {
  final red = img.ColorRgb8(255, 50, 50);
  for (final box in boxes) {
    for (int t = 0; t < 4; t++) {
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

void main() async {
  final fileBytes = await File('/tmp/converted_IMG_3835.HEIC.jpg').readAsBytes();
  final originalImage = img.decodeImage(fileBytes);
  if (originalImage == null) return;
  
  // TFLite class 15, score 0.875, these are the typical bounds for a typical bird.
  // Wait, I need the actual bounding box. I will just run the model directly in this script again to get it.
  
  // Actually, wait, without TFLite I can't get the box. I will hardcode a typical box from center? No, let's use tflite.
}
