// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:tflite_flutter/tflite_flutter.dart';
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
  final interpreter = await Interpreter.fromFile(
    File('assets/efficientdet_lite4.tflite'),
  );
  final tempPath = '/tmp/IMG_3835.jpg';

  final fileBytes = await File(tempPath).readAsBytes();
  final originalImage = img.decodeImage(fileBytes);
  if (originalImage == null) return;

  final inputShape = interpreter.getInputTensor(0).shape;
  final int targetW = inputShape[1];
  final int targetH = inputShape[2];

  img.Image imageInput = img.copyResize(
    originalImage,
    width: targetW,
    height: targetH,
    interpolation: img.Interpolation.linear,
  );

  var tensor = List.generate(
    1,
    (_) => List.generate(
      targetH,
      (y) => List.generate(targetW, (x) {
        final pixel = imageInput.getPixel(x, y);
        return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
      }),
    ),
  );

  Map<int, Object> dynamicOutputs = {
    0: List<List<List<double>>>.filled(1, List.filled(25, List.filled(4, 0.0))),
    1: List<List<double>>.filled(1, List.filled(25, 0.0)),
    2: List<List<double>>.filled(1, List.filled(25, 0.0)),
    3: List<double>.filled(1, 0.0),
  };

  interpreter.runForMultipleInputs([tensor], dynamicOutputs);

  var locations = dynamicOutputs[0] as List<List<List<double>>>;
  var classes = dynamicOutputs[1] as List<List<double>>;
  var scores = dynamicOutputs[2] as List<List<double>>;
  var counts = dynamicOutputs[3] as List<double>;

  int count = counts[0].toInt();
  Rectangle<int>? bestBox;
  for (int i = 0; i < count; i++) {
    double score = scores[0][i];
    int detectedClass = classes[0][i].toInt();
    if (score > 0.20 && (detectedClass == 16 || detectedClass == 15)) {
      List<double> box = locations[0][i];
      double ymin = box[0].clamp(0.0, 1.0);
      double xmin = box[1].clamp(0.0, 1.0);
      double ymax = box[2].clamp(0.0, 1.0);
      double xmax = box[3].clamp(0.0, 1.0);
      int localX = (xmin * originalImage.width).toInt();
      int localY = (ymin * originalImage.height).toInt();
      int localW = ((xmax - xmin) * originalImage.width).toInt();
      int localH = ((ymax - ymin) * originalImage.height).toInt();
      bestBox = Rectangle<int>(localX, localY, localW, localH);
      break;
    }
  }

  if (bestBox == null) return;

  final padX = (bestBox.width * 0.8).round();
  final padY = (bestBox.height * 0.8).round();

  final cropX1 = (bestBox.left - padX).clamp(0, originalImage.width - 1);
  final cropY1 = (bestBox.top - padY).clamp(0, originalImage.height - 1);
  final cropX2 = (bestBox.left + bestBox.width + padX).clamp(
    1,
    originalImage.width,
  );
  final cropY2 = (bestBox.top + bestBox.height + padY).clamp(
    1,
    originalImage.height,
  );

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
