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

// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:rackery/services/image_converter.dart';

void main() {
  test('Detect Turnstone with Converter', () async {
    final interpreter = await Interpreter.fromFile(
      File('assets/efficientdet_lite4.tflite'),
    );

    // First convert it so the image lib can parse it
    final convertedPath = await ImageConverter.convertToJpegIfNeeded(
      '/home/jkane/test photos/IMG_3835.HEIC',
    );
    print("Converted to \$convertedPath");

    final fileBytes = await File(convertedPath).readAsBytes();
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
