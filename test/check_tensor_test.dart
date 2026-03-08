import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io';
void main() {
  test('Check tensors', () async {
    final interpreter = Interpreter.fromFile(File('assets/efficientdet_lite4.tflite'));
    String out = "INPUTS:\n";
    for (var t in interpreter.getInputTensors()) {
      out += "${t.name} type: ${t.type} shape: ${t.shape}\n";
    }
    out += "OUTPUTS:\n";
    for (var t in interpreter.getOutputTensors()) {
      out += "${t.name} type: ${t.type} shape: ${t.shape}\n";
    }
    File('tensors_lite4.txt').writeAsStringSync(out);
  });
}
