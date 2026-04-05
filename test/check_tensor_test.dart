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
  test('Check tensors', () async {
    final interpreter = Interpreter.fromFile(
      File('assets/efficientdet_lite4.tflite'),
    );
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
