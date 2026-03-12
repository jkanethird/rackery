// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

void main() {
  test('Detect Turnstone', () async {
    final interpreter = await Interpreter.fromFile(
      File('assets/efficientdet_lite4.tflite'),
    );
    final fileBytes = await File(
      '/home/jkane/test photos/IMG_3835.HEIC',
    ).readAsBytes();
    final originalImage = img.decodeImage(fileBytes);
    if (originalImage == null) {
      print("Could not decode image");
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
      0: List<List<List<double>>>.filled(
        1,
        List.filled(25, List.filled(4, 0.0)),
      ),
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
  });
}
