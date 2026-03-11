// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import
import 'dart:io';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

void main() async {
  
  final interpreter = await Interpreter.fromFile(File('assets/efficientdet_lite4.tflite'));
  final tempPath = '/tmp/IMG_3835.jpg';
  
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

  var locations = dynamicOutputs[0] as List<List<List<double>>>;
  var classes = dynamicOutputs[1] as List<List<double>>;
  var scores = dynamicOutputs[2] as List<List<double>>;
  var counts = dynamicOutputs[3] as List<double>;

  int count = counts[0].toInt();
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
        
        double aspectRatio = localW / localH;
        print("Detected at X: $localX, Y: $localY, W: $localW, H: $localH, Ratio: $aspectRatio (Class $detectedClass, Score $score)");
      }
  }
}
