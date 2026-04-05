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

import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io';

void main() {
  test('Run MobileNet', () async {
    final interpreter = Interpreter.fromFile(
      File('assets/ssd_mobilenet.tflite'),
    );

    // Create a dummy 300x300 image tensor
    final tensor = List.generate(
      1,
      (_) =>
          List.generate(300, (y) => List.generate(300, (x) => [128, 128, 128])),
    );

    Map<int, Object> dynamicOutputs = {
      0: List<List<List<double>>>.filled(
        1,
        List.filled(10, List.filled(4, 0.0)),
      ),
      1: List<List<double>>.filled(1, List.filled(10, 0.0)),
      2: List<List<double>>.filled(1, List.filled(10, 0.0)),
      3: List<double>.filled(1, 0.0),
    };

    interpreter.runForMultipleInputs([tensor], dynamicOutputs);

    var locations = dynamicOutputs[0] as List<List<List<double>>>;
    // Write the output array locations out
    File(
      'nms_out.txt',
    ).writeAsStringSync('Box 0: ${locations[0][0]}\nBox 1: ${locations[0][1]}');
  });
}
