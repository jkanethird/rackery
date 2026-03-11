// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import
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
  final tempPath = '/tmp/converted_IMG_3835.HEIC.jpg';
  
  final fileBytes = await File(tempPath).readAsBytes();
  final originalImage = img.decodeImage(fileBytes);
  if (originalImage == null) return;
  
  final bestBox = Rectangle<int>(1993, 1332, 457, 507);

  final padX = (bestBox.width * 0.8).round();
  final padY = (bestBox.height * 0.8).round();

  final cropX1 = (bestBox.left - padX).clamp(0, originalImage.width - 1);
  final cropY1 = (bestBox.top - padY).clamp(0, originalImage.height - 1);
  final cropX2 = (bestBox.left + bestBox.width + padX).clamp(1, originalImage.width);
  final cropY2 = (bestBox.top + bestBox.height + padY).clamp(1, originalImage.height);

  img.Image region = img.copyCrop(
    originalImage,
    x: cropX1,
    y: cropY1,
    width: cropX2 - cropX1,
    height: cropY2 - cropY1,
  );

  final relBox = Rectangle<int>(
    bestBox.left - cropX1,
    bestBox.top - cropY1,
    bestBox.width,
    bestBox.height,
  );

  if (region.width < 400 || region.height < 400) {
    final scale = 400 / max(region.width, region.height);
    final newW = (region.width * scale).round();
    final newH = (region.height * scale).round();
    final scaleX = newW / region.width;
    final scaleY = newH / region.height;
    final scaled = Rectangle<int>(
      (relBox.left * scaleX).round(),
      (relBox.top * scaleY).round(),
      (relBox.width * scaleX).round(),
      (relBox.height * scaleY).round(),
    );
    region = img.copyResize(region, width: newW, height: newH);
    _drawBoxes(region, [scaled]);
  } else {
    _drawBoxes(region, [relBox]);
  }

  if (region.width > 1280 || region.height > 1280) {
    final scale = 1280 / max(region.width, region.height);
    final newW = (region.width * scale).round();
    final newH = (region.height * scale).round();
    region = img.copyResize(region, width: newW, height: newH);
  }

  final jpgBytes = img.encodeJpg(region, quality: 90);
  final base64Image = base64Encode(jpgBytes);

  final prompt =
      'You are an expert ornithologist helping build an eBird checklist. '
      'A red rectangle has been drawn on the image to highlight the bird. Focus your identification on the bird inside the red box.\n'
      'Identify the bird species using visible features: body shape, plumage color '
      'and pattern, beak shape, leg color, size relative to surroundings, and habitat.\n'
      'Explain your reasoning step by step, and then provide your best guess for the species.';

  final response = await http.post(
    Uri.parse('http://localhost:11434/api/generate'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'model': 'llava:13b',
      'prompt': prompt,
      'images': [base64Image],
      'stream': false,
      'options': {'temperature': 0.2, 'num_predict': 512},
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    print(data['response']);
  } else {
    print("Error: \${response.statusCode}");
  }
}
