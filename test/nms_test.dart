import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io';

void main() {
  test('Run MobileNet', () async {
    final interpreter = Interpreter.fromFile(File('assets/ssd_mobilenet.tflite'));
    
    // Create a dummy 300x300 image tensor
    final tensor = List.generate(
      1,
      (_) => List.generate(
        300,
        (y) => List.generate(300, (x) => [128, 128, 128]),
      ),
    );

    Map<int, Object> dynamicOutputs = {
      0: List<List<List<double>>>.filled(1, List.filled(10, List.filled(4, 0.0))),
      1: List<List<double>>.filled(1, List.filled(10, 0.0)),
      2: List<List<double>>.filled(1, List.filled(10, 0.0)),
      3: List<double>.filled(1, 0.0),
    };

    interpreter.runForMultipleInputs([tensor], dynamicOutputs);
    
    var locations = dynamicOutputs[0] as List<List<List<double>>>;
    // Write the output array locations out
    File('nms_out.txt').writeAsStringSync('Box 0: ${locations[0][0]}\nBox 1: ${locations[0][1]}');
  });
}
