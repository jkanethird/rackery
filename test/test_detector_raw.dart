import 'dart:io';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

void main() async {
  final interpreter = await Interpreter.fromFile(File('assets/efficientdet_lite4.tflite'));
  
  // Directly point to the system ImageMagick without using Flutter plugins since we're in a raw Dart script
  final tempPath = '/tmp/IMG_3835.jpg';
  final result = await Process.run('magick', ['/home/jkane/test photos/IMG_3835.HEIC', tempPath]);
  if (result.exitCode != 0) {
     print("Magick failed");
     return;
  }
  
  final fileBytes = await File(tempPath).readAsBytes();
  final originalImage = img.decodeImage(fileBytes);
  if (originalImage == null) {
      print("Could not decode converted image");
      return;
  }
  
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

  var classes = dynamicOutputs[1] as List<List<double>>;
  var scores = dynamicOutputs[2] as List<List<double>>;
  var counts = dynamicOutputs[3] as List<double>;

  int count = counts[0].toInt();
  print("Count: \$count");
  for (int i = 0; i < count; i++) {
    print("Class: \${classes[0][i]}, Score: \${scores[0][i]}");
  }
}
