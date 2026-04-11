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
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

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

// ── Internal types ─────────────────────────────────────────────────────────

class _RawDetection {
  final Rectangle<int> box;
  final double score;
  final Rectangle<int>? sourceTile;

  _RawDetection(this.box, this.score, [this.sourceTile]);
}

/// Request for computing all tile pixel data in a background isolate.
class _PrepareTilesRequest {
  final Uint8List fileBytes;
  final int targetW;
  final int targetH;
  final List<List<int>>? customTiles;

  _PrepareTilesRequest(
    this.fileBytes,
    this.targetW,
    this.targetH, [
    this.customTiles,
  ]);
}

/// Result from the tile preparation compute isolate.
/// Uses only primitives and Uint8List for efficient isolate transfer.
class _PrepareTilesResult {
  /// Flat pixel data (RGB) per tile, each Uint8List is targetW*targetH*3 bytes.
  final List<Uint8List> tilePixels;

  /// Tile rectangles as [x, y, w, h] per tile.
  final List<List<int>> tileRects;

  final int origW;
  final int origH;

  _PrepareTilesResult(this.tilePixels, this.tileRects, this.origW, this.origH);
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

    // Dynamic pool size bounds based on active CPU logical cores
    // EfficientDet is light internally (~20MB), but instances scale cleanly per internal block size
    // We scale 1 detector pool instance per 4 logical cores, capped tightly to 4 max parallel pipelines
    _poolSize = max(1, min(4, (Platform.numberOfProcessors / 4).ceil()));

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

  Future<List<BirdCrop>> detectAndCrop(String imagePath) async {
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
  Future<List<BirdCrop>> _detect(
    Uint8List fileBytes,
    int targetW,
    int targetH,
  ) async {
    // Step 1: All heavy image ops in compute isolate
    final prepared = await compute(
      _prepareTiles,
      _PrepareTilesRequest(fileBytes, targetW, targetH),
    );

    if (prepared.tilePixels.isEmpty) return [];

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

    if (rawDetections.isEmpty) return [];

    final nmsDetections = _applyNms(rawDetections);

    final reconciledDetections = await _reconcileAbuttingBoxes(
      nmsDetections,
      prepared.origW,
      prepared.origH,
      (customTiles) async {
        if (customTiles.isEmpty) return [];

        final prepCust = await compute(
          _prepareTiles,
          _PrepareTilesRequest(
            fileBytes,
            targetW,
            targetH,
            customTiles.map((r) => [r.left, r.top, r.width, r.height]).toList(),
          ),
        );

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

    if (reconciledDetections.isEmpty) return [];

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
    return await compute(
      _postProcessDetections,
      _PostProcessRequest(fileBytes, finalFormattedList),
    );
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
