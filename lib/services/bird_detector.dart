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

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:rackery/src/rust/api/image_utils.dart';

part 'detection_helpers.dart';
part 'detection_reconciler.dart';
part 'detection_pipelines.dart';

// ── Public types ───────────────────────────────────────────────────────────

class BirdCrop {
  final Uint8List croppedJpgBytes;
  final List<double> centerColor;
  final double confidence;
  final Rectangle<int> box;

  BirdCrop(this.croppedJpgBytes, this.centerColor, this.confidence, this.box);
}

class DetectionResult {
  final List<BirdCrop> crops;
  final Duration createTilesTime;
  final Duration birdDetectionTime;
  DetectionResult(this.crops, this.createTilesTime, this.birdDetectionTime);
}

// ── Internal types ─────────────────────────────────────────────────────────

class _RawDetection {
  final Rectangle<int> box;
  final double score;
  final Rectangle<int>? sourceTile;

  _RawDetection(this.box, this.score, [this.sourceTile]);
}

/// Request for post-processing in a compute isolate.
class _PostProcessRequest {
  final Uint8List fileBytes;
  final List<List<int>> detections; // [x, y, w, h, score*1000]

  _PostProcessRequest(this.fileBytes, this.detections);
}

// ── BirdDetector class ─────────────────────────────────────────────────────

class BirdDetector {
  late final int _poolSize;
  final List<Interpreter> _interpreters = [];
  final List<IsolateInterpreter> _isolateInterpreters = [];
  final List<bool> _interpreterBusy = [];

  Future<void> init() async {
    final options = InterpreterOptions()
      ..threads = min(4, Platform.numberOfProcessors);

    // Enable XNNPack delegate for SIMD-optimized CPU inference.
    if (Platform.isWindows || Platform.isMacOS) {
      try {
        options.addDelegate(XNNPackDelegate());
      } catch (_) {
        // XNNPack not available in the loaded TFLite DLL/dylib
      }
    }

    // Force pool size to 1.
    // TFLite uses native C++ threading (`options..threads`). If we spawn multiple
    // concurrent models here, it causes extreme CPU context switching and cache thrashing
    // which significantly slows down overall performance.
    _poolSize = 1;

    for (int i = 0; i < _poolSize; i++) {
      final interpreter = await Interpreter.fromAsset(
        'assets/efficientdet_lite4.tflite',
        options: options,
      );
      final isolateInterpreter = await IsolateInterpreter.create(
        address: interpreter.address,
      );

      _interpreters.add(interpreter);
      _isolateInterpreters.add(isolateInterpreter);
      _interpreterBusy.add(false);
    }
  }

  Future<IsolateInterpreter> _acquireDetector() async {
    while (true) {
      for (int i = 0; i < _isolateInterpreters.length; i++) {
        if (!_interpreterBusy[i]) {
          _interpreterBusy[i] = true;
          return _isolateInterpreters[i];
        }
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  void _releaseDetector(IsolateInterpreter s) {
    final idx = _isolateInterpreters.indexOf(s);
    if (idx != -1) {
      _interpreterBusy[idx] = false;
    }
  }

  Future<DetectionResult> detectAndCrop(String imagePath) async {
    if (_interpreters.isEmpty) {
      throw Exception('Detector not initialized');
    }

    final fileBytes = await File(imagePath).readAsBytes();

    final inputShape = _interpreters.first.getInputTensor(0).shape;
    final int targetW = inputShape[1];
    final int targetH = inputShape[2];

    return await _detect(fileBytes, targetW, targetH);
  }

  /// Platform-agnostic pipeline — fully async, no heavy work on main isolate.
  ///
  /// 1. compute() isolate: decode + crop + resize all tiles → flat Uint8Lists
  /// 2. Main isolate: pass flat pixels to pooled IsolateInterpreter (async inference)
  /// 3. compute() isolate: NMS + crop + JPG encode
  Future<DetectionResult> _detect(
    Uint8List fileBytes,
    int targetW,
    int targetH,
  ) async {
    final stopwatch = Stopwatch()..start();

    // Step 1: All heavy image ops in compute isolate
    final prepared = await prepareTiles(
      fileBytes: fileBytes,
      targetW: targetW,
      targetH: targetH,
    );

    final createTilesTime = stopwatch.elapsed;
    stopwatch.reset();

    if (prepared == null || prepared.tilePixels.isEmpty) {
      return DetectionResult([], createTilesTime, Duration.zero);
    }

    // Step 2: Inference via IsolateInterpreter (async, no UI blocking)
    List<_RawDetection> rawDetections = [];

    IsolateInterpreter? isolateInterpreter;
    try {
      isolateInterpreter = await _acquireDetector();

      for (int ti = 0; ti < prepared.tilePixels.length; ti++) {
        final pixels = prepared.tilePixels[ti];
        final outputs = _allocateOutputs();
        await isolateInterpreter.runForMultipleInputs([pixels], outputs);

        final rect = prepared.tileRects[ti];
        final tile = Rectangle<int>(rect[0], rect[1], rect[2], rect[3]);
        rawDetections.addAll(
          _extractDetections(outputs, tile, prepared.origW, prepared.origH),
        );
      }
    } finally {
      if (isolateInterpreter != null) {
        _releaseDetector(isolateInterpreter);
      }
    }

    if (rawDetections.isEmpty) {
      return DetectionResult([], createTilesTime, stopwatch.elapsed);
    }

    final nmsDetections = _applyNms(rawDetections);

    final reconciledDetections = await _reconcileAbuttingBoxes(
      nmsDetections,
      prepared.origW,
      prepared.origH,
      (customTiles) async {
        if (customTiles.isEmpty) return [];

        final prepCust = await prepareTiles(
          fileBytes: fileBytes,
          targetW: targetW,
          targetH: targetH,
          customTiles: customTiles.map((r) => Uint32List.fromList([r.left, r.top, r.width, r.height])).toList(),
        );

        if (prepCust == null || prepCust.tilePixels.isEmpty) return [];

        List<_RawDetection> customDets = [];
        IsolateInterpreter? customIsolate;
        try {
          customIsolate = await _acquireDetector();
          for (int ti = 0; ti < prepCust.tilePixels.length; ti++) {
            final pixels = prepCust.tilePixels[ti];
            final outputs = _allocateOutputs();
            await customIsolate.runForMultipleInputs([pixels], outputs);

            final rect = prepCust.tileRects[ti];
            final tile = Rectangle<int>(rect[0], rect[1], rect[2], rect[3]);
            customDets.addAll(
              _extractDetections(outputs, tile, prepCust.origW, prepCust.origH),
            );
          }
        } finally {
          if (customIsolate != null) {
            _releaseDetector(customIsolate);
          }
        }
        return _applyNms(customDets);
      },
    );

    if (reconciledDetections.isEmpty) {
      return DetectionResult([], createTilesTime, stopwatch.elapsed);
    }

    List<List<int>> finalFormattedList = reconciledDetections
        .map(
          (d) => [
            d.box.left,
            d.box.top,
            d.box.width,
            d.box.height,
            (d.score * 1000).toInt(),
          ],
        )
        .toList();

    // Step 3: NMS (noop since already applied) + crop + encode in compute isolate
    final crops = await compute(
      _postProcessDetections,
      _PostProcessRequest(fileBytes, finalFormattedList),
    );

    return DetectionResult(crops, createTilesTime, stopwatch.elapsed);
  }

  void dispose() {
    for (final isolateInterpreter in _isolateInterpreters) {
      isolateInterpreter.close();
    }
    for (final interpreter in _interpreters) {
      interpreter.close();
    }
    _isolateInterpreters.clear();
    _interpreters.clear();
    _interpreterBusy.clear();
  }
}
